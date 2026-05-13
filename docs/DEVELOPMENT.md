<!-- generated-by: gsd-doc-writer -->
# Development Guide

This guide covers the repository layout, conventions, and workflows for
extending or modifying the cnpg-playground.

---

## Repository Layout

```
cnpg-playground/
├── scripts/          # Core lifecycle scripts (setup, info, teardown, vault-*, dex-*, eso-*)
│   ├── common.sh     # Shared variables, helpers, version pins — the single source of truth
│   └── funcs_*.sh    # Modular function libraries sourced by setup scripts
├── k8s/              # Kind cluster template (kind-cluster.yaml.tpl)
├── monitoring/       # Observability stack (Alloy, Mimir, Loki, Tempo, OTel Collector, Grafana)
│   ├── setup.sh      # Deploy the full monitoring stack
│   ├── teardown.sh   # Remove the full monitoring stack
│   └── */            # Per-component Helm values + config templates
├── demo/             # Demo scenarios (distributed topology, self-service, pgadmin, ESO)
│   ├── setup.sh      # Deploy CNPG distributed topology demo
│   ├── yaml/         # Kubernetes manifests per region (eu/, us/, local/, self-service/)
│   └── *.sh          # Higher-level demo scripts
├── vault/            # HashiCorp Vault config + cert-manager + ESO ClusterSecretStore
├── dex/              # Dex OIDC identity provider config template
├── traefik/          # Traefik Helm values
├── pgadmin/          # pgAdmin Kubernetes manifests
└── docs/             # Documentation
```

---

## Conventions

### Shell scripts

- Shebang: `#!/usr/bin/env bash`
- Always start with `set -euo pipefail`
- Source shared helpers: `source "$(dirname "$0")/common.sh"` (adjust relative path as needed)
- Version pins go in `scripts/common.sh` — never hardcode chart/image versions elsewhere
- Use `log_info`, `log_warn`, `log_error` from `scripts/common.sh` for output

### Template files

Files with a `.tpl` suffix require variable substitution before use. `setup.sh`
scripts render them at install time using `envsubst`:

```bash
envsubst < my-config.yaml.tpl > /tmp/my-config.yaml
kubectl apply -f /tmp/my-config.yaml
```

Keep all substitutable variables as `$VAR_NAME` (not `${VAR_NAME}`) unless the
shell context requires braces.

### Helm values files

- One values file per component: `monitoring/<component>/<component>-values.yaml`
- Single-replica defaults throughout (playground footprint constraint)
- Node selectors target infra workers: `nodeSelector: node-role.kubernetes.io/infra: ""`

### YAML manifests

- 2-space indentation
- Group by concern: `monitoring/`, `demo/yaml/<region>/`, `vault/`, etc.
- Self-service manifests live in `demo/yaml/self-service/<namespace>/`

---

## Common Development Tasks

### Adding a new component to the monitoring stack

1. Add chart version variable to `scripts/common.sh`:
   ```bash
   export MY_COMPONENT_CHART_VERSION="1.2.3"
   ```

2. Create `monitoring/my-component/` with a Helm values file.

3. Add install/uninstall blocks to `monitoring/setup.sh` and `monitoring/teardown.sh`
   following the existing pattern (namespace creation, helm install, rollout wait).

4. Label the namespace for Alloy scraping if it exposes Prometheus metrics:
   ```bash
   label_namespace_for_scrape my-component "${CONTEXT}"
   ```

### Adding a new region tenant to Mimir

1. In `monitoring/mimir/mimir-values.yaml`, add an entry under `runtimeConfig.overrides`:
   ```yaml
   my-region:
     max_global_series_per_user: 500000
     max_query_lookback: 30d
     ingestion_rate: 100000
   ```

2. Add `my-region` to the `query_federation.allowed_tenants` list of every existing tenant.

3. Configure Alloy for the new region to remote-write with `X-Scope-OrgID: my-region`.

### Modifying Kind cluster topology

Edit `k8s/kind-cluster.yaml.tpl`. Changes take effect on the **next** `scripts/setup.sh`
run after `scripts/teardown.sh`. There is no in-place upgrade path for existing clusters.

### Adding a new Grafana dashboard

1. Create a `GrafanaDashboard` CR YAML in the appropriate directory
   (e.g., `monitoring/grafana/` for the shared instance).

2. Set `spec.instanceSelector` to target the correct Grafana instance:
   - Shared instance: `{matchLabels: {dashboards: grafana}}`
   - Tenant instance: `{matchLabels: {dashboards: grafana-rbr-ver}}`

3. Apply via `kubectl apply -f` or include in the relevant setup script.

### Pinning a new chart version

Update the variable in `scripts/common.sh`:

```bash
export MY_CHART_VERSION="x.y.z"
```

Then re-run `monitoring/setup.sh` (or the relevant setup script) — it upgrades
installed releases via `helm upgrade --install`.

---

## Local Iteration Workflow

1. **Make changes** to scripts or manifests.
2. **Test** on a running cluster:
   ```bash
   # Apply manifest changes directly
   kubectl --context kind-k8s-eu apply -f monitoring/my-component/my-values.yaml

   # Re-run a setup step
   source scripts/common.sh && helm upgrade --install ...
   ```
3. **Full cycle** (destructive — use sparingly):
   ```bash
   ./scripts/teardown.sh
   ./scripts/setup.sh
   ```

For monitoring stack changes only (faster than full teardown):
```bash
./monitoring/teardown.sh
./monitoring/setup.sh
```

---

## Debugging

### Check cluster status
```bash
./scripts/info.sh
```

### Inspect a failing pod
```bash
kubectl --context kind-k8s-eu describe pod -n <namespace> <pod>
kubectl --context kind-k8s-eu logs -n <namespace> <pod> --previous
```

### Verify MetalLB IP assignment
```bash
kubectl --context kind-k8s-eu get svc -A | grep LoadBalancer
```

### Check Alloy scrape targets
```bash
# Port-forward Alloy UI
kubectl --context kind-k8s-eu port-forward -n alloy svc/alloy-service 12345:12345
# Open http://localhost:12345
```

### Check Mimir ingestion
```bash
# Query a metric via the Mimir HTTP API
curl -H "X-Scope-OrgID: eu" \
  "http://mimir-query.<HUB_IP_DASHED>.sslip.io/prometheus/api/v1/query?query=up"
```

### Container runtime detection

`scripts/common.sh` auto-detects Docker or Podman via `CONTAINER_PROVIDER`.
If detection fails, set it explicitly:

```bash
export CONTAINER_PROVIDER=podman
./scripts/setup.sh
```

---

## Making a Release

This playground does not publish versioned releases. Changes are merged to
`main` directly. See [CONTRIBUTING.md](../CONTRIBUTING.md) for PR workflow.
