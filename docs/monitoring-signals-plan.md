# Plan — Cross-Region Rollup Dashboards + Mimir Federation

## Execution Sequence (shared across both plans)

> Identical block in `docs/monitoring-ops-plan.md`. Update both when changing order. Each row maps to one commit.

### Phase 0 — Prereqs (done)

- `874eb43` — Prometheus CR removed (Mimir sole metrics store)
- `a53e108` — `mimir.rules.kubernetes` Alloy block in place
- `7372767` — `rule_selector {}` block syntax fix

### Phase 1 — Foundation (independent, parallel-safe)

| # | Plan | Commit | Why first |
|---|---|---|---|
| 1 | Ops | C1 — label namespaces for scrape allowlist | No deps. Label scheme used downstream. |
| 2 | Ops | C2 — scope Alloy ServiceMonitor/PodMonitor to labeled namespaces | Hardens scrape posture before adding rules. |
| 3 | **Signals** | **C1 — dual-label emit `cluster + region` (Alloy + Tempo)** | **Critical — gates everything below.** All fleet dashboards + recording rules + CNPG alert annotations consume `region`. |

### Phase 2 — Mimir multi-tenant + AM wiring (depends on Phase 1)

| # | Plan | Commit | Notes |
|---|---|---|---|
| 4 | Signals | C2 — Mimir runtime-config per-tenant overrides | Enables `query_federation.allowed_tenants`. |
| 5 | Ops | C3 — Mimir Ruler→AM wire + null receiver | AM fallback config + `alertmanager_url`. |
| 6 | Signals | C3 — `mimir-fleet` cross-tenant DS + query IngressRoute | Multi-region read path. |

### Phase 3 — Dashboards + alerting policies (depends on Phase 2)

| # | Plan | Commit | Notes |
|---|---|---|---|
| 7 | Signals | C4 — 4 fleet rollup dashboards | Consumes `region` label + `mimir-fleet` DS. |
| 8 | Ops | C4 — Grafana Unified Alerting + null contact point + smoke rule | Grafana Alerting CR scaffolding. |
| 9 | Signals | C5 — self-service mirror of fleet DS + dashboards | rbr-ver Grafana sees fleet view. |
| 10 | Ops | C5 — self-service mirror of Grafana Alerting | rbr-ver Grafana Alerting. |

### Phase 4 — Alert content + production-grade routing (depends on Phase 3)

| # | Plan | Commit | Notes |
|---|---|---|---|
| 11 | Ops | C6 — CNPG alert library + 3 gap alerts + hub-only fleet alert | Uses `region` label from Phase 1 #3. |
| 12 | Signals | C6 — fleet recording rules + cross-region writer topology | Hub-only apply + non-hub purge. Speeds dashboards from #7. |
| 13 | Ops | C7 — Mimir AM `inhibit_rules` + Grafana mute timings | Needs alert library from #11 (inhibition source/target names). |
| 14 | Ops | C8 — Mimir AM HA 3 replicas + memberlist gossip | Independent — slot earlier if convenient. |
| 15 | Ops | C9 — namespace-labeler CronJob + severity taxonomy lint | Lint depends on alert library from #11. |

### Critical ordering rules

- **Signals C1 (#3) must land before** any commit querying `region` label: signals C4 (#7), signals C6 (#12), ops C6 (#11), ops C7 (#13).
- **Ops C3 AM wire (#5) must land before** ops C7 inhibit_rules (#13) and ops C8 HA (#14).
- **Ops C1+C2 namespace labels (#1, #2) must land before** ops C9 labeler (#15).

### Parallelizable

- #4 + #5 + #6 — runtime-config, AM wire, fleet DS — different files.
- #7 + #8 — fleet dashboards vs Grafana Alerting CRs.
- #9 + #10 — self-service mirrors.
- #14 AM HA — independent; slot anywhere in Phase 4.

### Validation gates between phases

- **End Phase 1**: signals V.1 + signals V.7 (allowlist enforced; dual-label visible on series).
- **End Phase 2**: signals V.2 + signals V.3 + ops V.2 (cross-tenant query; federation policy; Ruler→AM smoke).
- **End Phase 3**: signals V.5/V.6 + ops V.3/V.4 (dashboards render; Grafana Alerting routes).
- **End Phase 4**: ops V.6 + V.7 + V.8 + V.9 + V.10 + V.11 (CNPG library; inhibit; mute; HA quorum; labeler; lint).

---

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
| 8 | `cluster` label semantics | **Dual-label emit: `cluster = ${REGION}` AND `region = ${REGION}`** — community dashboards (k8s-resources-cluster.json etc.) keep working on `$cluster`; new fleet dashboards query semantically clearer `region`. Zero rename to existing dashboard JSON. Both labels carry identical value per series. CNPG cluster name comes from the `pod` label (`pg-eu-1`, `pg-us-2`, …). See Part F.1 audit. |
| 9 | Recording-rule auto-apply | **Yes — bundle in `monitoring/mimir/rules-samples/` synced via existing `mimir.rules.kubernetes` path** (closes Out-of-Scope item from prior round) |
| 10 | Cross-region rule writer topology | **Per-region writer, federated reader** — each Alloy writes rules to its own tenant only; cross-region rollup rules use `source_tenants` annotation and live in the **hub** region's rules-samples; non-hub regions skip them (Part F.4) |
| 11 | Dashboard JSON D.3 + D.4 | **Inline full JSON in this plan** (was: sketch only) |

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
    url: ${MIMIR_QUERY_URL}
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

Embed `runtimeConfig` overrides directly. The chart serializes this map into a ConfigMap mounted at `/var/mimir/runtime.yaml` — no `--set-file` needed. Confirmed pattern: `mimir-distributed` chart's `runtimeConfig` field accepts a YAML map and renders it into a ConfigMap automatically.

```yaml
runtimeConfig:
  overrides:
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
    tempo:
      max_global_series_per_user: 200000
      max_query_lookback: 7d
      ingestion_rate: 50000
      query_federation:
        allowed_tenants: [tempo]

mimir:
  structuredConfig:
    # ... existing common/blocks_storage etc. ...
    runtime_config:
      file: /var/mimir/runtime.yaml
      reload_period: 10s
```

The standalone `monitoring/mimir/runtime-config.yaml` (B.1) is kept as a documentation reference only — it is NOT passed via `--set-file`. Its content is embedded above.

### B.3 Patch — `monitoring/setup.sh` (hub Mimir install)

No change needed to helm command — `runtimeConfig` is embedded in `mimir-values.yaml`:

```bash
helm_upgrade_install mimir \
    oci://ghcr.io/grafana/helm-charts/mimir-distributed \
    mimir "${CONTEXT_NAME}" "${MIMIR_CHART_VERSION}" \
    --values "${GIT_REPO_ROOT}/monitoring/mimir/mimir-values.yaml" \
    --set "mimir.structuredConfig.common.storage.s3.access_key_id=${RUSTFS_ROOT_USER}" \
    --set "mimir.structuredConfig.common.storage.s3.secret_access_key=${RUSTFS_ROOT_PASSWORD}"
```

No `--set-file` for runtimeConfig. The chart's `runtimeConfig` block in values.yaml is the canonical mechanism.

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

Source: `cnpg_*` metrics with external label `region = ${REGION}` (from Part F.1 dual-label emit) and `pod` label that carries the CNPG-cluster-name prefix (`pg-eu-1`, `pg-us-2`, …).

> Label semantics: CNPG operator's instance exporter does NOT emit a `cluster` label on metrics — only `namespace`, `pod`, and CNPG-specific labels. So no actual collision with Alloy's external_label. The pre-existing dashboards (`k8s-resources-cluster.json`) and community CNPG dashboards already work with `cluster = ${REGION}` semantics. Part F.1 documents the audit. Fleet dashboards here use `region` for readability.

#### D.1.1 Pre-req patch — `monitoring/alloy/alloy-config.river.tpl`

Dual-label emit so both old and new dashboards work side-by-side:

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
  external_labels = {
    cluster = "${REGION}",   // existing — keep for community dashboards
    region  = "${REGION}",   // new — readable name for fleet dashboards
  }
}
```

Storage cost: ~zero. The two labels carry identical value per series, Mimir compresses redundantly-valued labels efficiently in the TSDB. No relabeling needed at query time.

> Tempo `metricsGenerator` `traces_*` series ALSO need the `region` label for D.4's `by (region, pod)` join across `mimir-fleet` + `mimir-tempo`. Verify `monitoring/tempo/tempo-values.yaml` `metricsGenerator.processor.spanmetrics.dimensions` includes the `cluster` resource attribute (already set per kind-mimir-plan.md D.7) — then add a Tempo `external_labels` block in the same patch to emit `region = ${REGION}` alongside `cluster`. **Add to Part F.2 verification.**

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
          "id": 1,
          "title": "Clusters by Region",
          "type": "stat",
          "gridPos": {"h": 4, "w": 6, "x": 0, "y": 0},
          "datasource": {"type":"prometheus","uid":"mimir-fleet"},
          "fieldConfig": {"defaults": {"unit": "short", "color": {"mode": "thresholds"}, "thresholds": {"mode": "absolute", "steps": [{"color": "blue", "value": null}]}}, "overrides": []},
          "options": {"reduceOptions": {"calcs": ["lastNotNull"]}, "orientation": "auto", "textMode": "auto", "colorMode": "background", "graphMode": "none"},
          "targets": [
            {"expr": "count(count by (region, cluster) (cnpg_pg_replication_lag{region=~\"$region\"}))", "legendFormat": ""}
          ]
        },
        {
          "id": 2,
          "title": "Cluster Status Table",
          "type": "table",
          "gridPos": {"h": 8, "w": 18, "x": 6, "y": 0},
          "datasource": {"type":"prometheus","uid":"mimir-fleet"},
          "fieldConfig": {"defaults": {}, "overrides": [{"matcher": {"id": "byName", "options": "Value"}, "properties": [{"id": "displayName", "value": "Lag (s)"}, {"id": "unit", "value": "s"}]}]},
          "options": {"sortBy": [{"displayName": "region"}], "footer": {"show": false}},
          "targets": [
            {"expr": "max by (region, cluster, namespace) (cnpg_pg_replication_lag{region=~\"$region\"})", "format": "table", "instant": true, "legendFormat": ""}
          ],
          "transformations": [{"id": "organize", "options": {"excludeByName": {"Time": true, "__name__": true, "job": true}}}]
        },
        {
          "id": 3,
          "title": "WAL Lag — max replication delay",
          "type": "timeseries",
          "gridPos": {"h": 8, "w": 24, "x": 0, "y": 8},
          "datasource": {"type":"prometheus","uid":"mimir-fleet"},
          "fieldConfig": {"defaults": {"unit": "s", "custom": {"lineWidth": 2, "fillOpacity": 5}}, "overrides": []},
          "options": {"legend": {"calcs": ["lastNotNull", "max"], "displayMode": "table", "placement": "right"}, "tooltip": {"mode": "multi"}},
          "targets": [
            {"expr": "max by (region, cluster) (cnpg_pg_replication_lag{region=~\"$region\"})", "legendFormat": "{{region}}/{{cluster}}"}
          ]
        },
        {
          "id": 4,
          "title": "Primary Pod per Cluster",
          "type": "table",
          "gridPos": {"h": 6, "w": 24, "x": 0, "y": 16},
          "datasource": {"type":"prometheus","uid":"mimir-fleet"},
          "fieldConfig": {"defaults": {}, "overrides": []},
          "options": {"sortBy": [{"displayName": "region"}], "footer": {"show": false}},
          "targets": [
            {"expr": "max by (region, cluster, pod, role) (cnpg_pg_replication_lag{role=\"primary\",region=~\"$region\"})", "format": "table", "instant": true, "legendFormat": ""}
          ],
          "transformations": [{"id": "organize", "options": {"excludeByName": {"Time": true, "__name__": true, "job": true}}}]
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
          "id": 1,
          "title": "Request rate (req/s) per region",
          "type": "timeseries",
          "gridPos": {"h": 8, "w": 24, "x": 0, "y": 0},
          "datasource": {"type":"prometheus","uid":"mimir-tempo"},
          "fieldConfig": {"defaults": {"unit": "reqps", "custom": {"lineWidth": 2, "fillOpacity": 5}}, "overrides": []},
          "options": {"legend": {"calcs": ["lastNotNull"], "displayMode": "table", "placement": "right"}, "tooltip": {"mode": "multi"}},
          "targets": [
            {"expr": "sum by (service_name) (rate(traces_spanmetrics_calls_total{service_name=~\"traefik-($region)\"}[1m]))", "legendFormat": "{{service_name}}"}
          ]
        },
        {
          "id": 2,
          "title": "5xx error rate per region",
          "type": "timeseries",
          "gridPos": {"h": 8, "w": 24, "x": 0, "y": 8},
          "datasource": {"type":"prometheus","uid":"mimir-tempo"},
          "fieldConfig": {"defaults": {"unit": "reqps", "custom": {"lineWidth": 2, "fillOpacity": 5}, "color": {"mode": "fixed", "fixedColor": "red"}}, "overrides": []},
          "options": {"legend": {"calcs": ["lastNotNull"], "displayMode": "table", "placement": "right"}, "tooltip": {"mode": "multi"}},
          "targets": [
            {"expr": "sum by (service_name) (rate(traces_spanmetrics_calls_total{service_name=~\"traefik-($region)\",status_code=~\"5..\"}[1m]))", "legendFormat": "{{service_name}}"}
          ]
        },
        {
          "id": 3,
          "title": "p95 latency per region",
          "type": "timeseries",
          "gridPos": {"h": 8, "w": 24, "x": 0, "y": 16},
          "datasource": {"type":"prometheus","uid":"mimir-tempo"},
          "fieldConfig": {"defaults": {"unit": "s", "custom": {"lineWidth": 2, "fillOpacity": 5}}, "overrides": []},
          "options": {"legend": {"calcs": ["lastNotNull", "max"], "displayMode": "table", "placement": "right"}, "tooltip": {"mode": "multi"}},
          "targets": [
            {"expr": "histogram_quantile(0.95, sum by (le, service_name) (rate(traces_spanmetrics_latency_bucket{service_name=~\"traefik-($region)\"}[5m])))", "legendFormat": "{{service_name}}"}
          ]
        }
      ]
    }
```

### D.3 New file — `monitoring/grafana/grafana_dashboard_fleet_k8s_capacity.yaml`

**K8s node/cluster capacity fleet**: CPU/memory/disk/pod-pressure across regions.

```yaml
apiVersion: grafana.integreatly.org/v1beta1
kind: GrafanaDashboard
metadata:
  name: fleet-k8s-capacity
  namespace: grafana
spec:
  instanceSelector:
    matchLabels:
      dashboards: grafana
  json: |
    {
      "title": "K8s Capacity Fleet",
      "uid": "fleet-k8s-capacity",
      "schemaVersion": 39,
      "refresh": "30s",
      "templating": {
        "list": [
          {
            "name": "region",
            "type": "query",
            "datasource": {"type": "prometheus", "uid": "mimir-fleet"},
            "query": "label_values(kube_node_status_allocatable{resource=\"cpu\"}, region)",
            "includeAll": true,
            "multi": true,
            "refresh": 2,
            "current": {}
          }
        ]
      },
      "panels": [
        {
          "id": 1,
          "title": "Allocatable CPU (cores)",
          "type": "stat",
          "gridPos": {"h": 4, "w": 6, "x": 0, "y": 0},
          "datasource": {"type": "prometheus", "uid": "mimir-fleet"},
          "fieldConfig": {"defaults": {"unit": "short", "decimals": 1, "color": {"mode": "thresholds"}, "thresholds": {"mode": "absolute", "steps": [{"color": "blue", "value": null}]}}, "overrides": []},
          "options": {"reduceOptions": {"calcs": ["lastNotNull"]}, "orientation": "auto", "textMode": "auto", "colorMode": "background", "graphMode": "none"},
          "targets": [{"expr": "sum(kube_node_status_allocatable{resource=\"cpu\",region=~\"$region\"})", "legendFormat": ""}]
        },
        {
          "id": 2,
          "title": "CPU Utilisation",
          "type": "stat",
          "gridPos": {"h": 4, "w": 6, "x": 6, "y": 0},
          "datasource": {"type": "prometheus", "uid": "mimir-fleet"},
          "fieldConfig": {"defaults": {"unit": "percentunit", "color": {"mode": "thresholds"}, "thresholds": {"mode": "absolute", "steps": [{"color": "green", "value": null}, {"color": "yellow", "value": 0.7}, {"color": "red", "value": 0.9}]}}, "overrides": []},
          "options": {"reduceOptions": {"calcs": ["lastNotNull"]}, "orientation": "auto", "textMode": "auto", "colorMode": "background", "graphMode": "none"},
          "targets": [{"expr": "sum(rate(node_cpu_seconds_total{mode!=\"idle\",region=~\"$region\"}[5m])) / sum(kube_node_status_allocatable{resource=\"cpu\",region=~\"$region\"})"}]
        },
        {
          "id": 3,
          "title": "Memory Available",
          "type": "stat",
          "gridPos": {"h": 4, "w": 6, "x": 12, "y": 0},
          "datasource": {"type": "prometheus", "uid": "mimir-fleet"},
          "fieldConfig": {"defaults": {"unit": "bytes", "color": {"mode": "thresholds"}, "thresholds": {"mode": "absolute", "steps": [{"color": "red", "value": null}, {"color": "yellow", "value": 1073741824}, {"color": "green", "value": 4294967296}]}}, "overrides": []},
          "options": {"reduceOptions": {"calcs": ["lastNotNull"]}, "orientation": "auto", "colorMode": "background", "graphMode": "none"},
          "targets": [{"expr": "sum(node_memory_MemAvailable_bytes{region=~\"$region\"})"}]
        },
        {
          "id": 4,
          "title": "Running Pods",
          "type": "stat",
          "gridPos": {"h": 4, "w": 6, "x": 18, "y": 0},
          "datasource": {"type": "prometheus", "uid": "mimir-fleet"},
          "fieldConfig": {"defaults": {"unit": "short", "color": {"mode": "thresholds"}, "thresholds": {"mode": "absolute", "steps": [{"color": "blue", "value": null}]}}, "overrides": []},
          "options": {"reduceOptions": {"calcs": ["lastNotNull"]}, "orientation": "auto", "colorMode": "background", "graphMode": "none"},
          "targets": [{"expr": "count(kube_pod_info{region=~\"$region\"})"}]
        },
        {
          "id": 5,
          "title": "CPU Usage per Region",
          "type": "timeseries",
          "gridPos": {"h": 8, "w": 12, "x": 0, "y": 4},
          "datasource": {"type": "prometheus", "uid": "mimir-fleet"},
          "fieldConfig": {"defaults": {"unit": "short", "custom": {"lineWidth": 2, "fillOpacity": 5}}, "overrides": []},
          "options": {"legend": {"calcs": ["lastNotNull"], "displayMode": "table", "placement": "bottom"}, "tooltip": {"mode": "multi"}},
          "targets": [{"expr": "sum by (region) (rate(node_cpu_seconds_total{mode!=\"idle\",region=~\"$region\"}[5m]))", "legendFormat": "{{region}}"}]
        },
        {
          "id": 6,
          "title": "Memory Available per Region",
          "type": "timeseries",
          "gridPos": {"h": 8, "w": 12, "x": 12, "y": 4},
          "datasource": {"type": "prometheus", "uid": "mimir-fleet"},
          "fieldConfig": {"defaults": {"unit": "bytes", "custom": {"lineWidth": 2, "fillOpacity": 5}}, "overrides": []},
          "options": {"legend": {"calcs": ["lastNotNull"], "displayMode": "table", "placement": "bottom"}, "tooltip": {"mode": "multi"}},
          "targets": [{"expr": "sum by (region) (node_memory_MemAvailable_bytes{region=~\"$region\"})", "legendFormat": "{{region}}"}]
        },
        {
          "id": 7,
          "title": "Node Capacity Summary",
          "type": "table",
          "gridPos": {"h": 7, "w": 24, "x": 0, "y": 12},
          "datasource": {"type": "prometheus", "uid": "mimir-fleet"},
          "fieldConfig": {"defaults": {}, "overrides": [{"matcher": {"id": "byName", "options": "memory"}, "properties": [{"id": "unit", "value": "bytes"}]}]},
          "options": {"sortBy": [{"displayName": "region", "desc": false}], "footer": {"show": false}},
          "targets": [
            {"expr": "max by (region, node) (kube_node_status_allocatable{resource=\"cpu\",region=~\"$region\"})", "format": "table", "instant": true, "legendFormat": ""},
            {"expr": "max by (region, node) (kube_node_status_allocatable{resource=\"memory\",region=~\"$region\"})", "format": "table", "instant": true, "legendFormat": ""}
          ],
          "transformations": [
            {"id": "merge", "options": {}},
            {"id": "organize", "options": {"excludeByName": {"Time": true, "__name__": true, "job": true, "instance": true}}}
          ]
        },
        {
          "id": 8,
          "title": "Bound PVCs per Region",
          "type": "timeseries",
          "gridPos": {"h": 6, "w": 12, "x": 0, "y": 19},
          "datasource": {"type": "prometheus", "uid": "mimir-fleet"},
          "fieldConfig": {"defaults": {"unit": "short"}, "overrides": []},
          "options": {"legend": {"displayMode": "list", "placement": "bottom"}, "tooltip": {"mode": "multi"}},
          "targets": [{"expr": "sum by (region) (kube_persistentvolumeclaim_status_phase{phase=\"Bound\",region=~\"$region\"})", "legendFormat": "{{region}}"}]
        },
        {
          "id": 9,
          "title": "Pod Phase by Region",
          "type": "timeseries",
          "gridPos": {"h": 6, "w": 12, "x": 12, "y": 19},
          "datasource": {"type": "prometheus", "uid": "mimir-fleet"},
          "fieldConfig": {"defaults": {"unit": "short"}, "overrides": []},
          "options": {"legend": {"displayMode": "list", "placement": "bottom"}, "tooltip": {"mode": "multi"}},
          "targets": [{"expr": "sum by (region, phase) (kube_pod_status_phase{region=~\"$region\"})", "legendFormat": "{{region}}/{{phase}}"}]
        }
      ]
    }
```

### D.4 New file — `monitoring/grafana/grafana_dashboard_fleet_request_flow.yaml`

**Cross-region request flow**: Traefik → CNPG service-graph view.

Source: Tempo `service-graph` processor metrics — `traces_service_graph_request_total`, `traces_service_graph_request_failed_total`, `traces_service_graph_request_server_seconds_bucket`. Lives in tenant `tempo` (`mimir-tempo` DS). Plus join to region tenants for target service CPU (`mimir-fleet` DS).

> nodeGraph panel type requires Tempo datasource + `serviceMap` query type (Tempo-specific). For a playground, table+timeseries panels over `mimir-tempo` spanmetric data is equivalent and simpler to maintain. The nodeGraph approach is noted as an upgrade path.

```yaml
apiVersion: grafana.integreatly.org/v1beta1
kind: GrafanaDashboard
metadata:
  name: fleet-request-flow
  namespace: grafana
spec:
  instanceSelector:
    matchLabels:
      dashboards: grafana
  json: |
    {
      "title": "Cross-Region Request Flow",
      "uid": "fleet-request-flow",
      "schemaVersion": 39,
      "refresh": "30s",
      "templating": {
        "list": [
          {
            "name": "service",
            "type": "query",
            "datasource": {"type": "prometheus", "uid": "mimir-tempo"},
            "query": "label_values(traces_service_graph_request_total, client)",
            "includeAll": true,
            "multi": true,
            "refresh": 2,
            "current": {}
          }
        ]
      },
      "panels": [
        {
          "id": 1,
          "title": "Total Cross-Service Req/s",
          "type": "stat",
          "gridPos": {"h": 4, "w": 8, "x": 0, "y": 0},
          "datasource": {"type": "prometheus", "uid": "mimir-tempo"},
          "fieldConfig": {"defaults": {"unit": "reqps", "color": {"mode": "thresholds"}, "thresholds": {"mode": "absolute", "steps": [{"color": "blue", "value": null}]}}, "overrides": []},
          "options": {"reduceOptions": {"calcs": ["lastNotNull"]}, "orientation": "auto", "colorMode": "background", "graphMode": "none"},
          "targets": [{"expr": "sum(rate(traces_service_graph_request_total[1m]))", "legendFormat": ""}]
        },
        {
          "id": 2,
          "title": "Failed Cross-Service Req/s",
          "type": "stat",
          "gridPos": {"h": 4, "w": 8, "x": 8, "y": 0},
          "datasource": {"type": "prometheus", "uid": "mimir-tempo"},
          "fieldConfig": {"defaults": {"unit": "reqps", "color": {"mode": "thresholds"}, "thresholds": {"mode": "absolute", "steps": [{"color": "green", "value": null}, {"color": "yellow", "value": 0.01}, {"color": "red", "value": 0.1}]}}, "overrides": []},
          "options": {"reduceOptions": {"calcs": ["lastNotNull"]}, "orientation": "auto", "colorMode": "background", "graphMode": "none"},
          "targets": [{"expr": "sum(rate(traces_service_graph_request_failed_total[1m]))", "legendFormat": ""}]
        },
        {
          "id": 3,
          "title": "p95 Cross-Service Latency",
          "type": "stat",
          "gridPos": {"h": 4, "w": 8, "x": 16, "y": 0},
          "datasource": {"type": "prometheus", "uid": "mimir-tempo"},
          "fieldConfig": {"defaults": {"unit": "ms", "color": {"mode": "thresholds"}, "thresholds": {"mode": "absolute", "steps": [{"color": "green", "value": null}, {"color": "yellow", "value": 200}, {"color": "red", "value": 1000}]}}, "overrides": []},
          "options": {"reduceOptions": {"calcs": ["lastNotNull"]}, "orientation": "auto", "colorMode": "background", "graphMode": "none"},
          "targets": [{"expr": "histogram_quantile(0.95, sum by (le) (rate(traces_service_graph_request_server_seconds_bucket[5m]))) * 1000", "legendFormat": ""}]
        },
        {
          "id": 4,
          "title": "Request Rate per Service Pair",
          "type": "timeseries",
          "gridPos": {"h": 9, "w": 12, "x": 0, "y": 4},
          "datasource": {"type": "prometheus", "uid": "mimir-tempo"},
          "fieldConfig": {"defaults": {"unit": "reqps", "custom": {"lineWidth": 2, "fillOpacity": 5}}, "overrides": []},
          "options": {"legend": {"calcs": ["lastNotNull"], "displayMode": "table", "placement": "right"}, "tooltip": {"mode": "multi"}},
          "targets": [{"expr": "sum by (client, server) (rate(traces_service_graph_request_total{client=~\"$service\"}[1m]))", "legendFormat": "{{client}} → {{server}}"}]
        },
        {
          "id": 5,
          "title": "Error Rate per Service Pair",
          "type": "timeseries",
          "gridPos": {"h": 9, "w": 12, "x": 12, "y": 4},
          "datasource": {"type": "prometheus", "uid": "mimir-tempo"},
          "fieldConfig": {"defaults": {"unit": "reqps", "custom": {"lineWidth": 2, "fillOpacity": 5}, "color": {"mode": "fixed", "fixedColor": "red"}}, "overrides": []},
          "options": {"legend": {"calcs": ["lastNotNull"], "displayMode": "table", "placement": "right"}, "tooltip": {"mode": "multi"}},
          "targets": [{"expr": "sum by (client, server) (rate(traces_service_graph_request_failed_total{client=~\"$service\"}[1m]))", "legendFormat": "{{client}} → {{server}}"}]
        },
        {
          "id": 6,
          "title": "Service Graph — Request Flow Table",
          "type": "table",
          "gridPos": {"h": 8, "w": 16, "x": 0, "y": 13},
          "datasource": {"type": "prometheus", "uid": "mimir-tempo"},
          "fieldConfig": {"defaults": {}, "overrides": [
            {"matcher": {"id": "byName", "options": "req_rate"}, "properties": [{"id": "displayName", "value": "Req/s"}, {"id": "unit", "value": "reqps"}]},
            {"matcher": {"id": "byName", "options": "p95_ms"}, "properties": [{"id": "displayName", "value": "p95 (ms)"}, {"id": "unit", "value": "ms"}]}
          ]},
          "options": {"sortBy": [{"displayName": "Req/s", "desc": true}], "footer": {"show": false}},
          "targets": [
            {"expr": "sum by (client, server) (rate(traces_service_graph_request_total[5m]))", "format": "table", "instant": true, "legendFormat": ""},
            {"expr": "sum by (client, server) (rate(traces_service_graph_request_failed_total[5m]))", "format": "table", "instant": true, "legendFormat": ""},
            {"expr": "histogram_quantile(0.95, sum by (le, client, server) (rate(traces_service_graph_request_server_seconds_bucket[5m]))) * 1000", "format": "table", "instant": true, "legendFormat": ""}
          ],
          "transformations": [
            {"id": "merge", "options": {}},
            {"id": "organize", "options": {"excludeByName": {"Time": true, "__name__": true}}}
          ]
        },
        {
          "id": 7,
          "title": "Top CPU Pods (target service stress)",
          "type": "timeseries",
          "gridPos": {"h": 8, "w": 8, "x": 16, "y": 13},
          "datasource": {"type": "prometheus", "uid": "mimir-fleet"},
          "fieldConfig": {"defaults": {"unit": "short", "custom": {"lineWidth": 1}}, "overrides": []},
          "options": {"legend": {"displayMode": "list", "placement": "bottom"}, "tooltip": {"mode": "multi"}},
          "targets": [{"expr": "topk(5, sum by (region, pod) (rate(container_cpu_usage_seconds_total{container!=\"\",region=~\".+\"}[5m])))", "legendFormat": "{{region}}/{{pod}}"}]
        }
      ]
    }
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

#### `demo/yaml/self-service/grafana/grafanadashboard-fleet-cnpg-rbr-ver.yaml`

```yaml
apiVersion: grafana.integreatly.org/v1beta1
kind: GrafanaDashboard
metadata:
  name: fleet-cnpg-overview-rbr-ver
  namespace: grafana
spec:
  instanceSelector:
    matchLabels:
      dashboards: grafana-rbr-ver
  json: |
    {
      "title": "CNPG Fleet Overview",
      "uid": "fleet-cnpg-rbr-ver",
      "schemaVersion": 39,
      "refresh": "30s",
      "templating": {
        "list": [
          {
            "name": "region",
            "type": "query",
            "datasource": {"type":"prometheus","uid":"mimir-fleet-rbr-ver"},
            "query": "label_values(cnpg_pg_replication_lag, region)",
            "includeAll": true,
            "multi": true
          }
        ]
      },
      "panels": [
        {
          "id": 1,
          "title": "Clusters by Region",
          "type": "stat",
          "gridPos": {"h": 4, "w": 6, "x": 0, "y": 0},
          "datasource": {"type":"prometheus","uid":"mimir-fleet-rbr-ver"},
          "fieldConfig": {"defaults": {"unit": "short", "color": {"mode": "thresholds"}, "thresholds": {"mode": "absolute", "steps": [{"color": "blue", "value": null}]}}, "overrides": []},
          "options": {"reduceOptions": {"calcs": ["lastNotNull"]}, "orientation": "auto", "textMode": "auto", "colorMode": "background", "graphMode": "none"},
          "targets": [
            {"expr": "count(count by (region, cluster) (cnpg_pg_replication_lag{region=~\"$region\"}))", "legendFormat": ""}
          ]
        },
        {
          "id": 2,
          "title": "Cluster Status Table",
          "type": "table",
          "gridPos": {"h": 8, "w": 18, "x": 6, "y": 0},
          "datasource": {"type":"prometheus","uid":"mimir-fleet-rbr-ver"},
          "fieldConfig": {"defaults": {}, "overrides": [{"matcher": {"id": "byName", "options": "Value"}, "properties": [{"id": "displayName", "value": "Lag (s)"}, {"id": "unit", "value": "s"}]}]},
          "options": {"sortBy": [{"displayName": "region"}], "footer": {"show": false}},
          "targets": [
            {"expr": "max by (region, cluster, namespace) (cnpg_pg_replication_lag{region=~\"$region\"})", "format": "table", "instant": true, "legendFormat": ""}
          ],
          "transformations": [{"id": "organize", "options": {"excludeByName": {"Time": true, "__name__": true, "job": true}}}]
        },
        {
          "id": 3,
          "title": "WAL Lag — max replication delay",
          "type": "timeseries",
          "gridPos": {"h": 8, "w": 24, "x": 0, "y": 8},
          "datasource": {"type":"prometheus","uid":"mimir-fleet-rbr-ver"},
          "fieldConfig": {"defaults": {"unit": "s", "custom": {"lineWidth": 2, "fillOpacity": 5}}, "overrides": []},
          "options": {"legend": {"calcs": ["lastNotNull", "max"], "displayMode": "table", "placement": "right"}, "tooltip": {"mode": "multi"}},
          "targets": [
            {"expr": "max by (region, cluster) (cnpg_pg_replication_lag{region=~\"$region\"})", "legendFormat": "{{region}}/{{cluster}}"}
          ]
        },
        {
          "id": 4,
          "title": "Primary Pod per Cluster",
          "type": "table",
          "gridPos": {"h": 6, "w": 24, "x": 0, "y": 16},
          "datasource": {"type":"prometheus","uid":"mimir-fleet-rbr-ver"},
          "fieldConfig": {"defaults": {}, "overrides": []},
          "options": {"sortBy": [{"displayName": "region"}], "footer": {"show": false}},
          "targets": [
            {"expr": "max by (region, cluster, pod, role) (cnpg_pg_replication_lag{role=\"primary\",region=~\"$region\"})", "format": "table", "instant": true, "legendFormat": ""}
          ],
          "transformations": [{"id": "organize", "options": {"excludeByName": {"Time": true, "__name__": true, "job": true}}}]
        }
      ]
    }
```

#### `demo/yaml/self-service/grafana/grafanadashboard-fleet-traefik-red-rbr-ver.yaml`

```yaml
apiVersion: grafana.integreatly.org/v1beta1
kind: GrafanaDashboard
metadata:
  name: fleet-traefik-red-rbr-ver
  namespace: grafana
spec:
  instanceSelector:
    matchLabels:
      dashboards: grafana-rbr-ver
  json: |
    {
      "title": "Traefik Fleet — RED",
      "uid": "fleet-traefik-red-rbr-ver",
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
          "id": 1,
          "title": "Request rate (req/s) per region",
          "type": "timeseries",
          "gridPos": {"h": 8, "w": 24, "x": 0, "y": 0},
          "datasource": {"type":"prometheus","uid":"mimir-tempo-rbr-ver"},
          "fieldConfig": {"defaults": {"unit": "reqps", "custom": {"lineWidth": 2, "fillOpacity": 5}}, "overrides": []},
          "options": {"legend": {"calcs": ["lastNotNull"], "displayMode": "table", "placement": "right"}, "tooltip": {"mode": "multi"}},
          "targets": [
            {"expr": "sum by (service_name) (rate(traces_spanmetrics_calls_total{service_name=~\"traefik-($region)\"}[1m]))", "legendFormat": "{{service_name}}"}
          ]
        },
        {
          "id": 2,
          "title": "5xx error rate per region",
          "type": "timeseries",
          "gridPos": {"h": 8, "w": 24, "x": 0, "y": 8},
          "datasource": {"type":"prometheus","uid":"mimir-tempo-rbr-ver"},
          "fieldConfig": {"defaults": {"unit": "reqps", "custom": {"lineWidth": 2, "fillOpacity": 5}, "color": {"mode": "fixed", "fixedColor": "red"}}, "overrides": []},
          "options": {"legend": {"calcs": ["lastNotNull"], "displayMode": "table", "placement": "right"}, "tooltip": {"mode": "multi"}},
          "targets": [
            {"expr": "sum by (service_name) (rate(traces_spanmetrics_calls_total{service_name=~\"traefik-($region)\",status_code=~\"5..\"}[1m]))", "legendFormat": "{{service_name}}"}
          ]
        },
        {
          "id": 3,
          "title": "p95 latency per region",
          "type": "timeseries",
          "gridPos": {"h": 8, "w": 24, "x": 0, "y": 16},
          "datasource": {"type":"prometheus","uid":"mimir-tempo-rbr-ver"},
          "fieldConfig": {"defaults": {"unit": "s", "custom": {"lineWidth": 2, "fillOpacity": 5}}, "overrides": []},
          "options": {"legend": {"calcs": ["lastNotNull", "max"], "displayMode": "table", "placement": "right"}, "tooltip": {"mode": "multi"}},
          "targets": [
            {"expr": "histogram_quantile(0.95, sum by (le, service_name) (rate(traces_spanmetrics_latency_bucket{service_name=~\"traefik-($region)\"}[5m])))", "legendFormat": "{{service_name}}"}
          ]
        }
      ]
    }
```

#### `demo/yaml/self-service/grafana/grafanadashboard-fleet-k8s-capacity-rbr-ver.yaml`

```yaml
apiVersion: grafana.integreatly.org/v1beta1
kind: GrafanaDashboard
metadata:
  name: fleet-k8s-capacity-rbr-ver
  namespace: grafana
spec:
  instanceSelector:
    matchLabels:
      dashboards: grafana-rbr-ver
  json: |
    {
      "title": "K8s Capacity Fleet",
      "uid": "fleet-k8s-capacity-rbr-ver",
      "schemaVersion": 39,
      "refresh": "30s",
      "templating": {
        "list": [
          {
            "name": "region",
            "type": "query",
            "datasource": {"type": "prometheus", "uid": "mimir-fleet-rbr-ver"},
            "query": "label_values(kube_node_status_allocatable{resource=\"cpu\"}, region)",
            "includeAll": true,
            "multi": true,
            "refresh": 2,
            "current": {}
          }
        ]
      },
      "panels": [
        {
          "id": 1,
          "title": "Allocatable CPU (cores)",
          "type": "stat",
          "gridPos": {"h": 4, "w": 6, "x": 0, "y": 0},
          "datasource": {"type": "prometheus", "uid": "mimir-fleet-rbr-ver"},
          "fieldConfig": {"defaults": {"unit": "short", "decimals": 1, "color": {"mode": "thresholds"}, "thresholds": {"mode": "absolute", "steps": [{"color": "blue", "value": null}]}}, "overrides": []},
          "options": {"reduceOptions": {"calcs": ["lastNotNull"]}, "orientation": "auto", "textMode": "auto", "colorMode": "background", "graphMode": "none"},
          "targets": [{"expr": "sum(kube_node_status_allocatable{resource=\"cpu\",region=~\"$region\"})", "legendFormat": ""}]
        },
        {
          "id": 2,
          "title": "CPU Utilisation",
          "type": "stat",
          "gridPos": {"h": 4, "w": 6, "x": 6, "y": 0},
          "datasource": {"type": "prometheus", "uid": "mimir-fleet-rbr-ver"},
          "fieldConfig": {"defaults": {"unit": "percentunit", "color": {"mode": "thresholds"}, "thresholds": {"mode": "absolute", "steps": [{"color": "green", "value": null}, {"color": "yellow", "value": 0.7}, {"color": "red", "value": 0.9}]}}, "overrides": []},
          "options": {"reduceOptions": {"calcs": ["lastNotNull"]}, "orientation": "auto", "textMode": "auto", "colorMode": "background", "graphMode": "none"},
          "targets": [{"expr": "sum(rate(node_cpu_seconds_total{mode!=\"idle\",region=~\"$region\"}[5m])) / sum(kube_node_status_allocatable{resource=\"cpu\",region=~\"$region\"})"}]
        },
        {
          "id": 3,
          "title": "Memory Available",
          "type": "stat",
          "gridPos": {"h": 4, "w": 6, "x": 12, "y": 0},
          "datasource": {"type": "prometheus", "uid": "mimir-fleet-rbr-ver"},
          "fieldConfig": {"defaults": {"unit": "bytes", "color": {"mode": "thresholds"}, "thresholds": {"mode": "absolute", "steps": [{"color": "red", "value": null}, {"color": "yellow", "value": 1073741824}, {"color": "green", "value": 4294967296}]}}, "overrides": []},
          "options": {"reduceOptions": {"calcs": ["lastNotNull"]}, "orientation": "auto", "colorMode": "background", "graphMode": "none"},
          "targets": [{"expr": "sum(node_memory_MemAvailable_bytes{region=~\"$region\"})"}]
        },
        {
          "id": 4,
          "title": "Running Pods",
          "type": "stat",
          "gridPos": {"h": 4, "w": 6, "x": 18, "y": 0},
          "datasource": {"type": "prometheus", "uid": "mimir-fleet-rbr-ver"},
          "fieldConfig": {"defaults": {"unit": "short", "color": {"mode": "thresholds"}, "thresholds": {"mode": "absolute", "steps": [{"color": "blue", "value": null}]}}, "overrides": []},
          "options": {"reduceOptions": {"calcs": ["lastNotNull"]}, "orientation": "auto", "colorMode": "background", "graphMode": "none"},
          "targets": [{"expr": "count(kube_pod_info{region=~\"$region\"})"}]
        },
        {
          "id": 5,
          "title": "CPU Usage per Region",
          "type": "timeseries",
          "gridPos": {"h": 8, "w": 12, "x": 0, "y": 4},
          "datasource": {"type": "prometheus", "uid": "mimir-fleet-rbr-ver"},
          "fieldConfig": {"defaults": {"unit": "short", "custom": {"lineWidth": 2, "fillOpacity": 5}}, "overrides": []},
          "options": {"legend": {"calcs": ["lastNotNull"], "displayMode": "table", "placement": "bottom"}, "tooltip": {"mode": "multi"}},
          "targets": [{"expr": "sum by (region) (rate(node_cpu_seconds_total{mode!=\"idle\",region=~\"$region\"}[5m]))", "legendFormat": "{{region}}"}]
        },
        {
          "id": 6,
          "title": "Memory Available per Region",
          "type": "timeseries",
          "gridPos": {"h": 8, "w": 12, "x": 12, "y": 4},
          "datasource": {"type": "prometheus", "uid": "mimir-fleet-rbr-ver"},
          "fieldConfig": {"defaults": {"unit": "bytes", "custom": {"lineWidth": 2, "fillOpacity": 5}}, "overrides": []},
          "options": {"legend": {"calcs": ["lastNotNull"], "displayMode": "table", "placement": "bottom"}, "tooltip": {"mode": "multi"}},
          "targets": [{"expr": "sum by (region) (node_memory_MemAvailable_bytes{region=~\"$region\"})", "legendFormat": "{{region}}"}]
        },
        {
          "id": 7,
          "title": "Node Capacity Summary",
          "type": "table",
          "gridPos": {"h": 7, "w": 24, "x": 0, "y": 12},
          "datasource": {"type": "prometheus", "uid": "mimir-fleet-rbr-ver"},
          "fieldConfig": {"defaults": {}, "overrides": [{"matcher": {"id": "byName", "options": "memory"}, "properties": [{"id": "unit", "value": "bytes"}]}]},
          "options": {"sortBy": [{"displayName": "region", "desc": false}], "footer": {"show": false}},
          "targets": [
            {"expr": "max by (region, node) (kube_node_status_allocatable{resource=\"cpu\",region=~\"$region\"})", "format": "table", "instant": true, "legendFormat": ""},
            {"expr": "max by (region, node) (kube_node_status_allocatable{resource=\"memory\",region=~\"$region\"})", "format": "table", "instant": true, "legendFormat": ""}
          ],
          "transformations": [
            {"id": "merge", "options": {}},
            {"id": "organize", "options": {"excludeByName": {"Time": true, "__name__": true, "job": true, "instance": true}}}
          ]
        },
        {
          "id": 8,
          "title": "Bound PVCs per Region",
          "type": "timeseries",
          "gridPos": {"h": 6, "w": 12, "x": 0, "y": 19},
          "datasource": {"type": "prometheus", "uid": "mimir-fleet-rbr-ver"},
          "fieldConfig": {"defaults": {"unit": "short"}, "overrides": []},
          "options": {"legend": {"displayMode": "list", "placement": "bottom"}, "tooltip": {"mode": "multi"}},
          "targets": [{"expr": "sum by (region) (kube_persistentvolumeclaim_status_phase{phase=\"Bound\",region=~\"$region\"})", "legendFormat": "{{region}}"}]
        },
        {
          "id": 9,
          "title": "Pod Phase by Region",
          "type": "timeseries",
          "gridPos": {"h": 6, "w": 12, "x": 12, "y": 19},
          "datasource": {"type": "prometheus", "uid": "mimir-fleet-rbr-ver"},
          "fieldConfig": {"defaults": {"unit": "short"}, "overrides": []},
          "options": {"legend": {"displayMode": "list", "placement": "bottom"}, "tooltip": {"mode": "multi"}},
          "targets": [{"expr": "sum by (region, phase) (kube_pod_status_phase{region=~\"$region\"})", "legendFormat": "{{region}}/{{phase}}"}]
        }
      ]
    }
```

#### `demo/yaml/self-service/grafana/grafanadashboard-fleet-request-flow-rbr-ver.yaml`

```yaml
apiVersion: grafana.integreatly.org/v1beta1
kind: GrafanaDashboard
metadata:
  name: fleet-request-flow-rbr-ver
  namespace: grafana
spec:
  instanceSelector:
    matchLabels:
      dashboards: grafana-rbr-ver
  json: |
    {
      "title": "Cross-Region Request Flow",
      "uid": "fleet-request-flow-rbr-ver",
      "schemaVersion": 39,
      "refresh": "30s",
      "templating": {
        "list": [
          {
            "name": "service",
            "type": "query",
            "datasource": {"type": "prometheus", "uid": "mimir-tempo-rbr-ver"},
            "query": "label_values(traces_service_graph_request_total, client)",
            "includeAll": true,
            "multi": true,
            "refresh": 2,
            "current": {}
          }
        ]
      },
      "panels": [
        {
          "id": 1,
          "title": "Total Cross-Service Req/s",
          "type": "stat",
          "gridPos": {"h": 4, "w": 8, "x": 0, "y": 0},
          "datasource": {"type": "prometheus", "uid": "mimir-tempo-rbr-ver"},
          "fieldConfig": {"defaults": {"unit": "reqps", "color": {"mode": "thresholds"}, "thresholds": {"mode": "absolute", "steps": [{"color": "blue", "value": null}]}}, "overrides": []},
          "options": {"reduceOptions": {"calcs": ["lastNotNull"]}, "orientation": "auto", "colorMode": "background", "graphMode": "none"},
          "targets": [{"expr": "sum(rate(traces_service_graph_request_total[1m]))", "legendFormat": ""}]
        },
        {
          "id": 2,
          "title": "Failed Cross-Service Req/s",
          "type": "stat",
          "gridPos": {"h": 4, "w": 8, "x": 8, "y": 0},
          "datasource": {"type": "prometheus", "uid": "mimir-tempo-rbr-ver"},
          "fieldConfig": {"defaults": {"unit": "reqps", "color": {"mode": "thresholds"}, "thresholds": {"mode": "absolute", "steps": [{"color": "green", "value": null}, {"color": "yellow", "value": 0.01}, {"color": "red", "value": 0.1}]}}, "overrides": []},
          "options": {"reduceOptions": {"calcs": ["lastNotNull"]}, "orientation": "auto", "colorMode": "background", "graphMode": "none"},
          "targets": [{"expr": "sum(rate(traces_service_graph_request_failed_total[1m]))", "legendFormat": ""}]
        },
        {
          "id": 3,
          "title": "p95 Cross-Service Latency",
          "type": "stat",
          "gridPos": {"h": 4, "w": 8, "x": 16, "y": 0},
          "datasource": {"type": "prometheus", "uid": "mimir-tempo-rbr-ver"},
          "fieldConfig": {"defaults": {"unit": "ms", "color": {"mode": "thresholds"}, "thresholds": {"mode": "absolute", "steps": [{"color": "green", "value": null}, {"color": "yellow", "value": 200}, {"color": "red", "value": 1000}]}}, "overrides": []},
          "options": {"reduceOptions": {"calcs": ["lastNotNull"]}, "orientation": "auto", "colorMode": "background", "graphMode": "none"},
          "targets": [{"expr": "histogram_quantile(0.95, sum by (le) (rate(traces_service_graph_request_server_seconds_bucket[5m]))) * 1000", "legendFormat": ""}]
        },
        {
          "id": 4,
          "title": "Request Rate per Service Pair",
          "type": "timeseries",
          "gridPos": {"h": 9, "w": 12, "x": 0, "y": 4},
          "datasource": {"type": "prometheus", "uid": "mimir-tempo-rbr-ver"},
          "fieldConfig": {"defaults": {"unit": "reqps", "custom": {"lineWidth": 2, "fillOpacity": 5}}, "overrides": []},
          "options": {"legend": {"calcs": ["lastNotNull"], "displayMode": "table", "placement": "right"}, "tooltip": {"mode": "multi"}},
          "targets": [{"expr": "sum by (client, server) (rate(traces_service_graph_request_total{client=~\"$service\"}[1m]))", "legendFormat": "{{client}} → {{server}}"}]
        },
        {
          "id": 5,
          "title": "Error Rate per Service Pair",
          "type": "timeseries",
          "gridPos": {"h": 9, "w": 12, "x": 12, "y": 4},
          "datasource": {"type": "prometheus", "uid": "mimir-tempo-rbr-ver"},
          "fieldConfig": {"defaults": {"unit": "reqps", "custom": {"lineWidth": 2, "fillOpacity": 5}, "color": {"mode": "fixed", "fixedColor": "red"}}, "overrides": []},
          "options": {"legend": {"calcs": ["lastNotNull"], "displayMode": "table", "placement": "right"}, "tooltip": {"mode": "multi"}},
          "targets": [{"expr": "sum by (client, server) (rate(traces_service_graph_request_failed_total{client=~\"$service\"}[1m]))", "legendFormat": "{{client}} → {{server}}"}]
        },
        {
          "id": 6,
          "title": "Service Graph — Request Flow Table",
          "type": "table",
          "gridPos": {"h": 8, "w": 16, "x": 0, "y": 13},
          "datasource": {"type": "prometheus", "uid": "mimir-tempo-rbr-ver"},
          "fieldConfig": {"defaults": {}, "overrides": [
            {"matcher": {"id": "byName", "options": "req_rate"}, "properties": [{"id": "displayName", "value": "Req/s"}, {"id": "unit", "value": "reqps"}]},
            {"matcher": {"id": "byName", "options": "p95_ms"}, "properties": [{"id": "displayName", "value": "p95 (ms)"}, {"id": "unit", "value": "ms"}]}
          ]},
          "options": {"sortBy": [{"displayName": "Req/s", "desc": true}], "footer": {"show": false}},
          "targets": [
            {"expr": "sum by (client, server) (rate(traces_service_graph_request_total[5m]))", "format": "table", "instant": true, "legendFormat": ""},
            {"expr": "sum by (client, server) (rate(traces_service_graph_request_failed_total[5m]))", "format": "table", "instant": true, "legendFormat": ""},
            {"expr": "histogram_quantile(0.95, sum by (le, client, server) (rate(traces_service_graph_request_server_seconds_bucket[5m]))) * 1000", "format": "table", "instant": true, "legendFormat": ""}
          ],
          "transformations": [
            {"id": "merge", "options": {}},
            {"id": "organize", "options": {"excludeByName": {"Time": true, "__name__": true}}}
          ]
        },
        {
          "id": 7,
          "title": "Top CPU Pods (target service stress)",
          "type": "timeseries",
          "gridPos": {"h": 8, "w": 8, "x": 16, "y": 13},
          "datasource": {"type": "prometheus", "uid": "mimir-fleet-rbr-ver"},
          "fieldConfig": {"defaults": {"unit": "short", "custom": {"lineWidth": 1}}, "overrides": []},
          "options": {"legend": {"displayMode": "list", "placement": "bottom"}, "tooltip": {"mode": "multi"}},
          "targets": [{"expr": "topk(5, sum by (region, pod) (rate(container_cpu_usage_seconds_total{container!=\"\",region=~\".+\"}[5m])))", "legendFormat": "{{region}}/{{pod}}"}]
        }
      ]
    }
```

### E.2 Patch — `demo/self-service-setup.sh`

Add after the existing dashboard apply block:

```bash
kubectl --context "${LOCAL_CONTEXT}" apply -f \
    demo/yaml/self-service/grafana/grafanadashboard-fleet-cnpg-rbr-ver.yaml
kubectl --context "${LOCAL_CONTEXT}" apply -f \
    demo/yaml/self-service/grafana/grafanadashboard-fleet-traefik-red-rbr-ver.yaml
kubectl --context "${LOCAL_CONTEXT}" apply -f \
    demo/yaml/self-service/grafana/grafanadashboard-fleet-k8s-capacity-rbr-ver.yaml
kubectl --context "${LOCAL_CONTEXT}" apply -f \
    demo/yaml/self-service/grafana/grafanadashboard-fleet-request-flow-rbr-ver.yaml
```

---

## Part F — Label audit, recording rules, cross-region rule topology

Closes three Out-of-Scope items from the prior round. Each subsection is independent.

### F.1 `cluster` label audit + dual-label emit

**Audit result** (grep over `monitoring/grafana/`, `demo/yaml/self-service/grafana/`, all referenced community dashboards as of 2026-05-12):

| Source | Usage of `cluster` label | Action |
|---|---|---|
| `monitoring/grafana/dashboards/k8s-resources-cluster.json` | `cluster="$cluster"` (k8s cluster = region semantics) | No change |
| `monitoring/grafana/dashboards/kube-state.json` (kube-prometheus-stack) | `cluster=` filter on every panel | No change |
| `monitoring/grafana/grafana_dashboard.yaml` → upstream `cloudnative-pg/grafana-dashboards` JSON | No `cluster` label filter on CNPG metrics (uses `pod` label) | No change |
| `monitoring/cnpg/cnpg-cluster-wildcard-podmonitor.yaml` | No relabeling adds `cluster` label | No change — operator metrics only carry `pod` |
| New Part D dashboards (D.1–D.4) | Query `region` label for region grouping | Requires `region` label on series |

**Decision**: keep `cluster = ${REGION}` external label AND add `region = ${REGION}` as a second external label. Both carry identical value per series; community dashboards keep working; new fleet dashboards read the readable name.

**Patch — `monitoring/alloy/alloy-config.river.tpl`** (mirrors D.1.1 — single touch):

```hcl
external_labels = {
  cluster = "${REGION}",
  region  = "${REGION}",
}
```

**Patch — `monitoring/tempo/tempo-values.yaml`** — extend `metricsGenerator.externalLabels` block so span metrics also carry both labels:

```yaml
metricsGenerator:
  enabled: true
  config:
    processor:
      service_graphs:
        wait: 10s
      span_metrics:
        dimensions:
          - http.method
          - http.status_code
          - http.target
    storage:
      remote_write:
        - url: http://mimir-nginx.mimir.svc.cluster.local/api/v1/push
          headers:
            X-Scope-OrgID: tempo
          external_labels:
            cluster: ${REGION}
            region: ${REGION}
```

Already wraps via the Tempo Helm chart `--set` rendered in `monitoring/setup.sh`. Add `REGION` to the Tempo envsubst allowlist (it already substitutes `OBJECTSTORE_IP`).

**Verification**: Part F → V.7 (added in Verification section below).

---

### F.2 Recording-rule pre-aggregation (auto-applied)

Closes "Recording-rule pre-aggregation for fleet dashboard query speed" — was sample-only, now auto-applied.

#### F.2.1 New directory — `monitoring/mimir/rules-samples/`

Holds PrometheusRule CRs picked up by Alloy `mimir.rules.kubernetes` (already configured at `rule_selector {} rule_namespace_selector {}` — picks up every PrometheusRule in every namespace). Place rules in the `mimir` namespace (already labeled `monitoring/scrape=enabled` by ops plan A.2).

#### F.2.2 New file — `monitoring/mimir/rules-samples/fleet-recording-rules.yaml`

Pre-aggregates the heavy fleet queries used by D.1, D.3, D.4. Applied **only on the hub** region (per Part F.4 topology).

```yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: fleet-recording-rules
  namespace: mimir
  annotations:
    monitoring.grafana.com/source_tenants: "local|eu|us"   # consumed by Alloy mimir.rules.kubernetes (Part C)
spec:
  groups:
    - name: fleet.cnpg
      interval: 30s
      rules:
        - record: fleet:cnpg_pg_replication_lag:max
          expr: max by (region, pod, namespace) (cnpg_pg_replication_lag)
        - record: fleet:cnpg_backends:sum
          expr: sum by (region, pod) (cnpg_backends_total)
        - record: fleet:cnpg_pg_stat_archiver_failed:rate5m
          expr: rate(cnpg_pg_stat_archiver_failed_count[5m])
    - name: fleet.k8s
      interval: 30s
      rules:
        - record: fleet:node_cpu_busy:rate5m
          expr: sum by (region) (rate(node_cpu_seconds_total{mode!="idle"}[5m]))
        - record: fleet:node_memory_available_bytes:sum
          expr: sum by (region) (node_memory_MemAvailable_bytes)
        - record: fleet:pod_running:count
          expr: sum by (region) (kube_pod_status_phase{phase="Running"})
        - record: fleet:pvc_bound:sum
          expr: sum by (region) (kube_persistentvolumeclaim_status_phase{phase="Bound"})
    - name: fleet.traefik
      interval: 30s
      rules:
        - record: fleet:traefik_requests:rate1m
          expr: sum by (region, service_name) (rate(traces_spanmetrics_calls_total{service_name=~"traefik-.+"}[1m]))
        - record: fleet:traefik_5xx:rate1m
          expr: sum by (region, service_name) (rate(traces_spanmetrics_calls_total{service_name=~"traefik-.+",status_code=~"5.."}[1m]))
        - record: fleet:traefik_latency_p95:histogram_5m
          expr: histogram_quantile(0.95, sum by (le, region, service_name) (rate(traces_spanmetrics_latency_bucket{service_name=~"traefik-.+"}[5m])))
    - name: fleet.servicegraph
      interval: 30s
      rules:
        - record: fleet:servicegraph_requests:rate1m
          expr: sum by (client, server) (rate(traces_service_graph_request_total[1m]))
        - record: fleet:servicegraph_failed:rate1m
          expr: sum by (client, server) (rate(traces_service_graph_request_failed_total[1m]))
        - record: fleet:servicegraph_latency_p95:histogram_5m
          expr: histogram_quantile(0.95, sum by (le, client, server) (rate(traces_service_graph_request_server_seconds_bucket[5m])))
```

> The `monitoring.grafana.com/source_tenants` annotation is honored by Alloy `mimir.rules.kubernetes` (per Part C.1) — Mimir Ruler evaluates the rule **federated** across the listed tenants and writes the output to the current tenant (`${REGION}`, hub-only).

#### F.2.3 Optional dashboard rewrite — use recording rules

Dashboard panels in D.1, D.3, D.4 can be retargeted to the `fleet:*` recording-rule series for ~5–20× query-speed improvement on multi-region setups. Keep the raw-query form as the primary expr and document the recording-rule alternative inline. **Execution-time tweak — not a blocker.**

#### F.2.4 Patch — `monitoring/setup.sh` (hub apply)

```bash
if [[ "${region}" == "${HUB_REGION}" ]]; then
    echo "📊 Applying Mimir fleet recording rules (hub only)..."
    kubectl --context "${CONTEXT_NAME}" apply -f \
        "${GIT_REPO_ROOT}/monitoring/mimir/rules-samples/fleet-recording-rules.yaml"
fi
```

Alloy on the hub then syncs this PrometheusRule into Mimir Ruler via `mimir.rules.kubernetes` (pre-existing wiring — no Alloy config change).

---

### F.3 Mimir Ruler tenant-write topology — diagram

```
┌─────────────────┐         ┌─────────────────┐         ┌─────────────────┐
│  Alloy (eu)     │         │  Alloy (us)     │         │  Alloy (local)  │
│  rules → tenant │         │  rules → tenant │         │  rules → tenant │
│      "eu"       │         │      "us"       │         │     "local"     │
└────────┬────────┘         └────────┬────────┘         └────────┬────────┘
         │                           │                           │
         └───────────┐               │             ┌─────────────┘
                     │               │             │
                     ▼               ▼             ▼
                  ┌──────────────────────────────────────┐
                  │  Hub Mimir Ruler                     │
                  │  - Tenant "eu" rules  → eval in "eu" │
                  │  - Tenant "us" rules  → eval in "us" │
                  │  - Tenant "local" rules              │
                  │  - Fleet rules (source_tenants:      │
                  │    eu|us|local) → eval federated,    │
                  │    written to tenant "local"         │
                  │    (hub region's tenant)             │
                  └──────────────────────────────────────┘
```

### F.4 Cross-region rule writer topology — locked

Per locked decision #10:

| Where | Writer | Reader | Notes |
|---|---|---|---|
| Per-region rules (alerting / per-tenant recording) | Each region's Alloy → its own tenant | Each region's Grafana (`mimir` DS, tenant=region) | Pre-existing behavior |
| Fleet rollup recording rules (Part F.2) | **Hub Alloy only** → tenant `${HUB_REGION}` (`local`) | Both Grafana instances via `mimir-fleet` DS (pipe-separated tenants) | Annotation `monitoring.grafana.com/source_tenants: "local\|eu\|us"` tells Mimir Ruler to evaluate federated; output lands in hub's tenant |
| Fleet alerting rules (ops plan Part C) | **Hub Grafana Unified Alerting** (evaluates via Mimir DS, not Mimir Ruler) | n/a — alert routes directly into Grafana Alerting → contact points | Pre-existing — see ops plan |

**Why hub-only for fleet recording rules**: a non-hub region whose Alloy also applied the same PrometheusRule would create *N* duplicate rule groups in Mimir Ruler (one per tenant), each evaluating the federated query and writing to its own tenant. Wasteful + ambiguous. Hub-only emission is the simplest "single writer, single tenant for output" topology.

**Implementation gate** in `monitoring/setup.sh` F.2.4 already uses `if [[ "${region}" == "${HUB_REGION}" ]]`.

**Non-hub safety check**: `monitoring/setup.sh` also needs to **delete** any stray `fleet-recording-rules` PrometheusRule from non-hub regions (e.g., if previously applied via a different code path):

```bash
if [[ "${region}" != "${HUB_REGION}" ]]; then
    kubectl --context "${CONTEXT_NAME}" -n mimir delete prometheusrule \
        fleet-recording-rules --ignore-not-found
fi
```

### F.5 Watchpoint — `source_tenants` precedence

When a rule group's annotation is `monitoring.grafana.com/source_tenants: "local|eu|us"` AND the tenant in `mimir.rules.kubernetes "rules" { tenant_id = "${REGION}" }` is `local` (hub), Mimir Ruler:

1. Stores the rule under tenant `local`
2. At evaluation, uses the pipe-separated tenant list as `X-Scope-OrgID` (federated read)
3. Writes the resulting series back to tenant `local`

If the rule's annotation is missing/empty, Mimir falls back to single-tenant evaluation (just `local`). Verified in V.4 in the existing Verification section.

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

### V.7 Dual-label emit + recording rules

```bash
# Confirm dual labels on a CNPG series
curl -s -H 'X-Scope-OrgID: local' \
    'http://localhost:8080/prometheus/api/v1/query?query=cnpg_pg_replication_lag' | \
    jq '.data.result[0].metric | {cluster, region, pod}'
# expect: {"cluster":"local","region":"local","pod":"pg-local-1"}  (both labels present)

# Confirm Tempo span-metrics carry region too
curl -s -H 'X-Scope-OrgID: tempo' \
    'http://localhost:8080/prometheus/api/v1/query?query=traces_spanmetrics_calls_total' | \
    jq '.data.result[0].metric | {cluster, region, service_name}'
# expect: both labels present + service_name=traefik-local

# Recording rule output appears in hub tenant only
for t in local eu us; do
  echo "--- tenant $t ---"
  curl -s -H "X-Scope-OrgID: $t" \
      'http://localhost:8080/prometheus/api/v1/query?query=fleet:cnpg_pg_replication_lag:max' | \
      jq '.data.result | length'
done
# expect: local > 0, eu = 0, us = 0  (hub-only writer)

# Federated read via mimir-fleet DS sees the rule from hub tenant
curl -s -H 'X-Scope-OrgID: local|eu|us' \
    'http://localhost:8080/prometheus/api/v1/query?query=fleet:cnpg_pg_replication_lag:max' | \
    jq '.data.result | length'
# expect: > 0
```

### V.8 Non-hub fleet-rule cleanup idempotency

```bash
# After running ./monitoring/setup.sh, non-hub regions must NOT have the fleet PrometheusRule
for ctx in kind-k8s-eu kind-k8s-us; do
  kubectl --context "$ctx" -n mimir get prometheusrule fleet-recording-rules 2>&1 | grep -q 'NotFound' \
    && echo "$ctx: clean ✓" \
    || echo "$ctx: STRAY RULE — re-run setup.sh to purge"
done
```

---

## File-level Changeset Summary

### Modify

- `monitoring/grafana/kustomization.yaml` — add 4 fleet dashboards
- `monitoring/setup.sh` — fleet DS apply; query IngressRoute apply; URL switch (no `--set-file` for runtimeConfig — embedded directly)
- `monitoring/mimir/mimir-values.yaml` — `runtimeConfig.overrides` map embedded directly (tenant overrides for local/eu/us/tempo)
- `monitoring/alloy/alloy-config.river.tpl` — dual-label emit `cluster + region` (F.1, replaces prior "rename" approach)
- `monitoring/tempo/tempo-values.yaml` — `metricsGenerator.storage.remote_write[].external_labels` adds `cluster + region` (F.1)
- `monitoring/setup.sh` — Tempo envsubst gains `${REGION}`; hub-only apply of `fleet-recording-rules.yaml`; non-hub purge of stray rule (F.2.4 / F.4)
- `monitoring/README.md` — federation section + fleet DS docs + dual-label note + recording-rule topology
- `demo/self-service-setup.sh` — apply fleet DS + 4 fleet dashboards for rbr-ver

### Create

- `monitoring/grafana/grafana_datasource_mimir_fleet.yaml.tpl`
- `monitoring/grafana/grafana_dashboard_fleet_cnpg.yaml`
- `monitoring/grafana/grafana_dashboard_fleet_traefik_red.yaml`
- `monitoring/grafana/grafana_dashboard_fleet_k8s_capacity.yaml`
- `monitoring/grafana/grafana_dashboard_fleet_request_flow.yaml`
- `monitoring/mimir/runtime-config.yaml` (documentation reference only — content embedded in `mimir-values.yaml`)
- `monitoring/mimir/ingressroute-query.yaml.tpl` (multi-region only)
- `monitoring/mimir/rules-samples/fleet-rules.yaml` (sample federated rule — Part C.2)
- `monitoring/mimir/rules-samples/fleet-recording-rules.yaml` (pre-aggregation, auto-applied on hub — Part F.2)
- `demo/yaml/self-service/grafana/grafanadatasource-mimir-fleet-rbr-ver.yaml.tpl`
- `demo/yaml/self-service/grafana/grafanadashboard-fleet-{cnpg,traefik-red,k8s-capacity,request-flow}-rbr-ver.yaml`

### Cross-plan touchpoints

- `monitoring-prom-removal-plan.md` Part A.1 — superseded by F.1 dual-label emit (no rename; `cluster` + `region` both present in `external_labels`)
- `monitoring-prom-removal-plan.md` Part C — all DS templates now consume `${MIMIR_QUERY_URL}` instead of hardcoded service URL (so non-hub Grafana works)
- `monitoring-ops-plan.md` Part F (mute timings) — uses same Grafana Alerting CR layer as fleet dashboards' folder routing

---

## Risks / Watchpoints

| Risk | Mitigation |
|---|---|
| `runtimeConfig.overrides` embedded directly in `mimir-values.yaml` — YAML map nesting | Confirmed chart accepts YAML map (not string) for `runtimeConfig`. Embedded directly avoids `--set-file` escaping pitfalls. Validate shape with `helm show values ... \| yq .runtimeConfig` before upgrade. |
| Dual-label emit doubles label cardinality budget | False — `cluster` and `region` carry identical value per series, Mimir's TSDB compresses redundantly-valued label pairs. Negligible storage/RAM impact. |
| Pipe-separated `X-Scope-OrgID: a\|b\|c` requires `tenant_federation.enabled: true` in Mimir AND `query_federation.allowed_tenants` listing each | Already enabled (kind-mimir-plan.md). Runtime-config Part B.1 sets `allowed_tenants`. Verify via V.3. |
| Tempo `service-graph` processor not enabled → request-flow dashboard empty | `kind-mimir-plan.md` D.3 enables `metricsGenerator.config` with `[service-graphs, span-metrics]` processors. Verify pod env. |
| Span-metrics `service_name` carries region suffix (`traefik-eu`) — `service_name=~"traefik-($region)"` regex requires region var | Documented in D.2 panel queries. |
| Non-hub Grafana querying via Traefik adds latency | sslip.io traversal adds ~50-100ms. Acceptable for playground. For prod, use direct IngressRoute or dedicated mTLS path. |
| `mimir-fleet` reads region tenants but not `tempo` — RED dashboard uses `mimir-tempo` DS — two-DS dashboard | Grafana supports multi-DS dashboards (per-panel selection). Documented. |
| `runtime_config.file` reload period (10s) too aggressive on slow disks | Acceptable for playground. Tune to `30s` if hub cluster shows reload churn. |
| `monitoring.grafana.com/source_tenants` annotation might not be honored if `mimir.rules.kubernetes` is on older Alloy version | Alloy 1.8.0 ships this. Memory confirms. |
| Cross-tenant rule output gets stamped with `tenant_id=${REGION}` even if reading from tempo | Documented; recording-rule output owner-tenant is the writing region, not source. Consumers of `fleet:*` recording rules read them via `mimir-fleet` DS or via the hub region's `mimir` DS. |
| Querying `mimir-fleet` with very broad PromQL (`count(up)`) returns ALL fleet series — high RAM on querier | Acceptable for 3-region playground. Mimir limits already set `max_global_series_per_user: 500000`. |
| Grafana DS `secureJsonData.httpHeaderValue1` doesn't accept pipe characters in some operator versions | Standard string field — pipes work. Test via V.2 first. |
| `fleet-recording-rules` PrometheusRule applied on non-hub regions duplicates evaluation per tenant | F.4 setup.sh purges stray rules on non-hub; V.8 verifies. If the file is committed to a Kustomization picked up by non-hub regions, gate the kustomization or move the file to a hub-only directory tree. |
| `fleet:*` recording rules reference labels (`region`, `service_name`) not yet present on legacy series | F.1 dual-label emit must land **before** F.2 rule apply, or the rule output will be empty. Setup.sh ordering: Alloy/Tempo reload → wait 30s → apply rules. |
| `traces_spanmetrics_calls_total` does NOT emit `region` until Tempo `metricsGenerator.storage.remote_write.external_labels` includes it | F.1 patches `monitoring/tempo/tempo-values.yaml` accordingly. Verify via V.7. |

---

## Suggested Commit Sequence

1. **Commit 1** — `feat(alloy,tempo): dual-label emit cluster+region for fleet readability`
   Touches: `monitoring/alloy/alloy-config.river.tpl`, `monitoring/tempo/tempo-values.yaml`, `monitoring/setup.sh` (Tempo envsubst gains `${REGION}`).
   Validation: V.7 dual-label check on `cnpg_*` and `traces_*` series; existing dashboards keep working (no `$cluster` rename needed).

2. **Commit 2** — `feat(mimir): runtime-config per-tenant overrides + federation allowlist`
   Touches: `monitoring/mimir/mimir-values.yaml` (`runtimeConfig.overrides` map embedded), `monitoring/mimir/runtime-config.yaml` (documentation copy, not applied), `monitoring/setup.sh`.
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

6. **Commit 6** — `feat(mimir): fleet recording rules + cross-region writer topology`
   Touches: `monitoring/mimir/rules-samples/fleet-rules.yaml` (new — sample federated alerting), `monitoring/mimir/rules-samples/fleet-recording-rules.yaml` (new — auto-applied on hub), `monitoring/setup.sh` (hub apply + non-hub purge), `monitoring/README.md` (topology section).
   Validation: V.4, V.7 (recording-rule output in hub tenant only), V.8 (non-hub purge idempotency).

---

## Out of Scope (next round)

- Per-tenant Grafana folders (org_mapping) — fleet dashboards live in default folder for both Grafana instances
- HTTPS for `mimir-query` IngressRoute — uses Vault PKI when wildcard certs land
- Per-tenant resource quotas (Mimir `ingestion_rate` per tenant override) beyond the defaults shipped in F.2 runtime_config
- Loki cross-tenant federation for log rollup (logs ingested per-region, queried per-region only)
- Multi-region Tempo distributors (currently hub-only; non-hub OTel collector pushes to hub via Traefik)
- `nodeGraph` panel type using Tempo DS `serviceMap` query — D.4 uses table+timeseries equivalent; upgrade path noted
