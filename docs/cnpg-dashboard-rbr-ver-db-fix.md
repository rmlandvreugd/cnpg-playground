# Fix — CNPG Dashboards for rbr-ver-db

_Last reviewed: 2026-05-11_

## Status

| Issue | Root Cause | Status |
|---|---|---|
| No Prometheus targets for rbr-ver-db | RC-1: no PodMonitors | **RESOLVED** — wildcard PodMonitors live |
| Dashboard metric names wrong | RC-2: missing `cnpg_` prefix, bad query names | **RESOLVED** — Fix 3 applied |
| Custom query metrics absent | RC-2: no custom monitoring configmap | **RESOLVED** — Fix 2 configmap created |
| `cnpg-custom-pg-rbr-ver` GrafanaDashboard not deploying | Instance selector matches no Grafana | **RESOLVED** — label already in grafana-rbr-ver.yaml.tpl |

---

## Root Causes

### RC-1: No Prometheus scrape targets for rbr-ver-db ✅ RESOLVED

~~`monitoring.enablePodMonitor: false` in the `verstappen` Cluster spec + no PodMonitors in
`rbr-ver-db`. Prometheus had zero targets for the namespace.~~

**As of 2026-05-11:** Part F wildcard PodMonitors are live in `cnpg-system`:

| Name | Selector | namespaceSelector |
|---|---|---|
| `cnpg-clusters` | `cnpg.io/cluster` exists | `any: true` |
| `cnpg-poolers` | `cnpg.io/poolerName` exists | `any: true` |

Prometheus confirms 3 `rbr-ver-db` targets (`cnpg_pg_postmaster_start_time` returns 3 time series).
Fix 1 (per-namespace PodMonitors) was never applied and is not needed. `cluster-verstappen.yaml.tpl`
can keep `enablePodMonitor: false`.

### RC-2: Dashboard uses wrong metric names (OPEN)

`grafanadashboard-cnpg-custom-rbr-ver.yaml` queries metrics that either don't exist or have the
wrong name. CNPG prefixes all custom-query metrics as `cnpg_<query_name>_<column>`. The dashboard
omits the prefix on several metrics and references two queries (`pg_long_running_queries`,
`pg_stat_connections`) that no configmap defines.

| Dashboard expr | Correct metric | Default configmap source |
|---|---|---|
| `pg_replication_lag_lag_seconds` | `cnpg_pg_replication_lag` | `pg_replication.lag` |
| `pg_stat_connections_total` | `cnpg_backends_total` | `backends.total` (has `state` label) |
| `pg_database_size_bytes` | `cnpg_pg_database_size_bytes` | `pg_database.size_bytes` |
| `pg_long_running_queries_count` | `cnpg_pg_long_running_queries_count` | **MISSING — needs custom query** |
| `pg_long_running_queries_max_age_seconds` | `cnpg_pg_long_running_queries_max_age_seconds` | **MISSING — needs custom query** |
| `cnpg_pgbouncer_pool_*` | `cnpg_pgbouncer_pool_*` | Built-in pooler metric — correct ✓ |

### RC-3: GrafanaDashboard CR not deploying (OPEN)

GrafanaDashboard `cnpg-custom-pg-rbr-ver` (namespace: `grafana`) shows `NO MATCHING INSTANCES`.
Its `instanceSelector` requires `matchLabels: dashboards: "grafana-rbr-ver"` but no Grafana
instance carries that label. The dashboard from this YAML is NOT being pushed to Grafana.

The live Grafana dashboard `cnpg-custom-pg` (uid: `cnpg-custom-pg`) comes from a DIFFERENT
GrafanaDashboard CR (`cnpg-custom-pg`). Both CRs have the same wrong metric names.

---

## Fix 2 — Custom queries configmap (unblocks long-running query metrics)

Create `demo/yaml/self-service/rbr-ver-db/cnpg-custom-monitoring-rbr-ver.yaml`. Provides
`pg_long_running_queries` query that the dashboard expects.

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: cnpg-custom-monitoring-rbr-ver
  namespace: rbr-ver-db
  labels:
    cnpg.io/reload: "true"
data:
  queries: |
    pg_long_running_queries:
      query: |
        SELECT
          count(*) AS count,
          COALESCE(EXTRACT(EPOCH FROM max(now() - query_start)), 0) AS max_age_seconds
        FROM pg_catalog.pg_stat_activity
        WHERE state = 'active'
          AND query_start < now() - interval '30 seconds'
          AND query NOT LIKE '%pg_stat_activity%'
      metrics:
        - count:
            usage: "GAUGE"
            description: "Queries running longer than 30 seconds"
        - max_age_seconds:
            usage: "GAUGE"
            description: "Age in seconds of the longest query over 30 seconds"
```

Produces: `cnpg_pg_long_running_queries_count`, `cnpg_pg_long_running_queries_max_age_seconds`.

Add a `monitoring:` section to `cluster-verstappen.yaml.tpl` (currently absent):

```yaml
spec:
  monitoring:
    enablePodMonitor: false          # wildcard PodMonitors in cnpg-system cover this
    disableDefaultQueries: false
    customQueriesConfigMap:
      - key: queries
        name: cnpg-default-monitoring
      - key: queries
        name: cnpg-custom-monitoring-rbr-ver
```

Apply:

```bash
kubectl apply -f demo/yaml/self-service/rbr-ver-db/cnpg-custom-monitoring-rbr-ver.yaml
kubectl patch cluster verstappen -n rbr-ver-db --type=merge -p '{
  "spec": {
    "monitoring": {
      "customQueriesConfigMap": [
        {"key": "queries", "name": "cnpg-default-monitoring"},
        {"key": "queries", "name": "cnpg-custom-monitoring-rbr-ver"}
      ]
    }
  }
}'
```

---

## Fix 3 — Correct dashboard metric names

Edit `demo/yaml/self-service/grafana/grafanadashboard-cnpg-custom-rbr-ver.yaml`.

### Variables (cluster + namespace)

```
# before
"definition": "label_values(pg_replication_lag_lag_seconds, cluster)"
"definition": "label_values(pg_replication_lag_lag_seconds{cluster=~\"$cluster\"}, namespace)"

# after
"definition": "label_values(cnpg_pg_replication_lag, cluster)"
"definition": "label_values(cnpg_pg_replication_lag{cluster=~\"$cluster\"}, namespace)"
```

### Panel 1 — Replication Lag

```
# before
"expr": "pg_replication_lag_lag_seconds{cluster=~\"$cluster\", namespace=~\"$namespace\"}"

# after
"expr": "cnpg_pg_replication_lag{cluster=~\"$cluster\", namespace=~\"$namespace\"}"
```

### Panel 2 — Connection State Breakdown

```
# before
"expr": "sum by (state) (pg_stat_connections_total{cluster=~\"$cluster\", namespace=~\"$namespace\"})"

# after
"expr": "sum by (state) (cnpg_backends_total{cluster=~\"$cluster\", namespace=~\"$namespace\"})"
```

### Panel 3 — Database Size

```
# before
"expr": "pg_database_size_bytes{cluster=~\"$cluster\", namespace=~\"$namespace\"}"
"legendFormat": "{{datname}} ({{pod}})"

# after
"expr": "cnpg_pg_database_size_bytes{cluster=~\"$cluster\", namespace=~\"$namespace\"}"
"legendFormat": "{{datname}}"
```

`cnpg_pg_database_size_bytes` carries `datname` label (not `pod`), so `{{pod}}` is dropped.

### Panel 4 — Long-running Queries

```
# before
"expr": "pg_long_running_queries_count{cluster=~\"$cluster\", namespace=~\"$namespace\"}"
"expr": "pg_long_running_queries_max_age_seconds{cluster=~\"$cluster\", namespace=~\"$namespace\"}"

# after
"expr": "cnpg_pg_long_running_queries_count{cluster=~\"$cluster\", namespace=~\"$namespace\"}"
"expr": "cnpg_pg_long_running_queries_max_age_seconds{cluster=~\"$cluster\", namespace=~\"$namespace\"}"
```

Panel 5 (pgBouncer) already correct — no change needed.

After editing, apply:

```bash
kubectl apply -f demo/yaml/self-service/grafana/grafanadashboard-cnpg-custom-rbr-ver.yaml
```

Note: this updates the `cnpg-custom-pg-rbr-ver` GrafanaDashboard CR, which currently has
`NO MATCHING INSTANCES` (see RC-3). The live dashboard `cnpg-custom-pg` is a separate CR and
needs the same metric name fixes applied to its source YAML.

---

## Fix 4 — Resolve NO MATCHING INSTANCES for cnpg-custom-pg-rbr-ver (OPEN)

The GrafanaDashboard CR `cnpg-custom-pg-rbr-ver` uses `instanceSelector.matchLabels.dashboards: "grafana-rbr-ver"`.
No Grafana instance carries this label. Options:

1. **Label the Grafana instance** — add `labels.dashboards: "grafana-rbr-ver"` to the Grafana CR
   in `demo/yaml/self-service/grafana/grafana-rbr-ver.yaml.tpl`.
2. **Change the selector** — update `grafanadashboard-cnpg-custom-rbr-ver.yaml` to use the same
   `instanceSelector` as the working dashboards (e.g., match the existing Grafana instance label).

Check the Grafana CR to see which label it currently carries, then align.

---

## Verification

```bash
# 1. Prometheus targets for rbr-ver-db (already confirmed — 3 pods UP)
# cnpg_pg_postmaster_start_time{namespace="rbr-ver-db"} returns 3 series ✓

# 2. Custom long-running queries metric (requires Fix 2)
curl -s 'http://localhost:9090/api/v1/query?query=cnpg_pg_long_running_queries_count{namespace="rbr-ver-db"}' \
  | jq '.data.result | length'
# Expect: 3 (one per instance)

# 3. Correct replication metric
curl -s 'http://localhost:9090/api/v1/query?query=cnpg_pg_replication_lag{namespace="rbr-ver-db"}' \
  | jq '.data.result'
# Expect: results for verstappen-2 and verstappen-3 (replicas only)

# 4. GrafanaDashboard instances resolved (requires Fix 4)
kubectl get grafanadashboard cnpg-custom-pg-rbr-ver -n grafana -o jsonpath='{.status}'
# Expect: no "NO MATCHING INSTANCES"
```

---

## Watchpoints

| Risk | Mitigation |
|---|---|
| `cnpg_pg_long_running_queries_count` absent after configmap patch | Label `cnpg.io/reload: "true"` must be on the configmap — included in Fix 2 YAML |
| Double-scrape risk from future per-cluster PodMonitors | Wildcard PodMonitors in `cnpg-system` already cover all namespaces; don't add per-cluster ones |
| `cnpg_backends_total` has `datname`/`usename`/`application_name` labels — panel 2 `sum by (state)` hides extra cardinality | Acceptable; no action needed |
| `cnpg_pg_database_size_bytes` emitted per database not per pod — legend `{{datname}}` sufficient | `{{pod}}` removed from legendFormat in Fix 3 |
| `cnpg-custom-pg-rbr-ver` dashboard not visible in Grafana until Fix 4 | Fix 4 must precede or accompany Fix 3 for end-to-end visibility |

---

## Commit

```
fix(monitoring): correct Custom PG Metrics dashboard and add long-running query configmap

RC-1 (no Prometheus targets) already resolved by Part F wildcard PodMonitors in cnpg-system.

RC-2: Dashboard queried wrong metric names (missing cnpg_ prefix) and two metrics had no backing
custom query (pg_long_running_queries_*, pg_stat_connections_*).

Fixes: custom-monitoring configmap with pg_long_running_queries query, monitoring section in
cluster template, dashboard corrections to use cnpg_pg_replication_lag, cnpg_backends_total,
cnpg_pg_database_size_bytes, cnpg_pg_long_running_queries_*.

RC-3 (NO MATCHING INSTANCES on GrafanaDashboard CR) tracked separately in Fix 4.
```
