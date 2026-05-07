# Plan — kind Control-Plane Metrics + Mimir Integration

## Context

Two follow-on workstreams branching off `docs/monitoring-k8s-core-plan.md`:

1. **kind control-plane metrics** — `kube-controller-manager`, `kube-scheduler`, `kube-proxy`, and `etcd` bind their metrics endpoints to `127.0.0.1` by default in kubeadm-bootstrapped clusters (which kind uses). The current playground keeps the corresponding ServiceMonitors enabled but accepts DOWN targets. This plan flips them to `0.0.0.0` via `kubeadmConfigPatches` so the bundled kube-prometheus-stack ServiceMonitors actually scrape successfully.
2. **Grafana Mimir integration** — Add Mimir as long-term, multi-region metrics storage behind the existing per-region Prometheus instances. Each region's Prometheus continues to scrape locally, then `remoteWrite`s to a single Mimir hub backed by RustFS S3. Grafana gains a Mimir datasource for cross-region queries.

**Primary target: single-region (`local`).** Multi-region (`eu`/`us`) must continue to work; the design treats the first region in `REGIONS` as the "hub" host of Mimir, with other regions pushing in via Traefik.

**Locked decisions (from interactive prompts):**

- Coexist: Prometheus keeps scraping; adds `spec.remoteWrite` → Mimir.
- Mimir classic architecture, monolithic single-binary, **no Kafka**.
- kind kubeadm patch applied now; plan documents the `demo/teardown.sh` + `scripts/setup.sh` recreate cycle.

---

## Part A — kind Control-Plane Metrics

### A.1 Why the current state fails

`kubeadm` defaults bind:

| Component | Default bind | Default port |
|---|---|---|
| `kube-controller-manager` | `127.0.0.1` | 10257 |
| `kube-scheduler` | `127.0.0.1` | 10259 |
| `kube-proxy` | `127.0.0.1` | 10249 |
| `etcd` `--listen-metrics-urls` | `http://127.0.0.1:2381` | 2381 |

Any pod outside the host network (i.e. Prometheus on a worker) cannot reach those endpoints. The `kube-prometheus-stack` chart provides ServiceMonitors that target the kube-system Service backing each component; with the default kind bind, those targets show DOWN.

### A.2 Patch — `k8s/kind-cluster.yaml.tpl` and `k8s/kind-cluster.yaml`

Extend the **control-plane node's** existing `kubeadmConfigPatches` block. The `.tpl` already has a `ClusterConfiguration` patch for OIDC; merge new fields into the same block. Add a second patch entry for `KubeProxyConfiguration`.

**`k8s/kind-cluster.yaml.tpl`** — replace the control-plane node block with:

```yaml
- role: control-plane
  extraMounts:
    - hostPath: ${DEX_TLS_DIR}/ca-chain.pem
      containerPath: /etc/kubernetes/oidc/dex-ca.pem
      readOnly: true
  kubeadmConfigPatches:
    - |
      kind: ClusterConfiguration
      apiServer:
        extraArgs:
          oidc-issuer-url: https://${DEX_HOST}:${DEX_PORT}/dex
          oidc-ca-file: /etc/kubernetes/oidc/dex-ca.pem
          oidc-client-id: kubernetes
          oidc-username-claim: email
          oidc-username-prefix: "oidc:"
          oidc-groups-claim: groups
          oidc-groups-prefix: "oidc:"
      controllerManager:
        extraArgs:
          bind-address: 0.0.0.0
      scheduler:
        extraArgs:
          bind-address: 0.0.0.0
      etcd:
        local:
          extraArgs:
            listen-metrics-urls: http://0.0.0.0:2381
    - |
      kind: KubeProxyConfiguration
      metricsBindAddress: 0.0.0.0
```

**`k8s/kind-cluster.yaml`** (no-OIDC variant) — replace the control-plane node block with:

```yaml
- role: control-plane
  kubeadmConfigPatches:
    - |
      kind: ClusterConfiguration
      controllerManager:
        extraArgs:
          bind-address: 0.0.0.0
      scheduler:
        extraArgs:
          bind-address: 0.0.0.0
      etcd:
        local:
          extraArgs:
            listen-metrics-urls: http://0.0.0.0:2381
    - |
      kind: KubeProxyConfiguration
      metricsBindAddress: 0.0.0.0
```

### A.3 kube-prometheus-stack — point kubeEtcd ServiceMonitor at port 2381

The chart's default `kubeEtcd.service.targetPort` is `2379` (the etcd client port, TLS). Our patch exposes the metrics-only listener on `2381` (HTTP, no TLS). Override:

**`monitoring/kube-prometheus-stack-values.yaml`** — append:

```yaml
kubeEtcd:
  enabled: true
  service:
    enabled: true
    port: 2381
    targetPort: 2381
  serviceMonitor:
    scheme: http
    insecureSkipVerify: true
```

`kubeControllerManager`, `kubeScheduler`, `kubeProxy` already use the correct bundled ServiceMonitor wiring once binds move off loopback — no extra values needed (already enabled per `docs/monitoring-k8s-core-plan.md` Commit 1).

### A.4 Recreate cycle (required)

`kubeadmConfigPatches` apply only at cluster bootstrap. Existing clusters must be torn down and recreated:

```bash
./demo/teardown.sh
./scripts/setup.sh           # picks up new kind-cluster.yaml(.tpl)
./monitoring/setup.sh        # rolls Prometheus stack with kubeEtcd override
```

### A.5 Security note (single-region playground)

Binding control-plane component metrics to `0.0.0.0` makes them reachable from any pod on the kind docker network:

- `kube-controller-manager` (`10257/https`) and `kube-scheduler` (`10259/https`) require **bearer-token auth** — RBAC-protected, safe.
- `kube-proxy` (`10249/http`) is plain HTTP but exposes only operational metrics.
- **etcd `2381` is HTTP, unauthenticated.** It exposes etcd's own runtime metrics but not key/value data. Acceptable for a local playground; **document this** in `monitoring/README.md`.

For production, the canonical alternative is to scrape etcd via the existing `2379` client port using the etcd peer/client certificate (PodMonitor with TLS + cert from the `etcd-certs` Secret). Out of scope here.

---

## Part B — Mimir Integration

### B.1 Topology

| Mode | Mimir | Prometheus push target |
|---|---|---|
| Single-region (`local`) | runs in `local` cluster, namespace `mimir` | `http://mimir-nginx.mimir.svc.cluster.local/api/v1/push` |
| Multi-region (`eu`+`us`+…) | runs in **first** region from `REGIONS[]` (the "hub") | other regions: `http://mimir-push.<hub-traefik-ip-dashed>.sslip.io/api/v1/push`, header `X-Scope-OrgID: <region>` |

Hub region selection: `HUB_REGION="${REGIONS[0]}"`. Single-region case collapses to "hub == only region", local cluster service URL.

### B.2 Helm chart and mode

- Chart: `grafana/mimir-distributed` (OCI: `oci://ghcr.io/grafana/helm-charts/mimir-distributed`).
- **Classic architecture** (no Kafka): set
  ```yaml
  kafka:
    enabled: false
  mimir:
    structuredConfig:
      ingest_storage:
        enabled: false
  ```
- **Monolithic compaction**: set replicas to 1 across all components (override defaults). The chart still spins separate Deployments/StatefulSets per role but pinned at `replicas: 1` keeps the footprint small.
- Storage: S3 → existing RustFS bucket `mimir`. Reuses the same `objectstore-local` Service + Endpoints pattern that Loki uses.

### B.3 New file — `monitoring/mimir/mimir-values.yaml`

```yaml
# Classic architecture, monolithic-style single-replica deployment for the playground.
# Storage: RustFS S3 (in-cluster Service objectstore-local in the mimir namespace).

kafka:
  enabled: false

minio:
  enabled: false  # bundled MinIO unused — RustFS provides S3

mimir:
  structuredConfig:
    ingest_storage:
      enabled: false
    common:
      storage:
        backend: s3
        s3:
          endpoint: objectstore-local.mimir.svc.cluster.local:9000
          region: us-east-1
          insecure: true
          # access_key_id / secret_access_key injected via env vars below
          access_key_id: ${RUSTFS_ROOT_USER}
          secret_access_key: ${RUSTFS_ROOT_PASSWORD}
    blocks_storage:
      s3:
        bucket_name: mimir-blocks
    alertmanager_storage:
      s3:
        bucket_name: mimir-alertmanager
    ruler_storage:
      s3:
        bucket_name: mimir-ruler
    multitenancy_enabled: true
    limits:
      ingestion_rate: 100000
      ingestion_burst_size: 200000

# Pin every component to single replica — playground footprint
distributor:    { replicas: 1 }
ingester:       { replicas: 1, persistentVolume: { size: 5Gi } }
querier:        { replicas: 1 }
query_frontend: { replicas: 1 }
query_scheduler: { replicas: 1 }
store_gateway:  { replicas: 1, persistentVolume: { size: 5Gi } }
compactor:      { replicas: 1, persistentVolume: { size: 5Gi } }
ruler:          { replicas: 1 }
alertmanager:   { replicas: 1, persistentVolume: { size: 1Gi } }
overrides_exporter: { replicas: 1 }

nginx:
  replicas: 1
  service:
    type: ClusterIP

# Keep on infra nodes
nodeSelector:
  node-role.kubernetes.io/infra: ""
tolerations:
  - key: node-role.kubernetes.io/infra
    operator: Exists
    effect: NoSchedule
```

> Schema check: `mimir.structuredConfig` is the chart's documented escape-hatch for raw `mimir.yaml`. `s3.access_key_id`/`secret_access_key` accept `${VAR}` env-substituted at config render time when the chart's `extraEnv` plumbing is used; if the chart version does not expand env in structuredConfig, fall back to `helm --set 'mimir.structuredConfig.common.storage.s3.access_key_id=...'` from the orchestrator (mirroring the existing Loki pattern in `monitoring/setup.sh`).

### B.4 New file — `monitoring/mimir/objectstore-bridge.yaml.tpl`

Mirror the Loki pattern: rendered by `setup.sh`, wires the in-cluster `objectstore-local` Service+Endpoints in the `mimir` namespace pointing at the host RustFS container.

```yaml
apiVersion: v1
kind: Service
metadata:
  name: objectstore-local
  namespace: mimir
spec:
  ports:
    - name: s3
      port: 9000
      targetPort: 9000
---
apiVersion: v1
kind: Endpoints
metadata:
  name: objectstore-local
  namespace: mimir
subsets:
  - addresses:
      - ip: ${OBJECTSTORE_IP}
    ports:
      - name: s3
        port: 9000
```

### B.5 New file — `monitoring/mimir/ingressroute.yaml.tpl` (multi-region only)

Renders only when `${#REGIONS[@]} -gt 1` and current region is the hub.

```yaml
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: mimir-push
  namespace: mimir
spec:
  entryPoints: [web]
  routes:
    - match: Host(`mimir-push.${TRAEFIK_IP_DASHED}.sslip.io`)
      kind: Rule
      services:
        - name: mimir-nginx
          port: 80
```

### B.6 Patch — `monitoring/prometheus-instance/deploy_prometheus.yaml`

Add `remoteWrite` to the `Prometheus` CR. The remote URL is templated by `setup.sh` based on hub vs non-hub region:

```yaml
spec:
  # ... existing fields (selectors from previous plan) ...
  remoteWrite:
    - url: ${MIMIR_PUSH_URL}
      headers:
        X-Scope-OrgID: ${REGION}
      writeRelabelConfigs:
        - sourceLabels: [__name__]
          regex: '(up|scrape_.*|kube_.*|node_.*|kubelet_.*|apiserver_.*|cnpg_.*|pg_.*)'
          action: keep
```

`setup.sh` substitutes:

- `MIMIR_PUSH_URL` = `http://mimir-nginx.mimir.svc.cluster.local/api/v1/push` for the hub region; `http://mimir-push.<hub-traefik-ip-dashed>.sslip.io/api/v1/push` for non-hub regions.
- `REGION` = current region (used as Mimir tenant ID).

The relabel keep-list trims junk so RustFS doesn't fill up; expandable later.

### B.7 New file — `monitoring/grafana/grafana_datasource_mimir.yaml`

Adds Mimir as a Prometheus-typed datasource so dashboards can switch via dropdown. Deployed only on the hub region's Grafana (other regions still get a same-namespace Prom datasource).

```yaml
apiVersion: grafana.integreatly.org/v1beta1
kind: GrafanaDatasource
metadata:
  name: mimir
  namespace: grafana
spec:
  instanceSelector:
    matchLabels:
      dashboards: grafana
  allowCrossNamespaceImport: true
  datasource:
    name: DS_MIMIR
    type: prometheus
    access: proxy
    url: http://mimir-nginx.mimir.svc.cluster.local
    jsonData:
      httpHeaderName1: X-Scope-OrgID
      timeInterval: 15s
    secureJsonData:
      httpHeaderValue1: __all__   # cross-tenant read; replace with per-region UID via Grafana templating later
```

For per-region dashboards in multi-region, the `X-Scope-OrgID` header can be templated via Grafana variable at dashboard level instead of datasource — out of scope for this plan.

### B.8 Patch — `monitoring/setup.sh`

New region-aware logic, in the per-region loop:

```bash
HUB_REGION="${REGIONS[0]}"
HUB_CONTEXT="$(get_cluster_context "${HUB_REGION}")"

for region in "${REGIONS[@]}"; do
    CONTEXT_NAME="$(get_cluster_context "${region}")"

    if [[ "${region}" == "${HUB_REGION}" ]]; then
        # 1. Render objectstore-bridge for mimir ns
        # 2. Helm install grafana/mimir-distributed
        # 3. If multi-region: render ingressroute.yaml.tpl
        # 4. Compute MIMIR_PUSH_URL = http://mimir-nginx.mimir.svc.cluster.local/api/v1/push
    else
        # Compute MIMIR_PUSH_URL via hub Traefik IP:
        HUB_TRAEFIK_IP="$(get_traefik_lb_ip "${HUB_CONTEXT}" 30)"
        HUB_TRAEFIK_DASHED="$(ip_to_dashed "${HUB_TRAEFIK_IP}")"
        MIMIR_PUSH_URL="http://mimir-push.${HUB_TRAEFIK_DASHED}.sslip.io/api/v1/push"
    fi

    # Render & apply prometheus-instance with MIMIR_PUSH_URL + REGION substituted
    REGION="${region}" MIMIR_PUSH_URL="${MIMIR_PUSH_URL}" \
        envsubst '${REGION} ${MIMIR_PUSH_URL}' \
        < "${GIT_REPO_ROOT}/monitoring/prometheus-instance/deploy_prometheus.yaml.tpl" \
        | kubectl --context "${CONTEXT_NAME}" apply -f -
done
```

Convert `monitoring/prometheus-instance/deploy_prometheus.yaml` → `.tpl` (mirroring the existing `*.tpl` + `envsubst` pattern in the repo). Keep the `kustomization.yaml` building the rest.

### B.9 New file — `monitoring/mimir/kustomization.yaml`

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: mimir
resources: []  # values + ingressroute applied via setup.sh; placeholder for future static manifests
```

### B.10 Pin chart version

Add to `scripts/common.sh`:

```bash
MIMIR_CHART_VERSION="5.x.y"  # latest classic-mode-friendly release at apply time
```

Used by `helm_upgrade_install` in setup.sh.

---

## Verification

### Part A
```bash
# After teardown + setup
kubectl --context kind-k8s-local get servicemonitor -A | grep -E 'kubelet|kube-controller|kube-scheduler|kube-proxy|kube-etcd|node-exporter|kube-state'

# Port-forward Prometheus
kubectl --context kind-k8s-local -n prometheus-operator port-forward svc/prometheus-operated 9090
# Open http://localhost:9090/targets — expect kubelet, kube-controller-manager, kube-scheduler,
# kube-proxy, kube-etcd, node-exporter, kube-state-metrics ALL UP.
```

### Part B
```bash
# Mimir pods up
kubectl --context kind-k8s-local -n mimir get pods

# RustFS bucket accessible
kubectl --context kind-k8s-local -n mimir run mc --rm -it --image=minio/mc:latest --restart=Never \
  --command -- sh -c "mc alias set s http://objectstore-local:9000 \$RUSTFS_ROOT_USER \$RUSTFS_ROOT_PASSWORD && mc ls s/mimir-blocks"

# Prometheus remote_write working
# Prometheus UI → Status → Remote Write → expect 0 failed samples after a minute.

# Mimir round-trip query
kubectl --context kind-k8s-local -n mimir port-forward svc/mimir-nginx 8080:80
curl -s -H "X-Scope-OrgID: local" 'http://localhost:8080/prometheus/api/v1/query?query=up' | jq '.data.result | length'
# expect: > 0

# Grafana → Mimir datasource → run `up{job="kubelet"}` → results visible
```

Multi-region check: deploy `eu` then `us`, confirm `us` Prometheus's remote_write target shows the hub's sslip.io URL and Mimir's `up` query with `X-Scope-OrgID: us` returns `us` cluster series.

---

## Risks / Watchpoints

| Risk | Mitigation |
|---|---|
| `kubeadmConfigPatches` ignored by older kind images | Document required kind ≥ v0.20 / kindest/node ≥ v1.27. |
| etcd 2381 unauthenticated HTTP exposure | Document in `monitoring/README.md`; acceptable for local playground. |
| Mimir chart version drift breaks `structuredConfig` schema | Pin `MIMIR_CHART_VERSION` in `scripts/common.sh`; revalidate on bumps. |
| RustFS bucket auto-creation | Mimir does **not** auto-create buckets. `setup.sh` must run a `mc mb mimir-blocks/mimir-alertmanager/mimir-ruler` step (mirror the Loki bucket-init pattern). |
| Cross-region push hits Traefik HTTP only | Acceptable for playground; for HTTPS, route through the existing wildcard cert pattern from `vault-pki` work. |
| Prometheus + Mimir double-store doubles disk | Tune Prom retention down (e.g. `retention: 6h`) once Mimir flow proven. |
| Hub-region Traefik IP changes between rebuilds | `setup.sh` recomputes via `get_traefik_lb_ip` on every run; non-hub regions get fresh URL. |
| Single-replica ingester loses data on restart | Acceptable for playground; documented. |

---

## File-level Changeset Summary

### Modify
- `k8s/kind-cluster.yaml.tpl`
- `k8s/kind-cluster.yaml`
- `monitoring/kube-prometheus-stack-values.yaml`  *(adds `kubeEtcd` block)*
- `monitoring/prometheus-instance/deploy_prometheus.yaml` → rename to `.tpl`
- `monitoring/prometheus-instance/kustomization.yaml`  *(drop the file from kustomize; setup.sh now templates it)*
- `monitoring/setup.sh`  *(hub region selection, Mimir install, push-URL substitution, bucket init)*
- `monitoring/grafana/kustomization.yaml`  *(add Mimir datasource on hub)*
- `monitoring/README.md`  *(security note on etcd 2381, Mimir resource ownership row)*
- `scripts/common.sh`  *(add `MIMIR_CHART_VERSION`)*

### Create
- `monitoring/mimir/mimir-values.yaml`
- `monitoring/mimir/objectstore-bridge.yaml.tpl`
- `monitoring/mimir/ingressroute.yaml.tpl`
- `monitoring/mimir/kustomization.yaml`
- `monitoring/grafana/grafana_datasource_mimir.yaml`

### Reused utilities (existing)
- `helm_upgrade_install`, `get_cluster_context`, `get_cluster_name` — `scripts/common.sh`
- `get_traefik_lb_ip`, `ip_to_dashed` — `scripts/common.sh`
- `detect_running_regions` — `scripts/funcs_regions.sh`
- `RUSTFS_BASE_NAME`, `RUSTFS_ROOT_USER`, `RUSTFS_ROOT_PASSWORD` — `scripts/common.sh`
- `objectstore-local` Service+Endpoints pattern — `monitoring/setup.sh` (Loki section)

---

## Suggested Commit Sequence

1. **Commit 1** — `feat(kind): expose control-plane metrics on 0.0.0.0`
   Touches: `k8s/kind-cluster.yaml{,.tpl}`, `monitoring/kube-prometheus-stack-values.yaml`, `monitoring/README.md`.
   Validation: full teardown+setup, all Prometheus targets UP.

2. **Commit 2** — `feat(monitoring): add Mimir hub for long-term metrics storage`
   Touches: `monitoring/mimir/*` (new), `monitoring/prometheus-instance/deploy_prometheus.yaml{→.tpl}`, `monitoring/setup.sh`, `scripts/common.sh`.
   Validation: Mimir pods up, Prometheus remote_write succeeding, RustFS `mimir-blocks` populated.

3. **Commit 3** — `feat(monitoring): add Mimir datasource to Grafana hub`
   Touches: `monitoring/grafana/grafana_datasource_mimir.yaml` (new), `monitoring/grafana/kustomization.yaml`.
   Validation: Grafana shows Mimir datasource; PromQL queries return cluster-wide data.

---

## Out of Scope

- HTTPS for cross-region remote_write (uses Vault PKI / Traefik TLS wildcard later)
- Mimir multi-tenant Grafana org_mapping integration with Dex
- Alertmanager rules and routing
- Mimir ruler federation
- Tempo / traces
- Replacing the existing Prometheus datasource (kept for fast local queries)
