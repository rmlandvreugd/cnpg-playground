# Traefik Integration Plan

## Goal

Add Traefik v3 as the ingress controller to all playground clusters, backed by MetalLB.
Two use cases:
- **UC1**: Expose Grafana via HTTP IngressRoute at `grafana.<dashed-ip>.sslip.io`
- **UC2**: Expose Vault API via TCP passthrough IngressRoute on port 8200 (vault branch)

## Decisions

| Question | Decision |
|---|---|
| Traefik version | v3.3, static manifests (no Helm) |
| LoadBalancer provider | MetalLB, one IP per cluster |
| Hostname scheme | `service.<dashed-ip>.sslip.io` |
| Grafana TLS | HTTP only |
| Vault TLS model | TCP passthrough, `HostSNI('*')` catch-all |
| Vault K8s service | Service + manual Endpoints (Docker IP resolved at runtime) |
| Cluster scope | All clusters (eu, us, local) |
| Infra node tolerations | Not needed — only postgres nodes have `NoSchedule` taint |
| Missing Traefik in monitoring | Skip + warn, port-forward as fallback |
| Teardown | Cluster deletion is sufficient, no explicit uninstall steps |
| Dashboard | Exposed via IngressRoute at `traefik.<dashed-ip>.sslip.io` |

## Architecture

```
Kind network (shared Docker bridge): 172.18.0.0/16
  MetalLB pool per cluster (single /32):
    eu    → 172.18.255.200
    us    → 172.18.255.201
    local → 172.18.255.202

Traefik entrypoints:
  web        :80   → HTTP routes (Grafana, dashboard)
  websecure  :443  → HTTPS (future)
  vault      :8200 → TCP passthrough to Vault container

Routing:
  grafana.<dashed-ip>.sslip.io  → grafana-service.grafana:3000  (HTTP IngressRoute)
  traefik.<dashed-ip>.sslip.io  → api@internal                  (HTTP IngressRoute)
  :8200 HostSNI('*')            → vault.vault:8200              (TCP IngressRoute, passthrough)
```

## Files to Create

### `traefik/` — new directory

| File | Purpose |
|---|---|
| `kustomization.yaml` | assembles all Traefik manifests |
| `namespace.yaml` | `traefik` namespace |
| `rbac.yaml` | ServiceAccount + ClusterRole + ClusterRoleBinding |
| `deployment.yaml` | Traefik v3.3, `nodeSelector: node-role.kubernetes.io/infra: ""` |
| `services.yaml` | LoadBalancer (80, 443, 8200) + ClusterIP (8080 dashboard) |
| `ingressroute-dashboard.yaml.tpl` | Dashboard IngressRoute, hostname via `envsubst` |

Traefik static config (CLI args in deployment):
```
--entrypoints.web.address=:80
--entrypoints.websecure.address=:443
--entrypoints.vault.address=:8200
--providers.kubernetescrd=true
--providers.kubernetescrd.allowCrossNamespace=true
--api.dashboard=true
--log.level=INFO
```
No `--api.insecure` — dashboard exposed only via IngressRoute.

CRDs applied from pinned upstream URL in setup script:
```
https://raw.githubusercontent.com/traefik/traefik/v3.3/docs/content/reference/dynamic-configuration/kubernetes-crd-definition-v1.yml
```

### `monitoring/grafana/ingressroute.yaml.tpl`

HTTP IngressRoute applied via `envsubst` after Traefik LB IP is known:
- Rule: `` Host(`grafana.${TRAEFIK_IP_DASHED}.sslip.io`) ``
- Service: `grafana-service.grafana:3000`
- Entrypoint: `web`

### `vault/traefik/ingressroute-tcp.yaml` *(vault branch)*

TCP IngressRoute — static, no IP substitution needed:
- Entrypoint: `vault`
- Rule: `HostSNI('*')` (catch-all)
- TLS: passthrough
- Service: `vault.vault:8200`

### `vault/traefik/service.yaml.tpl` *(vault branch)*

Headless Service + Endpoints applied via `envsubst` in `vault-setup.sh`:
- Service: no selector, port 8200
- Endpoints: `${VAULT_IP}:8200` (resolved from Docker inspect after kind network connect)

## Files to Modify

### `scripts/common.sh`

Add variables:
```bash
METALLB_VERSION="${METALLB_VERSION:-v0.14.9}"
TRAEFIK_VERSION="${TRAEFIK_VERSION:-v3.3}"
```

Add helper functions:
```bash
# Returns the MetalLB IP for a given region index (0-based)
get_metallb_ip() {
    local region_index="$1"
    local kind_subnet
    kind_subnet=$(docker network inspect kind --format '{{(index .IPAM.Config 0).Subnet}}')
    local kind_base
    kind_base=$(echo "$kind_subnet" | cut -d. -f1-2)
    echo "${kind_base}.255.$((200 + region_index))"
}

# Waits for Traefik LoadBalancer IP; prints the IP or returns 1 on timeout
get_traefik_lb_ip() {
    local context="$1"
    local max_wait="${2:-60}"
    local elapsed=0
    while [ "$elapsed" -lt "$max_wait" ]; do
        local ip
        ip=$(kubectl --context "$context" -n traefik get svc traefik \
            -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)
        if [ -n "$ip" ]; then
            echo "$ip"
            return 0
        fi
        sleep 2
        elapsed=$((elapsed + 2))
    done
    return 1
}

# Converts an IP address to dashed notation: 172.18.255.200 → 172-18-255-200
ip_to_dashed() {
    echo "$1" | tr '.' '-'
}
```

### `scripts/setup.sh`

After node labeling (end of Phase 1 loop body), add Phase 2 per cluster:

```bash
# --- Phase 2: MetalLB + Traefik per cluster ---
REGION_INDEX=0
for region in "${REGIONS[@]}"; do
    CONTEXT_NAME=$(get_cluster_context "${region}")
    TRAEFIK_IP=$(get_metallb_ip "${REGION_INDEX}")
    TRAEFIK_IP_DASHED=$(ip_to_dashed "${TRAEFIK_IP}")

    echo "🔧 Installing MetalLB in ${region}..."
    kubectl --context "${CONTEXT_NAME}" apply -f \
        "https://raw.githubusercontent.com/metallb/metallb/${METALLB_VERSION}/config/manifests/metallb-native.yaml"
    kubectl --context "${CONTEXT_NAME}" -n metallb-system \
        wait --for=condition=ready pod --selector=component=controller --timeout=90s

    # Apply IPAddressPool + L2Advertisement for this cluster's single IP
    TRAEFIK_IP="${TRAEFIK_IP}" envsubst < "${GIT_REPO_ROOT}/traefik/metallb-pool.yaml.tpl" \
        | kubectl --context "${CONTEXT_NAME}" apply -f -

    echo "🔧 Installing Traefik v3 in ${region}..."
    kubectl --context "${CONTEXT_NAME}" apply -f \
        "https://raw.githubusercontent.com/traefik/traefik/v3.3/docs/content/reference/dynamic-configuration/kubernetes-crd-definition-v1.yml"
    kubectl kustomize "${GIT_REPO_ROOT}/traefik" \
        | kubectl --context "${CONTEXT_NAME}" apply -f -
    kubectl --context "${CONTEXT_NAME}" -n traefik \
        rollout status deployment traefik --timeout=90s

    echo "🌐 Applying Traefik dashboard IngressRoute for ${region}..."
    TRAEFIK_IP_DASHED="${TRAEFIK_IP_DASHED}" envsubst \
        < "${GIT_REPO_ROOT}/traefik/ingressroute-dashboard.yaml.tpl" \
        | kubectl --context "${CONTEXT_NAME}" apply -f -

    echo "✅ Traefik ready: http://traefik.${TRAEFIK_IP_DASHED}.sslip.io"
    ((REGION_INDEX++))
done
```

Also add `traefik/metallb-pool.yaml.tpl` to the new files list (see below).

### `monitoring/setup.sh`

After Grafana kustomize apply, replace the port-forward echo block with:

```bash
    # Try to get Traefik LB IP; apply IngressRoute if available
    if TRAEFIK_LB_IP=$(get_traefik_lb_ip "${CONTEXT_NAME}" 30); then
        TRAEFIK_IP_DASHED=$(ip_to_dashed "${TRAEFIK_LB_IP}")
        TRAEFIK_IP_DASHED="${TRAEFIK_IP_DASHED}" envsubst \
            < "${GIT_REPO_ROOT}/monitoring/grafana/ingressroute.yaml.tpl" \
            | kubectl --context "${CONTEXT_NAME}" apply -f -
        echo " Grafana: http://grafana.${TRAEFIK_IP_DASHED}.sslip.io"
    else
        echo "⚠️  Traefik not found in ${CONTEXT_NAME} — falling back to port-forward"
        echo " kubectl port-forward service/grafana-service ${port}:3000 -n grafana --context ${CONTEXT_NAME}"
        echo " http://localhost:${port}"
    fi
```

### `scripts/vault-setup.sh` *(vault branch)*

After `docker network connect kind "${VAULT_CONTAINER_NAME}"`, for each cluster context:

```bash
VAULT_IP=$(${CONTAINER_PROVIDER} inspect "${VAULT_CONTAINER_NAME}" \
    --format '{{.NetworkSettings.Networks.kind.IPAddress}}')

for region in "${REGIONS[@]}"; do
    CONTEXT_NAME=$(get_cluster_context "${region}")
    echo "🔧 Wiring Vault service into ${region}..."
    kubectl --context "${CONTEXT_NAME}" create ns vault --dry-run=client -o yaml \
        | kubectl --context "${CONTEXT_NAME}" apply -f -
    VAULT_IP="${VAULT_IP}" envsubst \
        < "${GIT_REPO_ROOT}/vault/traefik/service.yaml.tpl" \
        | kubectl --context "${CONTEXT_NAME}" apply -f -
    kubectl --context "${CONTEXT_NAME}" apply \
        -f "${GIT_REPO_ROOT}/vault/traefik/ingressroute-tcp.yaml"
    echo "✅ Vault TCP route active on :8200 in ${region}"
done
```

### `scripts/info.sh`

Add a Traefik/Grafana URL block per region (after detecting the LB IP).

## Additional Template File

### `traefik/metallb-pool.yaml.tpl`

```yaml
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: traefik-pool
  namespace: metallb-system
spec:
  addresses:
  - ${TRAEFIK_IP}/32
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: traefik-l2
  namespace: metallb-system
spec:
  ipAddressPools:
  - traefik-pool
```

## Implementation Order

1. `scripts/common.sh` — add vars + helpers (foundation for everything else)
2. `traefik/` directory — all static manifests + templates
3. `scripts/setup.sh` — Phase 2 MetalLB + Traefik block
4. `monitoring/grafana/ingressroute.yaml.tpl` + `monitoring/setup.sh` update
5. `vault/traefik/` — service template + TCP IngressRoute *(vault branch)*
6. `scripts/vault-setup.sh` update *(vault branch)*
7. `scripts/info.sh` — URL output

## Out of Scope

- cert-manager / HTTPS for Grafana (HTTP only per decision)
- Traefik Helm chart (static manifests only)
- Explicit teardown steps (cluster deletion covers cleanup)
- HA for Traefik (single infra node, playground only)
