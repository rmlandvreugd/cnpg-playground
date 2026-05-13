<!-- generated-by: gsd-doc-writer -->
# Testing

This project is an infrastructure playground — there is no compiled source code and therefore
no unit test suite or test framework. Validation is entirely **operational**: scripts block until
Kubernetes workloads reach a known-good state, and the `cnpg` kubectl plugin provides
post-deploy inspection commands.

## Verification approach

| Phase | What is validated | Primary mechanism |
| :---- | :---------------- | :---------------- |
| Infrastructure setup | Kind clusters up, nodes Ready | `kubectl get nodes` |
| Operator deployment | CNPG / Barman Cloud controllers running | `kubectl rollout status` |
| PostgreSQL clusters | All instances healthy | `kubectl wait --for=condition=Ready cluster/<name>` |
| Monitoring stack | Mimir / Tempo / Loki / Alloy / Grafana running | `kubectl rollout status` + bucket-init pod completion |
| Certificates | TLS certs issued by cert-manager | `kubectl wait --for=condition=Ready certificate/<name>` |
| Self-service layer | ESO ExternalSecrets synced, Grafana dashboards loaded | `kubectl wait --for=condition=Ready externalsecret/<name>` |

## Running environment health checks

### 1. Cluster and node status

After `./scripts/setup.sh` completes, confirm all nodes are Ready:

```bash
export KUBECONFIG="$(git rev-parse --show-toplevel)/k8s/kube-config.yaml"

for region in eu us; do
  echo "=== Region: ${region} ==="
  kubectl --context "kind-k8s-${region}" get nodes
done
```

Use `./scripts/info.sh` for a combined status view across all detected regions:

```bash
./scripts/info.sh
```

### 2. PostgreSQL cluster readiness

After `./demo/setup.sh`, verify each CNPG Cluster object is Ready:

```bash
# Block until the cluster is fully ready (timeout: 30 minutes)
kubectl wait --context kind-k8s-eu \
  --timeout 30m \
  --for=condition=Ready cluster/pg-eu

kubectl wait --context kind-k8s-us \
  --timeout 30m \
  --for=condition=Ready cluster/pg-us
```

Inspect cluster status with the `cnpg` kubectl plugin:

```bash
kubectl cnpg --context kind-k8s-eu status pg-eu
kubectl cnpg --context kind-k8s-us status pg-us
```

### 3. CNPG operator and Barman Cloud Plugin

Verify operator deployments are rolled out:

```bash
kubectl --context kind-k8s-eu rollout status deployment \
  -n cnpg-system cnpg-controller-manager

kubectl --context kind-k8s-eu rollout status deployment \
  -n cnpg-system barman-cloud
```

### 4. Monitoring stack

After `./monitoring/setup.sh`, verify the key components:

```bash
# kube-prometheus-stack (Prometheus Operator)
kubectl --context kind-k8s-eu rollout status deployment/prometheus-operator \
  -n prometheus-operator --timeout=120s

# Alloy log/metrics collector
kubectl --context kind-k8s-eu rollout status deployment/alloy \
  -n grafana --timeout=120s

# Mimir (hub region only)
kubectl --context kind-k8s-eu -n mimir wait pod/mimir-bucket-init \
  --for=condition=Complete --timeout=120s

# Tempo (hub region only)
kubectl --context kind-k8s-eu -n tempo wait pod/tempo-bucket-init \
  --for=condition=Complete --timeout=120s

# OTel Collector (non-hub regions)
kubectl --context kind-k8s-us -n otel rollout status \
  deploy/otel-collector-opentelemetry-collector --timeout=120s
```

### 5. Certificates

```bash
# Traefik dashboard TLS certificate
kubectl wait --context kind-k8s-eu \
  --for=condition=Ready certificate/traefik-dashboard-cert \
  -n traefik --timeout=120s
```

### 6. External Secrets Operator (vault integration)

After `./scripts/eso-setup.sh` and `./scripts/vault-eso-setup.sh`:

```bash
# Wait for ESO CRDs to be established
kubectl wait --for=condition=Established \
  crd/externalsecrets.external-secrets.io --timeout=120s

# Check ExternalSecret sync status in the demo namespace
kubectl get externalsecret -n demo-local-db
```

## Inspecting service endpoints

Use `./scripts/info.sh` to retrieve sslip.io URLs for all running regions:

```bash
./scripts/info.sh
# Output includes:
#   Traefik dashboard: http://traefik.<ip>.sslip.io
#   Grafana:           http://grafana.<ip>.sslip.io
```

## Common failure indicators

| Symptom | Likely cause | Resolution |
| :------ | :----------- | :--------- |
| `kubectl wait` times out on `cluster/pg-<region>` | CNPG operator not deployed or inotify limits too low | Check `kubectl cnpg status`, run `./scripts/tune-sysctl.sh` |
| Mimir / Loki bucket-init pod stuck | RustFS object store container not reachable from Kind network | Verify RustFS container is running: `docker ps \| grep objectstore` |
| `rollout status` hangs on Alloy | Namespace not labelled for scrape | Label the namespace: see `scripts/funcs_namespace_scrape_label.sh` |
| Traefik `EXTERNAL-IP` pending | MetalLB IP pool not allocated | Re-run `scripts/setup.sh` or inspect MetalLB `IPAddressPool` CR |
| Certificates not issued | cert-manager not ready or Vault PKI unreachable | Check cert-manager pods in `cert-manager` namespace |

## No CI/CD pipeline detected

This repository contains no `.github/workflows/` directory. All validation is performed
locally after running setup scripts against Kind clusters.
