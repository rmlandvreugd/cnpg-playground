# Plan — Cross-Region Rollup Dashboards + Mimir Federation

## Context

Follow-up to `docs/monitoring-prom-removal-plan.md`. Closes two "Out of Scope" items by adding:

1. **Cross-region rollup dashboards** — dedicated fleet views that span all regions in one panel
2. **Mimir multi-tenant federation** — `source_tenants` annotation support for cross-region AND cross-purpose (regions ⊕ `tempo`) queries

Pairs with `docs/monitoring-ops-plan.md` (alerting + namespace scope tightening).

### Locked decisions (interactive)

| # | Question | Choice |
|---|---|---|
| 1 | Doc structure | Two plans (signals here; ops separate) |
| 2 | Rollup dashboard scope | New dedicated dashboard set (don't touch existing) |
| 3 | Specific dashboards | **All four**: CNPG fleet · Traefik fleet RED · K8s capacity fleet · Cross-region request flow |
| 4 | Cross-tenant DS layout | **Two DS**: `mimir-fleet` (regions only) + reuse existing `mimir-tempo` |
| 5 | Federation use case | Both — cross-region AND cross-purpose |
| 6 | Rule federation default | Region default + per-rule `source_tenants` annotation opt-in |
| 7 | Mimir limits | **Per-tenant override file** (`runtime_config` ConfigMap) |

### Current state (verified)

- `monitoring/mimir/mimir-values.yaml` — `multitenancy_enabled: true`, `tenant_federation.enabled: true` already set
- `monitoring/grafana/grafana_datasource_mimir_tempo.yaml` — DS for `tempo` tenant (UID `mimir-tempo`) — keep as-is
- `monitoring/grafana/grafana_datasource_mimir.yaml` (becomes `.yaml.tpl` after prom-removal-plan) — per-region tenant DS
- `monitoring/grafana/grafana_datasource_prometheus_alias.yaml.tpl` — alias DS (per-region tenant) — keep as-is
- CNPG clusters in repo: `pg-eu`, `pg-us`, `pg-local`, `verstappen` (`-rbr-ver-db` cluster)
- Demo namespaces: `demo-local-db` (`CNPG_DEMO_NAMESPACE`), `rbr-ver-db`, `default` for `verstappen`
- No existing `runtime_config` ConfigMap for Mimir
- Tempo `metricsGenerator` already remoteWrites to Mimir tenant `tempo` (per kind-mimir-plan.md D.3)
- Region external_label set on every series via Alloy `external_labels = { cluster = "${REGION}" }`

---

## Part A — `mimir-fleet` cross-tenant Grafana datasource

### A.1 New file — `monitoring/grafana/grafana_datasource_mimir_fleet.yaml.tpl`

Single DS that reads all region tenants in one query. Mimir's tenant-federation accepts pipe-separated tenant IDs in `X-Scope-OrgID`.

```yaml
apiVersion: grafana.integreatly.org/v1beta1
kind: GrafanaDatasource
metadata:
  name: mimir-fleet
  namespace: grafana
spec:
  instanceSelector:
    matchLabels:
      dashboards: grafana
  allowCrossNamespaceImport: true
  datasource:
    name: DS_MIMIR_FLEET
    uid: mimir-fleet
    type: prometheus
    access: proxy
    url: http://mimir-nginx.mimir.svc.cluster.local/prometheus
    isDefault: false
    jsonData:
      httpHeaderName1: X-Scope-OrgID
      timeInterval: 30s
      exemplarTraceIdDestinations:
        - name: traceID
          datasourceUid: tempo
    secureJsonData:
      httpHeaderValue1: ${FLEET_TENANTS}
```

`${FLEET_TENANTS}` set by `monitoring/setup.sh` from the `REGIONS[]` array:

```bash
FLEET_TENANTS="$(IFS='|'; echo "${REGIONS[*]}")"   # e.g. "local"  or  "eu|us|local"
```

Single-region (`local` only) → `local`. Multi-region → `eu|us|local`. **Excludes `tempo`** — span metrics live in dedicated `mimir-tempo` DS to keep semantics separated.

### A.2 Patch — `monitoring/grafana/kustomization.yaml`

Remove from kustomize (templated DS applied separately via `setup.sh`). The `mimir-fleet` DS template gets applied alongside `mimir` + `prometheus-alias` in the per-region loop.

### A.3 Patch — `monitoring/setup.sh`

Append in the Grafana datasource apply block (same region loop):

```bash
FLEET_TENANTS="$(IFS='|'; echo "${REGIONS[*]}")"
REGION="${region}" FLEET_TENANTS="${FLEET_TENANTS}" \
    envsubst '${FLEET_TENANTS}' \
    < "${GIT_REPO_ROOT}/monitoring/grafana/grafana_datasource_mimir_fleet.yaml.tpl" \
    | kubectl --context "${CONTEXT_NAME}" apply -f -
```

> Each region's Grafana applies the same `mimir-fleet` DS pointing at the hub-region Mimir nginx via the in-cluster Service. Non-hub regions still resolve `mimir-nginx.mimir.svc.cluster.local` — **but only on the hub**. Non-hub regions don't have a Mimir installation. For non-hub Grafana to read the fleet, the URL must traverse Traefik/sslip.io. Handle via:

**A.3.1 Hub-vs-non-hub URL switch in `setup.sh`:**

```bash
if [[ "${region}" == "${HUB_REGION}" ]]; then
    MIMIR_QUERY_URL="http://mimir-nginx.mimir.svc.cluster.local/prometheus"
else
    HUB_TRAEFIK_IP="$(get_traefik_lb_ip "${HUB_CONTEXT}" 30)"
    HUB_TRAEFIK_DASHED="$(ip_to_dashed "${HUB_TRAEFIK_IP}")"
    MIMIR_QUERY_URL="http://mimir-query.${HUB_TRAEFIK_DASHED}.sslip.io/prometheus"
fi
```

Add a new IngressRoute on the hub for query traffic (read-only path; existing `mimir-push` IngressRoute is push-only):

### A.4 New file — `monitoring/mimir/ingressroute-query.yaml.tpl` (multi-region only)

```yaml
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: mimir-query
  namespace: mimir
spec:
  entryPoints: [web]
  routes:
    - match: Host(`mimir-query.${TRAEFIK_IP_DASHED}.sslip.io`)
      kind: Rule
      services:
        - name: mimir-nginx
          port: 80
```

Apply only on hub when `${#REGIONS[@]} -gt 1`. Mirrors `mimir-push` IngressRoute pattern.

> Templating impact: the existing `grafana_datasource_mimir.yaml.tpl`, `_prometheus_alias.yaml.tpl`, and new `_mimir_fleet.yaml.tpl` all need `MIMIR_QUERY_URL` substitution instead of hardcoded `mimir-nginx.mimir.svc.cluster.local`. **Update prom-removal-plan files in parallel** so all DS use the same hub-vs-non-hub switch.

### A.5 New file — `monitoring/grafana/grafana_datasource_mimir_fleet_rbr_ver.yaml.tpl`

Mirror to `grafana-rbr-ver` per locked decision. UID-suffix pattern.

```yaml
apiVersion: grafana.integreatly.org/v1beta1
kind: GrafanaDatasource
metadata:
  name: mimir-fleet-rbr-ver
  namespace: grafana
spec:
  instanceSelector:
    matchLabels:
      dashboards: grafana-rbr-ver
  allowCrossNamespaceImport: true
  datasource:
    name: DS_MIMIR_FLEET
    uid: mimir-fleet-rbr-ver
    type: prometheus
    access: proxy
    url: ${MIMIR_QUERY_URL}
    isDefault: false
    jsonData:
      httpHeaderName1: X-Scope-OrgID
      timeInterval: 30s
    secureJsonData:
      httpHeaderValue1: ${FLEET_TENANTS}
```

Apply via `demo/self-service-setup.sh` envsubst loop.

---

## Part B — Mimir runtime_config per-tenant overrides

### B.1 New file — `monitoring/mimir/runtime-config.yaml`

Per-tenant overrides applied via Mimir's `runtime_config.file` loader. Federation allowlist is per-tenant: tenant X can query tenants in `query_federation.allowed_tenants` list.

```yaml
overrides:
  # Region tenants — each can federate over the full fleet + tempo (read-only)
  local:
    max_global_series_per_user: 500000
    max_query_lookback: 30d
    ingestion_rate: 100000
    ingestion_burst_size: 200000
    query_federation:
      allowed_tenants: [local, eu, us, tempo]
  eu:
    max_global_series_per_user: 500000
    max_query_lookback: 30d
    ingestion_rate: 100000
    ingestion_burst_size: 200000
    query_federation:
      allowed_tenants: [local, eu, us, tempo]
  us:
    max_global_series_per_user: 500000
    max_query_lookback: 30d
    ingestion_rate: 100000
    ingestion_burst_size: 200000
    query_federation:
      allowed_tenants: [local, eu, us, tempo]
  # Span-metrics tenant — narrower; doesn't read back into regions
  tempo:
    max_global_series_per_user: 200000
    max_query_lookback: 7d
    ingestion_rate: 50000
    query_federation:
      allowed_tenants: [tempo]
```

> Schema check: Mimir runtime_config accepts a top-level `overrides` map keyed by tenant ID with per-tenant limits. `query_federation.allowed_tenants` is supported as of Mimir 2.13+. Validate via `helm show values oci://ghcr.io/grafana/helm-charts/mimir-distributed --version ${MIMIR_CHART_VERSION}` for current schema field names — Grafana docs and chart source may diverge.

### B.2 Patch — `monitoring/mimir/mimir-values.yaml`

Add `runtimeConfig` block so chart mounts a ConfigMap with the runtime overrides:

```yaml
runtimeConfig:
  overrides:
    # filled at install time from monitoring/mimir/runtime-config.yaml via --set-file
    # (placeholder so chart-side validation passes)
    placeholder: {}

mimir:
  structuredConfig:
    # ... existing ...
    runtime_config:
      file: /var/mimir/runtime.yaml
      reload_period: 10s
```

### B.3 Patch — `monitoring/setup.sh` (hub Mimir install)

`--set-file` the runtime-config YAML into the chart's `runtimeConfig.overrides`:

```bash
helm_upgrade_install mimir \
    oci://ghcr.io/grafana/helm-charts/mimir-distributed \
    mimir "${CONTEXT_NAME}" "${MIMIR_CHART_VERSION}" \
    --values "${GIT_REPO_ROOT}/monitoring/mimir/mimir-values.yaml" \
    --set "mimir.structuredConfig.common.storage.s3.access_key_id=${RUSTFS_ROOT_USER}" \
    --set "mimir.structuredConfig.common.storage.s3.secret_access_key=${RUSTFS_ROOT_PASSWORD}" \
    --set-file "runtimeConfig=${GIT_REPO_ROOT}/monitoring/mimir/runtime-config.yaml"
```

Chart's `runtimeConfig` field serializes the supplied map into a ConfigMap mounted at `/var/mimir/runtime.yaml`.

> Watchpoint: `mimir-distributed` chart's `runtimeConfig` field accepts a literal YAML map (not a file path) and renders it into a ConfigMap. `--set-file runtimeConfig=...` injects file contents as a string — verify chart version supports this idiom. Fallback: pre-create the ConfigMap manually and reference it via `runtimeConfig.configMapName`.

---

## Part C — PrometheusRule `source_tenants` annotation pattern

### C.1 Confirm existing wiring

`docs/monitoring-prom-removal-plan.md` Part B already defines:

```hcl
mimir.rules.kubernetes "rules" {
  address    = "${MIMIR_RULER_URL}"
  tenant_id  = "${REGION}"
  rule_selector       = {}
  rule_namespace_selector = {}
}
```

Per the `mimir.rules.kubernetes` Alloy component docs, `monitoring.grafana.com/source_tenants` annotation on a `PrometheusRule` CR federates source data from listed tenants while writing the result to the configured `tenant_id` (here `${REGION}`).

### C.2 Sample federated rule — `monitoring/mimir/rules-samples/fleet-rules.yaml`

Reference example, not auto-applied. Documents the pattern.

```yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: fleet-cnpg-rollup
  namespace: monitoring-fleet         # convention: rules wanting cross-tenant data live here
  annotations:
    # Read from all region tenants AND tempo span-metrics; write to current region tenant
    monitoring.grafana.com/source_tenants: "local,eu,us,tempo"
spec:
  groups:
    - name: cnpg-fleet
      interval: 30s
      rules:
        - record: fleet:cnpg_pg_replication_lag:max
          expr: max by (cluster) (cnpg_pg_replication_lag)
        - record: fleet:traefik_request_rate_5m:sum
          expr: sum by (service, cluster) (rate(traces_spanmetrics_calls_total{service_name=~".+"}[5m]))

    - name: cross-purpose-red
      interval: 30s
      rules:
        # Join regional CNPG metrics with tempo-tenant span-metrics in one rule.
        - record: fleet:db_request_rate_per_cnpg_cluster
          expr: |
            sum by (cluster, k8s_cluster) (
              rate(traces_spanmetrics_calls_total{db_system="postgresql"}[5m])
            )
```

### C.3 Patch — `monitoring/README.md`

Add a "Federated rules" section:

```markdown
### Federated rules (`source_tenants` annotation)

A `PrometheusRule` can read across tenants by annotating with:

    monitoring.grafana.com/source_tenants: "local,eu,us,tempo"

The rule is owned by the region tenant where it lives (Alloy's `mimir.rules.kubernetes` sets `tenant_id = ${REGION}`). Recording-rule output lands in the region tenant. Federation read-allowed sets are enforced per-tenant via `monitoring/mimir/runtime-config.yaml` — adding a new tenant requires updating `allowed_tenants` for all consumers.

Sample rules in `monitoring/mimir/rules-samples/` — not auto-applied; copy into a real namespace to activate.
```

---

## Part D — Rollup dashboards (4 new)

> All four dashboards are JSON wrapped in `GrafanaDashboard` CRs with `instanceSelector` for main `grafana`. rbr-ver variants in Part E.

### D.1 New file — `monitoring/grafana/grafana_dashboard_fleet_cnpg.yaml`

**CNPG fleet overview**: table of all CNPG clusters across regions.

Source: `cnpg_*` metrics with `cluster` (CNPG cluster name) and external label `cluster` (region — confusing collision; rename external label or use `region` label going forward).

> ⚠️ Label collision: Prometheus external_label `cluster=${REGION}` collides with CNPG's per-pod label `cluster=<cnpg-cluster-name>`. The external_label wins on `remote_write` per Prometheus contract. **Fix**: rename Alloy's external label from `cluster` to `region` to disambiguate fleet dashboards.

#### D.1.1 Pre-req patch — `monitoring/alloy/alloy-config.river.tpl`

```hcl
prometheus.remote_write "mimir" {
  endpoint {
    url = "${MIMIR_PUSH_URL}"
    headers = { "X-Scope-OrgID" = "${REGION}" }
    write_relabel_config {
      source_labels = ["__name__"]
      regex         = "(up|scrape_.*|kube_.*|node_.*|kubelet_.*|apiserver_.*|cnpg_.*|pg_.*|traces_.*|process_.*|go_.*)"
      action        = "keep"
    }
  }
  external_labels = { region = "${REGION}" }   // was: cluster = "${REGION}"
}
```

Likewise rename in the Prometheus CR's previous `externalLabels` block — but that CR is being deleted by `monitoring-prom-removal-plan.md`. So this change lands purely in Alloy config. **Add to prom-removal-plan execution as a one-line tweak before merge.**

> Watchpoint: Tempo `metricsGenerator` already exports `traces_*` with its own label set; verify it doesn't add `cluster` label conflicting with CNPG's. Check `monitoring/tempo/tempo-values.yaml` for `external_labels`.

#### D.1.2 Dashboard JSON sketch (panels)

```yaml
apiVersion: grafana.integreatly.org/v1beta1
kind: GrafanaDashboard
metadata:
  name: fleet-cnpg-overview
  namespace: grafana
spec:
  instanceSelector:
    matchLabels:
      dashboards: grafana
  json: |
    {
      "title": "CNPG Fleet Overview",
      "uid": "fleet-cnpg",
      "schemaVersion": 39,
      "refresh": "30s",
      "templating": {
        "list": [
          {
            "name": "region",
            "type": "query",
            "datasource": {"type":"prometheus","uid":"mimir-fleet"},
            "query": "label_values(cnpg_pg_replication_lag, region)",
            "includeAll": true,
            "multi": true
          }
        ]
      },
      "panels": [
        {
          "title": "Clusters by Region",
          "type": "stat",
          "datasource": {"type":"prometheus","uid":"mimir-fleet"},
          "targets": [
            {"expr": "count(count by (region, cluster) (cnpg_pg_replication_lag{region=~\"$region\"}))"}
          ]
        },
        {
          "title": "Cluster Status Table",
          "type": "table",
          "datasource": {"type":"prometheus","uid":"mimir-fleet"},
          "targets": [
            {"expr": "max by (region, cluster, namespace) (cnpg_pg_replication_lag{region=~\"$region\"})", "format": "table"}
          ]
        },
        {
          "title": "WAL Lag (max replication delay, all clusters)",
          "type": "timeseries",
          "datasource": {"type":"prometheus","uid":"mimir-fleet"},
          "targets": [
            {"expr": "max by (region, cluster) (cnpg_pg_replication_lag{region=~\"$region\"})", "legendFormat": "{{region}}/{{cluster}}"}
          ]
        },
        {
          "title": "Primary Pod Per Cluster",
          "type": "table",
          "datasource": {"type":"prometheus","uid":"mimir-fleet"},
          "targets": [
            {"expr": "max by (region, cluster, pod, role) (cnpg_pg_replication_lag{role=\"primary\"})", "format": "table"}
          ]
        }
      ]
    }
```

### D.2 New file — `monitoring/grafana/grafana_dashboard_fleet_traefik_red.yaml`

**Traefik fleet RED**: rate/error/duration per region.

Source: `traces_spanmetrics_calls_total` + `traces_spanmetrics_latency_bucket` (tenant `tempo`) — needs the `mimir-fleet` DS because spanmetrics carries `cluster=traefik-${region}` resource attribute set in `traefik/values.yaml` (per kind-mimir-plan.md D.7). With region external label now renamed → `region`, span metrics carry the `service_name=traefik-${region}` derived attribute.

Wait — span metrics live in tenant `tempo`, not in region tenants. `mimir-fleet` DS only reads `local|eu|us`. To query spanmetrics need `mimir-tempo` DS OR add `tempo` to `mimir-fleet`'s `FLEET_TENANTS`.

> Decision tradeoff: keep `mimir-fleet` regions-only (per locked answer "Two DS: `mimir-fleet` regions only") and have this dashboard use `mimir-tempo` DS directly. Per-panel DS selection — Grafana supports multiple datasources on one dashboard.

```yaml
apiVersion: grafana.integreatly.org/v1beta1
kind: GrafanaDashboard
metadata:
  name: fleet-traefik-red
  namespace: grafana
spec:
  instanceSelector:
    matchLabels:
      dashboards: grafana
  json: |
    {
      "title": "Traefik Fleet — RED",
      "uid": "fleet-traefik-red",
      "schemaVersion": 39,
      "refresh": "30s",
      "templating": {
        "list": [
          {
            "name": "region",
            "type": "custom",
            "query": "local,eu,us",
            "includeAll": true,
            "multi": true
          }
        ]
      },
      "panels": [
        {
          "title": "Request rate (req/s) per region",
          "type": "timeseries",
          "datasource": {"type":"prometheus","uid":"mimir-tempo"},
          "targets": [
            {"expr": "sum by (service_name) (rate(traces_spanmetrics_calls_total{service_name=~\"traefik-($region)\"}[1m]))", "legendFormat": "{{service_name}}"}
          ]
        },
        {
          "title": "5xx error rate per region",
          "type": "timeseries",
          "datasource": {"type":"prometheus","uid":"mimir-tempo"},
          "targets": [
            {"expr": "sum by (service_name) (rate(traces_spanmetrics_calls_total{service_name=~\"traefik-($region)\",status_code=~\"5..\"}[1m]))"}
          ]
        },
        {
          "title": "p95 latency per region",
          "type": "timeseries",
          "datasource": {"type":"prometheus","uid":"mimir-tempo"},
          "targets": [
            {"expr": "histogram_quantile(0.95, sum by (le, service_name) (rate(traces_spanmetrics_latency_bucket{service_name=~\"traefik-($region)\"}[5m])))"}
          ]
        }
      ]
    }
```

### D.3 New file — `monitoring/grafana/grafana_dashboard_fleet_k8s_capacity.yaml`

**K8s node/cluster capacity fleet**: CPU/memory/disk/pod-pressure across regions.

```yaml
# uid: fleet-k8s-capacity
# Panels (all from DS_MIMIR_FLEET, region template var):
#   - Allocatable CPU per region:
#       sum by (region) (kube_node_status_allocatable{resource="cpu"})
#   - Used CPU per region:
#       sum by (region) (rate(node_cpu_seconds_total{mode!="idle"}[5m]))
#   - Memory available per region:
#       sum by (region) (node_memory_MemAvailable_bytes)
#   - Pod count per region:
#       count by (region) (kube_pod_info)
#   - PVC bound count per region:
#       sum by (region) (kube_persistentvolumeclaim_status_phase{phase="Bound"})
```

Full JSON authored at implementation time; pattern matches D.1.

### D.4 New file — `monitoring/grafana/grafana_dashboard_fleet_request_flow.yaml`

**Cross-region request flow**: Traefik → CNPG service-graph view.

Source: Tempo `service-graph` processor metrics — `traces_service_graph_request_total`, `traces_service_graph_request_failed_total`, `traces_service_graph_request_server_seconds_bucket`. Lives in tenant `tempo`. Plus join to region tenants for target service health.

Use Grafana's nodeGraph viz with Tempo DS as primary, Mimir-fleet for sidebar metrics.

```yaml
# uid: fleet-request-flow
# Panels:
#   - Service graph (Tempo DS, type=nodeGraph, query: service_graph)
#   - Cross-cluster request flow table (mimir-tempo DS):
#       sum by (client, server, k8s_cluster) (rate(traces_service_graph_request_total[5m]))
#   - Target service CPU stress (mimir-fleet DS, joined by k8s_cluster→region):
#       avg by (region, pod) (rate(container_cpu_usage_seconds_total{pod=~"$target_service.*"}[5m]))
```

### D.5 Patch — `monitoring/grafana/kustomization.yaml`

Add the four new GrafanaDashboard CRs:

```yaml
resources:
  # ... existing ...
  - grafana_dashboard_fleet_cnpg.yaml
  - grafana_dashboard_fleet_traefik_red.yaml
  - grafana_dashboard_fleet_k8s_capacity.yaml
  - grafana_dashboard_fleet_request_flow.yaml
```

---

## Part E — rbr-ver mirror

### E.1 New files

For each of the 4 dashboards above, create `-rbr-ver` variant:

- `demo/yaml/self-service/grafana/grafanadashboard-fleet-cnpg-rbr-ver.yaml`
- `demo/yaml/self-service/grafana/grafanadashboard-fleet-traefik-red-rbr-ver.yaml`
- `demo/yaml/self-service/grafana/grafanadashboard-fleet-k8s-capacity-rbr-ver.yaml`
- `demo/yaml/self-service/grafana/grafanadashboard-fleet-request-flow-rbr-ver.yaml`

Differences from main:
- `instanceSelector.matchLabels.dashboards: grafana-rbr-ver`
- `metadata.name` suffixed `-rbr-ver`
- `spec.json` `uid` suffixed `-rbr-ver` (e.g. `fleet-cnpg-rbr-ver`)
- Datasource refs: `mimir-fleet-rbr-ver`, `mimir-tempo-rbr-ver` (from Part A.5)

### E.2 Patch — `demo/self-service-setup.sh`

Add the four `kubectl apply -f` lines (per existing pattern in that script).

---

## Verification

### V.1 Fleet DS reachable from each region's Grafana

```bash
# From hub:
kubectl --context kind-k8s-local -n grafana get grafanadatasource mimir-fleet -o jsonpath='{.status.conditions[*]}'
# expect: Reconciled=True

# From non-hub:
kubectl --context kind-k8s-eu -n grafana get grafanadatasource mimir-fleet -o jsonpath='{.spec.datasource.url}'
# expect: http://mimir-query.<hub-traefik-dashed>.sslip.io/prometheus
```

### V.2 Cross-tenant query through nginx

```bash
kubectl --context kind-k8s-local -n mimir port-forward svc/mimir-nginx 8080:80 &
sleep 2

# Pipe-separated multi-tenant
curl -s -H 'X-Scope-OrgID: local|eu|us' \
    'http://localhost:8080/prometheus/api/v1/label/region/values' | jq
# expect (multi-region): ["eu","local","us"]
# expect (single-region): ["local"]

# Cross-purpose (regions + tempo)
curl -s -H 'X-Scope-OrgID: local|tempo' \
    'http://localhost:8080/prometheus/api/v1/query?query=count(up)+OR+count(traces_spanmetrics_calls_total)' | jq
# expect: scalar > 0
```

### V.3 Per-tenant federation policy enforcement

```bash
# Tempo should NOT be allowed to read region tenants (allowed_tenants: [tempo] only)
curl -s -H 'X-Scope-OrgID: tempo|local' \
    'http://localhost:8080/prometheus/api/v1/query?query=up' | jq '.error'
# expect: federation error (tenant tempo not allowed to query [local])
```

### V.4 Federated rule sync

Apply `monitoring/mimir/rules-samples/fleet-rules.yaml` to `default` namespace; verify Mimir Ruler picks up the federated rule with proper `source_tenants`:

```bash
kubectl apply -n default -f monitoring/mimir/rules-samples/fleet-rules.yaml
sleep 60
curl -s -H 'X-Scope-OrgID: local' \
    'http://localhost:8080/prometheus/api/v1/rules' | jq '.data.groups[] | select(.name=="cnpg-fleet")'
# expect: rule object visible

curl -s -H 'X-Scope-OrgID: local' \
    'http://localhost:8080/prometheus/api/v1/query?query=fleet:cnpg_pg_replication_lag:max' | jq
# expect: result returns max across all regions
```

### V.5 Dashboards render

- Grafana → Dashboards → CNPG Fleet Overview → all panels populate; region dropdown shows all running regions
- Traefik Fleet RED → spanmetrics data visible per region
- K8s capacity → per-region totals
- Request flow → service graph renders nodes for traefik + CNPG services

### V.6 rbr-ver Grafana

- `https://grafana-rbr-ver.<traefik-dashed>.sslip.io/` → fleet dashboards listed under same names
- UIDs `*-rbr-ver` confirmed via URL bar (e.g. `/d/fleet-cnpg-rbr-ver/cnpg-fleet-overview`)
- No collision with main Grafana's `fleet-cnpg` UID

---

## File-level Changeset Summary

### Modify

- `monitoring/grafana/kustomization.yaml` — add 4 fleet dashboards
- `monitoring/setup.sh` — fleet DS apply; runtime-config `--set-file`; query IngressRoute apply; URL switch
- `monitoring/mimir/mimir-values.yaml` — `runtimeConfig` placeholder + `runtime_config.file` ref
- `monitoring/alloy/alloy-config.river.tpl` — rename external label `cluster → region` (D.1.1)
- `monitoring/README.md` — federation section + fleet DS docs
- `demo/self-service-setup.sh` — apply fleet DS + 4 fleet dashboards for rbr-ver

### Create

- `monitoring/grafana/grafana_datasource_mimir_fleet.yaml.tpl`
- `monitoring/grafana/grafana_dashboard_fleet_cnpg.yaml`
- `monitoring/grafana/grafana_dashboard_fleet_traefik_red.yaml`
- `monitoring/grafana/grafana_dashboard_fleet_k8s_capacity.yaml`
- `monitoring/grafana/grafana_dashboard_fleet_request_flow.yaml`
- `monitoring/mimir/runtime-config.yaml`
- `monitoring/mimir/ingressroute-query.yaml.tpl` (multi-region only)
- `monitoring/mimir/rules-samples/fleet-rules.yaml` (sample, not auto-applied)
- `demo/yaml/self-service/grafana/grafanadatasource-mimir-fleet-rbr-ver.yaml.tpl`
- `demo/yaml/self-service/grafana/grafanadashboard-fleet-{cnpg,traefik-red,k8s-capacity,request-flow}-rbr-ver.yaml`

### Cross-plan touchpoints

- `monitoring-prom-removal-plan.md` Part A.1 — replace `cluster = "${REGION}"` external_label with `region = "${REGION}"` (single-line change before merging that plan, or rolled forward with this one)
- `monitoring-prom-removal-plan.md` Part C — all DS templates now consume `${MIMIR_QUERY_URL}` instead of hardcoded service URL (so non-hub Grafana works)

---

## Risks / Watchpoints

| Risk | Mitigation |
|---|---|
| `runtimeConfig` chart field behavior diverges from doc | Validate `helm show values oci://ghcr.io/grafana/helm-charts/mimir-distributed --version ${MIMIR_CHART_VERSION}` for current `runtimeConfig.*` schema. Fallback: pre-create ConfigMap + reference via `runtimeConfig.configMapName`. |
| Renaming external label `cluster → region` breaks existing dashboards that group by `cluster` (region semantics) | Existing dashboards (k8s_global, kube_state) use `cluster` mostly to mean CNPG cluster or k8s cluster — historically ambiguous. Audit before merge. Most imported community dashboards' `cluster` variable refers to the k8s cluster — would now be empty. Add a one-shot Mimir backfill relabel if needed. **Lower risk path**: keep external label as `cluster` and use `pg_cluster` to disambiguate CNPG; revisit if collision actually surfaces. |
| Pipe-separated `X-Scope-OrgID: a\|b\|c` requires `tenant_federation.enabled: true` in Mimir AND `query_federation.allowed_tenants` listing each | Already enabled (kind-mimir-plan.md). Runtime-config Part B.1 sets `allowed_tenants`. Verify via V.3. |
| Tempo `service-graph` processor not enabled → request-flow dashboard empty | `kind-mimir-plan.md` D.3 enables `metricsGenerator.config` with `[service-graphs, span-metrics]` processors. Verify pod env. |
| Span-metrics `service_name` carries region suffix (`traefik-eu`) — `service_name=~"traefik-($region)"` regex requires region var | Documented in D.2 panel queries. |
| Non-hub Grafana querying via Traefik adds latency | sslip.io traversal adds ~50-100ms. Acceptable for playground. For prod, use direct IngressRoute or dedicated mTLS path. |
| `mimir-fleet` reads region tenants but not `tempo` — RED dashboard uses `mimir-tempo` DS — two-DS dashboard | Grafana supports multi-DS dashboards (per-panel selection). Documented. |
| `runtime_config.file` reload period (10s) too aggressive on slow disks | Acceptable for playground. Tune to `30s` if hub cluster shows reload churn. |
| `monitoring.grafana.com/source_tenants` annotation might not be honored if `mimir.rules.kubernetes` is on older Alloy version | Alloy 1.8.0 ships this. Memory confirms. |
| Cross-tenant rule output gets stamped with `tenant_id=${REGION}` even if reading from tempo | Documented; recording-rule output owner-tenant is the writing region, not source. Consumers of `fleet:*` recording rules need region-tenant DS to read them. |
| Querying `mimir-fleet` with very broad PromQL (`count(up)`) returns ALL fleet series — high RAM on querier | Acceptable for 3-region playground. Mimir limits already set `max_global_series_per_user: 500000`. |
| Grafana DS `secureJsonData.httpHeaderValue1` doesn't accept pipe characters in some operator versions | Standard string field — pipes work. Test via V.2 first. |

---

## Suggested Commit Sequence

1. **Commit 1** — `feat(alloy): rename external label cluster→region for fleet disambiguation`
   Touches: `monitoring/alloy/alloy-config.river.tpl`.
   Validation: Mimir series carry `region` not `cluster`; existing dashboards re-validated (likely require dashboard variable rename — handle in commit 4).

2. **Commit 2** — `feat(mimir): runtime-config per-tenant overrides + federation allowlist`
   Touches: `monitoring/mimir/runtime-config.yaml` (new), `monitoring/mimir/mimir-values.yaml`, `monitoring/setup.sh` (runtime-config `--set-file`).
   Validation: V.3 (per-tenant federation enforcement).

3. **Commit 3** — `feat(grafana): mimir-fleet cross-tenant datasource + query IngressRoute`
   Touches: `monitoring/grafana/grafana_datasource_mimir_fleet.yaml.tpl` (new), `monitoring/mimir/ingressroute-query.yaml.tpl` (new), `monitoring/setup.sh`.
   Validation: V.1, V.2.

4. **Commit 4** — `feat(grafana): 4 cross-region rollup dashboards`
   Touches: 4 new `grafana_dashboard_fleet_*.yaml` + kustomization.
   Validation: V.5.

5. **Commit 5** — `feat(self-service): mirror fleet DS + dashboards to grafana-rbr-ver`
   Touches: rbr-ver variants + `demo/self-service-setup.sh`.
   Validation: V.6.

6. **Commit 6** — `docs(monitoring): sample federated PrometheusRule pattern`
   Touches: `monitoring/mimir/rules-samples/fleet-rules.yaml` (new), `monitoring/README.md`.
   Validation: V.4 (manual apply only).

---

## Out of Scope (next round)

- Recording-rule pre-aggregation for fleet dashboard query speed (`fleet:cnpg_*:max` etc) — sample provided but not auto-applied
- Per-tenant Grafana folders (org_mapping) — fleet dashboards live in default folder for both Grafana instances
- HTTPS for `mimir-query` IngressRoute — uses Vault PKI when wildcard certs land
- Cross-region Alloy `mimir.rules.kubernetes` topology — each region writes rules to its own tenant; cross-region writers not modelled
- Dashboard JSON full bodies for D.3 + D.4 — sketched only; finalize during execution
