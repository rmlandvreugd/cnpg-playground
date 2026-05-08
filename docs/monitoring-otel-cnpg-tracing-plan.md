# Plan — OTel Collector Tail Sampling, CNPG Metrics, Traefik Trace Dashboard

## Context

Extends `docs/monitoring-kind-mimir-plan.md`. Implements three items that were marked out-of-scope there, plus fixes a pre-existing Mimir tenant routing bug introduced by Part D.

**Prerequisite state:** Mimir, Tempo, Loki, Alloy, Grafana Operator, kube-prometheus-stack, and the Traefik access-log + tracing pipeline are all deployed per the prior plan.

---

## Known Bug — Mimir Tenant Mismatch (fix before Parts E–G)

**Problem:** Tempo's `metricsGenerator` writes span/service-graph metrics to Mimir with
`X-Scope-OrgID: tempo` (as configured in `monitoring/tempo/tempo-values.yaml`). The existing
`grafana_datasource_mimir.yaml` uses `X-Scope-OrgID: local`. Consequently, `traces_spanmetrics_*`
and `traces_service_graph_*` are written to the `tempo` tenant but the Grafana Mimir datasource
reads from the `local` tenant. These metrics are invisible in Grafana today.

Additionally, the Tempo datasource references `serviceMap.datasourceUid: mimir` and
`tracesToMetrics.datasourceUid: mimir` — both targeting the wrong tenant.

**Fix (Commit 0 — prerequisite):**

### Bug Fix 0.1 — New datasource `mimir-tempo`

New file `monitoring/grafana/grafana_datasource_mimir_tempo.yaml`:

```yaml
apiVersion: grafana.integreatly.org/v1beta1
kind: GrafanaDatasource
metadata:
  name: mimir-tempo
  namespace: grafana
spec:
  instanceSelector:
    matchLabels:
      dashboards: grafana
  allowCrossNamespaceImport: true
  datasource:
    name: DS_MIMIR_TEMPO
    uid: mimir-tempo
    type: prometheus
    access: proxy
    url: http://mimir-nginx.mimir.svc.cluster.local/prometheus
    jsonData:
      httpHeaderName1: X-Scope-OrgID
      timeInterval: 15s
    secureJsonData:
      httpHeaderValue1: tempo
```

### Bug Fix 0.2 — Patch `grafana_datasource_tempo.yaml`

Change `serviceMap.datasourceUid` and `tracesToMetrics.datasourceUid` from `mimir` → `mimir-tempo`:

```yaml
spec:
  datasource:
    jsonData:
      tracesToLogsV2:
        # ... unchanged ...
      tracesToMetrics:
        datasourceUid: mimir-tempo   # was: mimir
        tags:
          - key: cluster
      serviceMap:
        datasourceUid: mimir-tempo   # was: mimir
      nodeGraph:
        enabled: true
      lokiSearch:
        datasourceUid: loki
```

### Bug Fix 0.3 — Patch `grafana/kustomization.yaml`

Add `grafana_datasource_mimir_tempo.yaml` to resources list.

---

## Part E — OTel Collector with Tail-based Sampling

### E.1 Why tail sampling

Head-based sampling (current: 100% in Traefik) makes decisions before the trace is complete.
Tail-based sampling buffers spans until the full trace arrives, then applies policy:
- Keep all error traces regardless of rate
- Keep all slow traces (>500 ms threshold)
- Drop 90% of healthy fast traces

This keeps noise low in high-traffic scenarios while preserving every interesting trace.

### E.2 Single-instance constraint

The `tailsampling` processor requires ALL spans for a given trace to arrive at the SAME
collector instance. For this playground:

- Traefik is the only instrumented service
- Single otel-collector replica guarantees all spans land on one instance
- Future app instrumentation (PostgreSQL clients etc.) must send to the same collector
- For multi-replica collectors a `loadbalancing` exporter tier is required — out of scope

### E.3 Architecture

```
Hub region:
  Traefik → otel-collector.otel.svc.cluster.local:4317 (gRPC)
            → tail_sampling (decision_wait=10s)
            → tempo-distributor.tempo.svc.cluster.local:4317 (gRPC)

Non-hub regions:
  Traefik → HTTP 4318 → IngressRoute otel-push.<hub-ip-dashed>.sslip.io
            → otel-collector.otel.svc.cluster.local:4318 (HTTP)
            → tail_sampling
            → tempo-distributor.tempo.svc.cluster.local:4317 (gRPC)
```

The existing `tempo-otlp` IngressRoute (Tempo distributor 4318 direct) is retired once
otel-collector is running. Non-hub Traefik is re-upgraded with the new HTTP endpoint.

### E.4 New file — `monitoring/otel-collector/otel-collector-values.yaml`

```yaml
# OTel Collector contrib — tail-based sampling gateway for Tempo.
# Single replica: all spans for a trace must land on same instance.

mode: deployment
replicaCount: 1

image:
  repository: otel/opentelemetry-collector-contrib
  # tag pinned via OTEL_COLLECTOR_IMAGE_TAG in scripts/common.sh

# Chart >=0.110 requires explicit command name when image.repository diverges
# from the default. contrib binary is `otelcol-contrib`.
command:
  name: otelcol-contrib

config:
  receivers:
    otlp:
      protocols:
        grpc:
          endpoint: 0.0.0.0:4317
        http:
          endpoint: 0.0.0.0:4318

  processors:
    memory_limiter:
      check_interval: 1s
      limit_percentage: 75
      spike_limit_percentage: 25

    tail_sampling:
      decision_wait: 10s         # buffer window; tune up if Traefik spans arrive late
      num_traces: 1000           # circular buffer; sized as ~tps * decision_wait * 10x safety
      expected_new_traces_per_sec: 10
      policies:
        - name: errors-policy
          type: status_code
          status_code:
            status_codes: [ERROR]
        - name: slow-traces-policy
          type: latency
          latency:
            threshold_ms: 500
        - name: probabilistic-sample-policy
          type: probabilistic
          probabilistic:
            sampling_percentage: 10   # keep 10% of healthy fast traces

    batch:
      send_batch_size: 1000      # low-traffic playground; full batch unlikely
      timeout: 5s                # snappier flush for live dashboards

  exporters:
    otlp:
      endpoint: tempo-distributor.tempo.svc.cluster.local:4317
      tls:
        insecure: true
    debug:
      verbosity: basic   # remove or set verbosity: detailed for trace debugging

  service:
    pipelines:
      traces:
        receivers: [otlp]
        processors: [memory_limiter, tail_sampling, batch]
        exporters: [otlp]

ports:
  otlp:
    enabled: true
    containerPort: 4317
    servicePort: 4317
  otlp-http:
    enabled: true
    containerPort: 4318
    servicePort: 4318
  # disable unused default ports to reduce surface area
  metrics:
    enabled: false
  jaeger-compact:
    enabled: false
  jaeger-thrift:
    enabled: false
  jaeger-grpc:
    enabled: false
  zipkin:
    enabled: false

resources:
  limits:
    memory: 512Mi
    cpu: 500m
  requests:
    memory: 256Mi
    cpu: 100m

nodeSelector:
  node-role.kubernetes.io/infra: ""
tolerations:
  - key: node-role.kubernetes.io/infra
    operator: Exists
    effect: NoSchedule
```

> Processor order matters. `memory_limiter` must be first so OOM protection fires before
> spans buffer in `tail_sampling`. `batch` goes last to flush decided spans efficiently.

### E.5 New file — `monitoring/otel-collector/ingressroute.yaml.tpl` (multi-region only)

Replaces `monitoring/tempo/ingressroute.yaml.tpl` for non-hub Traefik OTLP push:

```yaml
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: otel-push
  namespace: otel
spec:
  entryPoints: [web]
  routes:
    - match: Host(`otel-push.${TRAEFIK_IP_DASHED}.sslip.io`)
      kind: Rule
      services:
        - name: otel-collector
          port: 4318
```

The old `tempo-otlp` IngressRoute in the `tempo` namespace should be deleted in `monitoring/setup.sh`
**only after otel-collector is verified Ready** to avoid a transient gap in non-hub trace ingestion:

```bash
kubectl --context "${CONTEXT_NAME}" -n otel rollout status deploy/otel-collector --timeout=120s \
  && kubectl --context "${CONTEXT_NAME}" delete ingressroute tempo-otlp-http -n tempo --ignore-not-found
```

### E.6 Patch — `scripts/common.sh`

Add:

```bash
OTEL_COLLECTOR_CHART_VERSION="${OTEL_COLLECTOR_CHART_VERSION:-0.153.0}"  # OCI: ghcr.io/open-telemetry/opentelemetry-helm-charts
OTEL_COLLECTOR_IMAGE_TAG="${OTEL_COLLECTOR_IMAGE_TAG:-0.153.0}"           # contrib image; defaults to chart appVersion if unset
```

> Image and chart tags are coupled by default (chart `appVersion` drives `image.tag`),
> but can be overridden independently. Validate the chart values with:
> `helm show values oci://ghcr.io/open-telemetry/opentelemetry-helm-charts/opentelemetry-collector \
>    --version ${OTEL_COLLECTOR_CHART_VERSION}`

### E.7 Patch — `monitoring/setup.sh`

> **Relocation required.** The current `monitoring/setup.sh:165–174` performs the non-hub
> Traefik OTLP HTTP reapply **inside** the Tempo install conditional. This block must be
> EXTRACTED and moved to **after** the new otel-collector install so non-hub Traefik
> targets `otel-push.*` instead of the now-deleted `tempo-otlp.*`.

**Hub region install block** (insert after Tempo install, replaces existing non-hub reapply):

```bash
if [[ "${region}" == "${HUB_REGION}" ]]; then
    echo "📡 Installing OTel Collector (tail-based sampling gateway)..."
    kubectl --context "${CONTEXT_NAME}" create namespace otel --dry-run=client -o yaml \
        | kubectl --context "${CONTEXT_NAME}" apply -f -

    helm_upgrade_install otel-collector \
        oci://ghcr.io/open-telemetry/opentelemetry-helm-charts/opentelemetry-collector \
        otel "${CONTEXT_NAME}" "${OTEL_COLLECTOR_CHART_VERSION}" \
        --values "${GIT_REPO_ROOT}/monitoring/otel-collector/otel-collector-values.yaml" \
        --set "image.tag=${OTEL_COLLECTOR_IMAGE_TAG}"

    # Wait for otel-collector readiness BEFORE flipping non-hub Traefik away from tempo-otlp
    kubectl --context "${CONTEXT_NAME}" -n otel rollout status deploy/otel-collector \
        --timeout=120s

    # Remove old direct-to-Tempo IngressRoute (gated on otel-collector readiness above)
    kubectl --context "${CONTEXT_NAME}" delete ingressroute tempo-otlp-http -n tempo \
        --ignore-not-found

    if [[ ${#REGIONS[@]} -gt 1 ]]; then
        HUB_TRAEFIK_IP="$(get_traefik_lb_ip "${HUB_CONTEXT}" 30)"
        HUB_TRAEFIK_DASHED="$(ip_to_dashed "${HUB_TRAEFIK_IP}")"
        TRAEFIK_IP_DASHED="${HUB_TRAEFIK_DASHED}" envsubst '${TRAEFIK_IP_DASHED}' \
            < "${GIT_REPO_ROOT}/monitoring/otel-collector/ingressroute.yaml.tpl" \
            | kubectl --context "${CONTEXT_NAME}" apply -f -

        echo "🔁 Reapplying Traefik on non-hub regions to push OTLP to otel-collector..."
        for non_hub_region in "${REGIONS[@]}"; do
            if [[ "${non_hub_region}" != "${HUB_REGION}" ]]; then
                NON_HUB_CTX="$(get_cluster_context "${non_hub_region}")"
                helm_upgrade_install traefik \
                    oci://ghcr.io/traefik/helm/traefik \
                    traefik "${NON_HUB_CTX}" "${TRAEFIK_CHART_VERSION}" \
                    --values "${GIT_REPO_ROOT}/traefik/values.yaml" \
                    --set "tracing.otlp.http.enabled=true" \
                    --set "tracing.otlp.http.endpoint=http://otel-push.${HUB_TRAEFIK_DASHED}.sslip.io/v1/traces" \
                    --set "tracing.serviceName=traefik-${non_hub_region}" \
                    --set "tracing.resourceAttributes.cluster=${non_hub_region}"
            fi
        done
    fi
fi
```

> **Attribute name standardization.** Use `tracing.resourceAttributes.<key>` (modern OTel
> resource attribute mapping) rather than the legacy `tracing.globalAttributes.<key>`.
> Apply consistently across `scripts/setup.sh` and `monitoring/setup.sh`. Both keys are
> currently mixed in the repo — fix as part of this patch.

### E.8 Patch — `scripts/setup.sh` (hub Traefik gRPC endpoint)

Change hub Traefik gRPC tracing endpoint from `tempo-distributor` to `otel-collector`:

```bash
# Hub region
TRACING_SET_ARGS=(
  --set "tracing.otlp.grpc.enabled=true"
  --set "tracing.otlp.grpc.endpoint=otel-collector.otel.svc.cluster.local:4317"  # was: tempo-distributor.tempo...
  --set "tracing.otlp.grpc.insecure=true"
)
```

### E.9 Install ordering

```
1. Tempo install (hub)               ← unchanged
2. OTel Collector install (hub)      ← NEW: before Traefik reconfiguration
3. OTel IngressRoute (hub, multi-region only)
4. Delete old tempo-otlp IngressRoute
5. Hub Traefik: already pointing at otel-collector (scripts/setup.sh phase 1)
6. Non-hub Traefik reapply           ← now points at otel-push.* instead of tempo-otlp.*
```

### E.10 Watchpoints

| Risk | Mitigation |
|---|---|
| Chart not available as OCI | Fall back: `helm repo add open-telemetry https://open-telemetry.github.io/opentelemetry-helm-charts` |
| Image tag `otelcontribcol` vs `otel/opentelemetry-collector-contrib` | Pin tag explicitly; validate with `docker manifest inspect` |
| `tail_sampling` + `batch` ordering: wrong order drops sampled spans | Always: `memory_limiter → tail_sampling → batch → exporters` |
| Tail sampling window exceeded (>10s spans): spans dropped | Increase `decision_wait` to 30s for bursty traffic; document |
| Single replica: collector restart drops in-flight buffered traces | Acceptable for playground; document as limitation |
| `tempo-otlp` IngressRoute deletion breaks in-flight non-hub traces | Delete after otel-collector IngressRoute is verified alive |

---

## Part F — CNPG + pgBouncer Metrics

### F.1 Current state

| Monitor | Selector | Port | Status |
|---|---|---|---|
| `pg-local-podmonitor` (in `default`) | `cnpg.io/cluster=pg-local` | `metrics` (9187) | ✅ exists — narrow scope |
| `pooler-local-podmonitor` (in `default`) | `cnpg.io/poolerName=pooler-local-rw` | `metrics` (9127) | ✅ exists — narrow scope |
| CNPG operator | — | 8080 | ❌ no PodMonitor |

Prometheus CR uses `podMonitorNamespaceSelector: {}` (all namespaces) so any PodMonitor — anywhere
— is scraped automatically. **This phase replaces the per-cluster monitors with cluster-wide
wildcard monitors in `monitoring/cnpg/`** so self-service tenants are covered without per-tenant
duplication.

### F.2 New file — `monitoring/cnpg/cnpg-operator-podmonitor.yaml`

```yaml
apiVersion: monitoring.coreos.com/v1
kind: PodMonitor
metadata:
  name: cnpg-operator
  namespace: cnpg-system
spec:
  selector:
    matchLabels:
      app.kubernetes.io/name: cloudnative-pg
  podMetricsEndpoints:
    - port: metrics
      path: /metrics
      scheme: http
```

> Watchpoint: if CNPG chart version changes the container port name from `metrics`,
> use `targetPort: 8080` instead. Verify: `kubectl get pods -n cnpg-system -o jsonpath='{.items[0].spec.containers[0].ports}'`.

### F.3 Custom PostgreSQL metrics — `demo/yaml/local/cnpg-custom-metrics-configmap.yaml`

CNPG's built-in exporter (port 9187) already exposes `cnpg_*` and `pg_*` metrics.
These custom queries add operational metrics not in the default set.

**Two CNPG-specific requirements:**
1. **`cnpg.io/reload: ""` label is mandatory** on the ConfigMap — without it CNPG does not reload custom queries when the ConfigMap changes.
2. **Per-query `primary: true` field** is the correct CNPG idiom to limit a query to the primary instance (CNPG renamed postgres-exporter's `master:` field). Use this rather than inline `pg_is_in_recovery()` SQL gating.

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: cnpg-custom-metrics
  namespace: default         # same namespace as the Cluster CR
  labels:
    cnpg.io/reload: ""       # required: CNPG only reloads labeled ConfigMaps
data:
  custom-metrics.yaml: |
    pg_replication_lag:
      # Run on every instance: returns 0 on primary, lag on replica.
      # No `primary: true` gate — replica reading is the whole point.
      query: |
        SELECT
          COALESCE(EXTRACT(EPOCH FROM (now() - pg_last_xact_replay_timestamp()))::bigint, 0) AS lag_seconds,
          pg_is_in_recovery()::int AS is_replica
      metrics:
        - lag_seconds:
            usage: GAUGE
            description: "Replication lag in seconds (0 on primary)"
        - is_replica:
            usage: GAUGE
            description: "1 if this is a standby, 0 if primary"

    pg_stat_connections:
      # Connection state is per-instance; useful on both primary and replicas.
      query: |
        SELECT state, count(*) AS total
        FROM pg_stat_activity
        WHERE datname IS NOT NULL
        GROUP BY state
      metrics:
        - state:
            usage: LABEL
            description: "Connection state"
        - total:
            usage: GAUGE
            description: "Number of connections in this state"

    pg_database_size:
      # Identical on primary and replicas — gate to primary to avoid 3x duplicate series.
      primary: true
      query: |
        SELECT datname, pg_database_size(datname) AS bytes
        FROM pg_database
        WHERE datname NOT IN ('template0','template1','postgres')
      metrics:
        - datname:
            usage: LABEL
            description: "Database name"
        - bytes:
            usage: GAUGE
            description: "Database size in bytes"

    pg_long_running_queries:
      # Queries on replicas are read-only and rare; primary is the operational concern.
      primary: true
      query: |
        SELECT count(*) AS count,
               COALESCE(max(EXTRACT(EPOCH FROM (now() - query_start)))::int, 0) AS max_age_seconds
        FROM pg_stat_activity
        WHERE state = 'active' AND query_start < now() - interval '30 seconds'
          AND query NOT LIKE '%pg_stat_activity%'
      metrics:
        - count:
            usage: GAUGE
            description: "Queries running longer than 30s"
        - max_age_seconds:
            usage: GAUGE
            description: "Age in seconds of the longest running query"
```

> **Source for `primary` field:** CNPG `pkg/management/postgres/metrics/parser.go` defines
> `Primary bool \`yaml:"primary"\``. Used in CNPG's own `config/manager/default-monitoring.yaml`
> (e.g. `pg_stat_replication`).

### F.4 Patch — `demo/yaml/local/pg-local.yaml`

`pg-local.yaml` currently has **no `monitoring:` block**. Add one:

```yaml
spec:
  monitoring:
    enablePodMonitor: false   # explicit: rely on wildcard PodMonitors in monitoring/cnpg/
    customQueriesConfigMap:
      - name: cnpg-custom-metrics
        key: custom-metrics.yaml
```

> **`enablePodMonitor` is deprecated upstream** (CNPG `cluster_types.go` carries a
> deprecation notice; removal targeted in a future release). Keeping it explicitly `false`
> is forward-compatible. The wildcard PodMonitors in `monitoring/cnpg/` (see F.6/F.7) take
> over scraping for `pg-local` and any future tenant Cluster.

### F.5 Patch — `monitoring/setup.sh`

Apply the operator PodMonitor and the cluster/pooler wildcard PodMonitors after the CNPG
controller restart step:

```bash
if kubectl --context "${CONTEXT_NAME}" get namespace cnpg-system &>/dev/null; then
    echo "📊 Applying CNPG PodMonitors (operator + cluster/pooler wildcards)..."
    kubectl --context "${CONTEXT_NAME}" apply \
        -f "${GIT_REPO_ROOT}/monitoring/cnpg/cnpg-operator-podmonitor.yaml" \
        -f "${GIT_REPO_ROOT}/monitoring/cnpg/cnpg-cluster-wildcard-podmonitor.yaml" \
        -f "${GIT_REPO_ROOT}/monitoring/cnpg/cnpg-pooler-wildcard-podmonitor.yaml"
fi
```

### F.6 Wildcard Pooler PodMonitor — `monitoring/cnpg/cnpg-pooler-wildcard-podmonitor.yaml`

Replaces the per-cluster `pooler-local-podmonitor.yaml`. Lives under `monitoring/cnpg/`
(operator-managed, applied once per region by `monitoring/setup.sh`) and matches every
pooler pod across every namespace.

```yaml
apiVersion: monitoring.coreos.com/v1
kind: PodMonitor
metadata:
  name: cnpg-poolers
  namespace: cnpg-system
spec:
  namespaceSelector:
    any: true                 # match poolers in any namespace (self-service tenants)
  selector:
    matchExpressions:
      - key: cnpg.io/poolerName
        operator: Exists      # set by CNPG on every pooler-managed pod
  podMetricsEndpoints:
    - port: metrics
      path: /metrics
```

> **Source for label:** CNPG `pkg/specs/pgbouncer/deployments.go` sets
> `cnpg.io/poolerName: <pooler.Name>` on every Pooler-managed pod template.
>
> **Delete** the existing `demo/yaml/local/pg-local-podmonitor.yaml` (which contained both
> the cluster and pooler PodMonitors) once the wildcards are live, to avoid double-scraping.

### F.7 Wildcard Cluster PodMonitor — `monitoring/cnpg/cnpg-cluster-wildcard-podmonitor.yaml`

Same pattern for the Cluster pods themselves:

```yaml
apiVersion: monitoring.coreos.com/v1
kind: PodMonitor
metadata:
  name: cnpg-clusters
  namespace: cnpg-system
spec:
  namespaceSelector:
    any: true
  selector:
    matchExpressions:
      - key: cnpg.io/cluster
        operator: Exists
  podMetricsEndpoints:
    - port: metrics
      path: /metrics
```

### F.8 Grafana dashboards for CNPG metrics

The official CloudNativePG dashboard (already imported) covers the core `cnpg_*` metrics.
The following additions fill gaps:

**New file — `monitoring/grafana/grafana_dashboard_cnpg_custom.yaml`**

Inline GrafanaDashboard with panels for:
- Replication lag per cluster (custom `pg_replication_lag_lag_seconds` metric)
- Connection states (active/idle/idle-in-transaction) — `pg_stat_connections_total`
- Database size trend — `pg_database_size_bytes`
- Long-running queries count — `pg_long_running_queries_count`
- pgBouncer pool utilization from Pooler metrics

File outline (full JSON in commit):

```json
{
  "title": "CNPG — Custom PostgreSQL Metrics",
  "uid": "cnpg-custom-pg",
  "panels": [
    "Replication Lag by Cluster (GAUGE)",
    "Connection State Breakdown (stacked time series)",
    "Database Size Over Time (bytes → human-readable)",
    "Long-running Queries (stat + alert threshold marker)",
    "pgBouncer Pool Utilization"
  ]
}
```

### F.9 Watchpoints

| Risk | Mitigation |
|---|---|
| CNPG operator port name not `metrics` | Fall back to `targetPort: 8080`; verify with `kubectl get pod -n cnpg-system -o jsonpath='{.items[0].spec.containers[0].ports}'` |
| Custom queries write on standby (functions like `pg_replication_slots`) | Use per-query `primary: true` field — NOT inline `pg_is_in_recovery()` SQL |
| Custom metrics ConfigMap not reloading | `cnpg.io/reload: ""` label must be present on the ConfigMap |
| `enablePodMonitor` field deprecated | Set explicitly to `false`; rely on wildcard PodMonitors in `monitoring/cnpg/` |
| Stale narrow PodMonitor double-scrapes after wildcards land | Delete `demo/yaml/local/pg-local-podmonitor.yaml` in same commit as wildcards |
| Custom metrics ConfigMap namespace mismatch | ConfigMap must be in same namespace as Cluster CR (one CM per cluster namespace) |

---

## Part G — Traefik Trace Dashboard (RED + Service Graph + TraceID Pivot)

### G.1 Available metrics

Tempo's `metricsGenerator` writes to Mimir tenant `tempo`. After Bug Fix 0.1, the `mimir-tempo`
datasource (UID: `mimir-tempo`) provides access:

| Metric | Description |
|---|---|
| `traces_spanmetrics_calls_total` | Total span count; labels: `service_name`, `span_name`, `span_kind`, `status_code` |
| `traces_spanmetrics_latency_bucket` | Span latency histogram |
| `traces_spanmetrics_latency_sum/count` | For average latency |
| `traces_service_graph_request_total` | Service-to-service call count; labels: `client`, `server` |
| `traces_service_graph_request_duration_seconds_bucket` | Service edge latency histogram |
| `traces_service_graph_failed_request_total` | Failed cross-service calls |

> `status_code` label values from OTel semantic conventions: `STATUS_CODE_OK`, `STATUS_CODE_ERROR`, `STATUS_CODE_UNSET`.

### G.2 Dashboard design

```
Row 0: stat row (3 panels, h=4)
  [1] Request Rate (req/s)  [2] Error Rate (%)  [3] P95 Latency (ms)

Row 1: trend row (2 panels, h=8)
  [4] Request Rate by Service (timeseries)    [5] Latency Percentiles p50/p95/p99 (timeseries)

Row 2: service graph (1 panel, h=10)
  [6] Service Map (nodeGraph via Tempo → mimir-tempo)

Row 3: trace explorer (2 panels, h=12)
  [7] Recent Traces (Tempo trace list)    [8] Top Slow Traces (Tempo filtered search)
```

### G.3 New file — `monitoring/grafana/grafana_dashboard_traefik_traces.yaml`

```yaml
apiVersion: grafana.integreatly.org/v1beta1
kind: GrafanaDashboard
metadata:
  name: traefik-traces
  namespace: grafana
spec:
  instanceSelector:
    matchLabels:
      dashboards: "grafana"
  json: |
    {
      "title": "Traefik Traces — RED + Service Graph",
      "uid": "traefik-traces-red",
      "schemaVersion": 39,
      "version": 1,
      "refresh": "30s",
      "time": {"from": "now-1h", "to": "now"},
      "templating": {
        "list": [
          {
            "name": "mimir_ds",
            "label": "Mimir (span metrics)",
            "type": "datasource",
            "pluginId": "prometheus",
            "query": "prometheus",
            "current": {"selected": true, "text": "DS_MIMIR_TEMPO", "value": "mimir-tempo"},
            "hide": 0
          },
          {
            "name": "loki_ds",
            "label": "Loki",
            "type": "datasource",
            "pluginId": "loki",
            "query": "loki",
            "current": {"selected": true, "text": "DS_LOKI", "value": "loki"},
            "hide": 0
          },
          {
            "name": "tempo_ds",
            "label": "Tempo",
            "type": "datasource",
            "pluginId": "tempo",
            "query": "tempo",
            "current": {"selected": true, "text": "DS_TEMPO", "value": "tempo"},
            "hide": 0
          },
          {
            "name": "service",
            "label": "Service",
            "type": "query",
            "datasource": {"type": "prometheus", "uid": "mimir-tempo"},
            "query": "label_values(traces_spanmetrics_calls_total, service_name)",
            "refresh": 2,
            "hide": 0,
            "multi": false,
            "includeAll": true,
            "allValue": ".*"
          }
        ]
      },
      "panels": [
        {
          "id": 1,
          "title": "Request Rate",
          "type": "stat",
          "gridPos": {"x": 0, "y": 0, "w": 8, "h": 4},
          "datasource": {"type": "prometheus", "uid": "${mimir_ds}"},
          "targets": [{
            "refId": "A",
            "expr": "sum(rate(traces_spanmetrics_calls_total{service_name=~\"$service\"}[$__rate_interval]))",
            "legendFormat": "req/s"
          }],
          "options": {"reduceOptions": {"calcs": ["lastNotNull"]}, "colorMode": "background"},
          "fieldConfig": {
            "defaults": {
              "unit": "reqps",
              "thresholds": {
                "mode": "absolute",
                "steps": [
                  {"color": "green", "value": null},
                  {"color": "yellow", "value": 100},
                  {"color": "red", "value": 1000}
                ]
              }
            }
          }
        },
        {
          "id": 2,
          "title": "Error Rate",
          "type": "stat",
          "gridPos": {"x": 8, "y": 0, "w": 8, "h": 4},
          "datasource": {"type": "prometheus", "uid": "${mimir_ds}"},
          "targets": [{
            "refId": "A",
            "expr": "100 * sum(rate(traces_spanmetrics_calls_total{status_code=\"STATUS_CODE_ERROR\",service_name=~\"$service\"}[$__rate_interval])) / sum(rate(traces_spanmetrics_calls_total{service_name=~\"$service\"}[$__rate_interval]))",
            "legendFormat": "error %",
            "instant": true
          }],
          "options": {"reduceOptions": {"calcs": ["lastNotNull"]}, "colorMode": "background"},
          "fieldConfig": {
            "defaults": {
              "unit": "percent",
              "noValue": "0",
              "thresholds": {
                "mode": "absolute",
                "steps": [
                  {"color": "green", "value": null},
                  {"color": "yellow", "value": 1},
                  {"color": "red", "value": 5}
                ]
              }
            }
          }
        },
        {
          "id": 3,
          "title": "P95 Latency",
          "type": "stat",
          "gridPos": {"x": 16, "y": 0, "w": 8, "h": 4},
          "datasource": {"type": "prometheus", "uid": "${mimir_ds}"},
          "targets": [{
            "refId": "A",
            "expr": "histogram_quantile(0.95, sum(rate(traces_spanmetrics_latency_bucket{service_name=~\"$service\"}[$__rate_interval])) by (le)) * 1000",
            "legendFormat": "p95 ms",
            "instant": true
          }],
          "options": {"reduceOptions": {"calcs": ["lastNotNull"]}, "colorMode": "background"},
          "fieldConfig": {
            "defaults": {
              "unit": "ms",
              "thresholds": {
                "mode": "absolute",
                "steps": [
                  {"color": "green", "value": null},
                  {"color": "yellow", "value": 200},
                  {"color": "red", "value": 500}
                ]
              }
            }
          }
        },
        {
          "id": 4,
          "title": "Request Rate by Service",
          "type": "timeseries",
          "gridPos": {"x": 0, "y": 4, "w": 12, "h": 8},
          "datasource": {"type": "prometheus", "uid": "${mimir_ds}"},
          "targets": [{
            "refId": "A",
            "expr": "sum by (service_name) (rate(traces_spanmetrics_calls_total{service_name=~\"$service\"}[$__rate_interval]))",
            "legendFormat": "{{service_name}}"
          }],
          "fieldConfig": {"defaults": {"unit": "reqps", "custom": {"lineWidth": 2}}}
        },
        {
          "id": 5,
          "title": "Latency Percentiles",
          "type": "timeseries",
          "gridPos": {"x": 12, "y": 4, "w": 12, "h": 8},
          "datasource": {"type": "prometheus", "uid": "${mimir_ds}"},
          "targets": [
            {
              "refId": "A",
              "expr": "histogram_quantile(0.50, sum by (le) (rate(traces_spanmetrics_latency_bucket{service_name=~\"$service\"}[$__rate_interval]))) * 1000",
              "legendFormat": "p50"
            },
            {
              "refId": "B",
              "expr": "histogram_quantile(0.95, sum by (le) (rate(traces_spanmetrics_latency_bucket{service_name=~\"$service\"}[$__rate_interval]))) * 1000",
              "legendFormat": "p95"
            },
            {
              "refId": "C",
              "expr": "histogram_quantile(0.99, sum by (le) (rate(traces_spanmetrics_latency_bucket{service_name=~\"$service\"}[$__rate_interval]))) * 1000",
              "legendFormat": "p99"
            }
          ],
          "fieldConfig": {"defaults": {"unit": "ms", "custom": {"lineWidth": 2}}}
        },
        {
          "id": 6,
          "title": "Service Map",
          "type": "nodeGraph",
          "gridPos": {"x": 0, "y": 12, "w": 24, "h": 10},
          "datasource": {"type": "tempo", "uid": "${tempo_ds}"},
          "targets": [{
            "refId": "A",
            "queryType": "serviceMap",
            "serviceMapQuery": ""
          }],
          "options": {}
        },
        {
          "id": 7,
          "title": "Recent Traces",
          "type": "table",
          "gridPos": {"x": 0, "y": 22, "w": 16, "h": 12},
          "datasource": {"type": "tempo", "uid": "${tempo_ds}"},
          "targets": [{
            "refId": "A",
            "queryType": "traceql",
            "query": "{resource.service.name=~\"$service\"}",
            "limit": 20,
            "tableType": "traces"
          }],
          "options": {"frameType": "trace"}
        },
        {
          "id": 8,
          "title": "Slowest Traces (>500ms)",
          "type": "table",
          "gridPos": {"x": 16, "y": 22, "w": 8, "h": 12},
          "datasource": {"type": "tempo", "uid": "${tempo_ds}"},
          "targets": [{
            "refId": "A",
            "queryType": "traceql",
            "query": "{resource.service.name=~\"$service\" && duration > 500ms}",
            "limit": 10,
            "tableType": "traces"
          }],
          "options": {"frameType": "trace"}
        }
      ]
    }
```

### G.4 Patch — `monitoring/grafana/kustomization.yaml`

```yaml
resources:
  # ... existing resources ...
  - grafana_datasource_mimir_tempo.yaml    # Bug Fix 0.1
  - grafana_dashboard_traefik_traces.yaml  # Part G
  - grafana_dashboard_cnpg_custom.yaml     # Part F
```

### G.5 Self-service tenant duplication

Per-tenant Grafana CRs in `demo/yaml/self-service/grafana/` mirror central Grafana resources via
`instanceSelector.matchLabels.dashboards: "grafana-rbr-ver"` (cf. `grafanadashboard-pgaudit-rbr-ver.yaml`).
The new central dashboards/datasources do NOT reach the per-tenant Grafana automatically.

**New files** (siblings of existing `grafanadashboard-pgaudit-rbr-ver.yaml`):

- `demo/yaml/self-service/grafana/grafanadatasource-tempo-rbr-ver.yaml`
  Mirrors `monitoring/grafana/grafana_datasource_tempo.yaml`. UID: `tempo` (per-Grafana scope, can re-use). Selector `dashboards: "grafana-rbr-ver"`.

- `demo/yaml/self-service/grafana/grafanadatasource-mimir-tempo-rbr-ver.yaml`
  Mirrors Bug Fix 0.1 datasource. UID: `mimir-tempo`. Selector `dashboards: "grafana-rbr-ver"`.

- `demo/yaml/self-service/grafana/grafanadashboard-traefik-traces-rbr-ver.yaml`
  Mirrors `grafana_dashboard_traefik_traces.yaml` JSON; only `metadata.name` and `spec.instanceSelector.matchLabels.dashboards` differ.

- `demo/yaml/self-service/grafana/grafanadashboard-cnpg-custom-rbr-ver.yaml`
  Mirrors `grafana_dashboard_cnpg_custom.yaml` JSON; same selector swap.

**Apply pathway:** verify in `demo/self-service-setup.sh` and/or kustomize overlay where the existing tenant Grafana CRs are applied. Add the new four to the same kubectl/kustomize invocation.

### G.6 Watchpoints

| Risk | Mitigation |
|---|---|
| `traces_spanmetrics_*` metrics absent (Tempo metricsGenerator not running) | Verify: `kubectl -n tempo get pods` and `kubectl -n tempo logs deploy/tempo-metrics-generator` |
| Service map panel empty (Tempo cannot reach mimir-tempo) | Verify `serviceMap.datasourceUid: mimir-tempo` in Tempo datasource; check Mimir federation |
| `$__rate_interval` too small for 15s scrape interval | Grafana auto-computes ≥4× scrape interval; min 60s — OK with Mimir's 15s interval |
| Datasource variable not defaulting to correct UID | Set explicit `current.value` in each datasource variable |
| TraceQL `{resource.service.name=~"$service"}` syntax varies by Tempo version | Verify with Tempo version pinned in `TEMPO_CHART_VERSION`; fallback: `{.service.name=~"$service"}` |

---

## Verification

### Bug Fix 0
```bash
# Confirm tempo-tenant metrics visible in Grafana
kubectl -n grafana port-forward svc/grafana-service 3000
# Grafana → Explore → DS_MIMIR_TEMPO → query: traces_spanmetrics_calls_total → expect results
```

### Part E
```bash
kubectl --context kind-k8s-local -n otel get pods    # otel-collector Running

# Verify traces reach Tempo via otel-collector (not directly)
# Force 50 requests through Traefik
for i in $(seq 1 50); do curl -s "http://traefik.${TRAEFIK_IP_DASHED}.sslip.io/dashboard/" >/dev/null; done

# Tempo Search: expect spans with traefik-local service
# otel-collector logs: expect "sampling decision" debug lines
kubectl -n otel logs -l app.kubernetes.io/name=opentelemetry-collector | grep -E 'sampl|decision'

# Verify error traces always kept:
curl -s "http://traefik.${TRAEFIK_IP_DASHED}.sslip.io/nonexistent" >/dev/null
# Tempo should show this 404 trace regardless of sampling percentage
```

### Part F
```bash
# CNPG operator metrics target UP
kubectl --context kind-k8s-local -n prometheus-operator port-forward svc/prometheus-operated 9090
# Prometheus UI → Targets → filter cnpg-system → expect UP

# Custom metrics visible
curl -s http://localhost:9090/api/v1/query?query=pg_replication_lag_lag_seconds | jq '.data.result'
curl -s http://localhost:9090/api/v1/query?query=pg_stat_connections_total | jq '.data.result'
```

### Part G
```bash
# Dashboard loads without errors
# Grafana → Dashboard → "Traefik Traces — RED + Service Graph"
# Stat panels show values (not "N/A")
# Service map renders edges between services
# Click a trace row → Tempo trace view → "Logs for this span" → Loki jump
# Click TraceID in Loki → Tempo span view
```

---

## File-level Changeset Summary

### Create
- `monitoring/grafana/grafana_datasource_mimir_tempo.yaml`   (Bug Fix 0.1)
- `monitoring/otel-collector/otel-collector-values.yaml`     (Part E)
- `monitoring/otel-collector/ingressroute.yaml.tpl`          (Part E, multi-region)
- `monitoring/cnpg/cnpg-operator-podmonitor.yaml`            (Part F.2)
- `monitoring/cnpg/cnpg-cluster-wildcard-podmonitor.yaml`    (Part F.7)
- `monitoring/cnpg/cnpg-pooler-wildcard-podmonitor.yaml`     (Part F.6)
- `demo/yaml/local/cnpg-custom-metrics-configmap.yaml`       (Part F.3)
- `monitoring/grafana/grafana_dashboard_traefik_traces.yaml` (Part G.3)
- `monitoring/grafana/grafana_dashboard_cnpg_custom.yaml`    (Part F.8 / G)
- `demo/yaml/self-service/grafana/grafanadatasource-tempo-rbr-ver.yaml`         (Part G.5)
- `demo/yaml/self-service/grafana/grafanadatasource-mimir-tempo-rbr-ver.yaml`   (Part G.5)
- `demo/yaml/self-service/grafana/grafanadashboard-traefik-traces-rbr-ver.yaml` (Part G.5)
- `demo/yaml/self-service/grafana/grafanadashboard-cnpg-custom-rbr-ver.yaml`    (Part G.5)

### Modify
- `monitoring/grafana/grafana_datasource_tempo.yaml`         (Bug Fix 0.2: datasourceUid mimir → mimir-tempo)
- `monitoring/grafana/kustomization.yaml`                    (Bug Fix 0.3, Part G: add new resources)
- `scripts/common.sh`                                        (Part E: OTEL_COLLECTOR_CHART_VERSION=0.153.0, IMAGE_TAG=0.153.0)
- `scripts/setup.sh`                                         (Part E: hub Traefik gRPC → otel-collector; standardize tracing.resourceAttributes.cluster)
- `monitoring/setup.sh`                                      (Part E: otel-collector install, relocate non-hub Traefik reapply OUT of Tempo block, gated tempo-otlp-http delete; Part F: apply 3 PodMonitors; standardize tracing.resourceAttributes.cluster)
- `demo/yaml/local/pg-local.yaml`                            (Part F.4: add monitoring block, enablePodMonitor:false, customQueriesConfigMap)
- `demo/self-service-setup.sh`                               (Part G.5: apply 4 new tenant Grafana CRs)

### Delete (after otel-collector live and wildcards verified)
- `monitoring/tempo/ingressroute.yaml.tpl`                   → replaced by `monitoring/otel-collector/ingressroute.yaml.tpl`
- `demo/yaml/local/pg-local-podmonitor.yaml`                 → replaced by `monitoring/cnpg/cnpg-{cluster,pooler}-wildcard-podmonitor.yaml`

---

## Suggested Commit Sequence

Wait for approval to continue after every commit.

If working in a git worktree, merge the commit to worktree root, before waiting to proceed

1. **Commit 0** — `fix(monitoring): add mimir-tempo datasource and correct Tempo serviceMap tenant`
   Touches: `grafana_datasource_mimir_tempo.yaml` (new), `grafana_datasource_tempo.yaml`, `kustomization.yaml`.
   Validation: Grafana Explore → DS_MIMIR_TEMPO → `traces_spanmetrics_calls_total` returns data.

2. **Commit 1** — `feat(monitoring): add otel-collector tail-based sampling gateway`
   Touches: `monitoring/otel-collector/*` (new), `scripts/common.sh`, `scripts/setup.sh`, `monitoring/setup.sh`.
   Validation: otel-collector Running; Tempo still receives spans; error traces kept, healthy traces ~10%.

3. **Commit 2** — `feat(monitoring): cnpg wildcard podmonitors, operator metrics, custom pg queries`
   Touches:
   - `monitoring/cnpg/cnpg-operator-podmonitor.yaml` (new)
   - `monitoring/cnpg/cnpg-cluster-wildcard-podmonitor.yaml` (new)
   - `monitoring/cnpg/cnpg-pooler-wildcard-podmonitor.yaml` (new)
   - `demo/yaml/local/cnpg-custom-metrics-configmap.yaml` (new, with `cnpg.io/reload: ""` label)
   - `demo/yaml/local/pg-local.yaml` (add monitoring block)
   - `monitoring/setup.sh` (apply 3 PodMonitors)
   - `demo/yaml/local/pg-local-podmonitor.yaml` (DELETE)
   Validation: Prometheus targets show cnpg-system UP; `pg_replication_lag_lag_seconds`, `pg_database_size_bytes` visible; no duplicate scrape series.

4. **Commit 3** — `feat(monitoring): traefik trace dashboard with RED panels and service graph`
   Touches:
   - `monitoring/grafana/grafana_dashboard_traefik_traces.yaml` (new)
   - `monitoring/grafana/grafana_dashboard_cnpg_custom.yaml` (new)
   - `monitoring/grafana/kustomization.yaml`
   - `demo/yaml/self-service/grafana/grafanadatasource-tempo-rbr-ver.yaml` (new)
   - `demo/yaml/self-service/grafana/grafanadatasource-mimir-tempo-rbr-ver.yaml` (new)
   - `demo/yaml/self-service/grafana/grafanadashboard-traefik-traces-rbr-ver.yaml` (new)
   - `demo/yaml/self-service/grafana/grafanadashboard-cnpg-custom-rbr-ver.yaml` (new)
   - `demo/self-service-setup.sh` (apply tenant CRs)
   Validation: central Grafana dashboard loads; all panels render; service map visible; trace → Loki pivot works. Per-tenant Grafana (`grafana-rbr-ver`) shows the same dashboards under tenant scope.

---

## Appendix — Prompt Suggestions for Follow-up Agent Investigations

Spawn a research agent for each open uncertainty during implementation. Each prompt is self-contained — copy-paste into a `general-purpose` subagent.

### P1. CNPG operator PodMonitor — Service vs Pod scrape and named port

> "Working in /home/admin/projects/cnpg-playground/.claude/worktrees/cnpg-dev. CNPG chart 0.28.0 (`cloudnative-pg/charts@v0.28.0`) installs the operator in namespace `cnpg-system`. Confirm:
>
> 1. Is the operator container port `8080` exposed on a Kubernetes Service, or only on the Pod?
> 2. Is the port name on the Pod template `metrics`, or different in 0.28.0?
> 3. Does `monitoring.podMonitorEnabled: true` in the chart values create an equivalent PodMonitor — and if so, what selectors/ports does it use?
>
> Read `cloudnative-pg/charts@v0.28.0` `templates/deployment.yaml`, `templates/service.yaml` (if present), and `templates/podmonitor.yaml`. Cite the exact YAML lines. If a Service exists, recommend whether to use a ServiceMonitor instead of the PodMonitor in our plan F.2. Reply ≤300 words."

### P2. Traefik OTLP attribute key — `globalAttributes` vs `resourceAttributes` in v3.3.0

> "Traefik chart `oci://ghcr.io/traefik/helm/traefik` version `39.0.8` ships Traefik v3.3.0. The plan and existing scripts mix `tracing.globalAttributes.<key>` (in `monitoring/setup.sh:172`) and `tracing.resourceAttributes.<key>` (in `scripts/setup.sh:240`).
>
> Confirm:
> 1. Are both Helm values supported in chart 39.0.8?
> 2. Do they map to the same Traefik static config field (e.g. both → `tracing.otlp.resourceAttributes`)? Or one is a chart shim around the other?
> 3. In Traefik v3.3.0, what is the upstream-blessed name (resource attribute, not global)?
>
> Sources: traefik/traefik-helm-chart at v39.0.8 `values.yaml`, `tracing.tpl`, and Traefik docs at https://doc.traefik.io/traefik/v3.3/observability/tracing/overview/. Cite repo paths and line numbers. Reply ≤250 words."

### P3. OTel Collector k8s vs contrib distro — `tail_sampling` availability

> "OpenTelemetry Collector Helm chart `opentelemetry-collector` v0.153.0 supports any image. We use `otel/opentelemetry-collector-contrib`. Question: does the alternative `ghcr.io/open-telemetry/opentelemetry-collector-releases/opentelemetry-collector-k8s` distro include the `tail_sampling` processor?
>
> Read `open-telemetry/opentelemetry-collector-releases` `distributions/k8s/manifest.yaml` and equivalent `distributions/contrib/manifest.yaml` at the v0.153.0 release tag. Compare the processor lists. Reply with: yes/no for tail_sampling in k8s flavor, image size delta if discoverable, recommendation. ≤200 words."

### P4. Verify `primary: true` per-query gate in CNPG 1.27/1.28

> "Working in CNPG chart 0.28.0 (`scripts/common.sh` pins `CNPG_CHART_VERSION=0.28.0`). The plan F.3 uses per-query `primary: true` field on PostgreSQL custom query metrics.
>
> Confirm:
> 1. Field name is `primary` (boolean, default false). Source: `cloudnative-pg/cloudnative-pg` `pkg/management/postgres/metrics/parser.go`.
> 2. Runtime gating logic: which file/function decides whether to skip on replicas? (`pkg/management/postgres/metrics/collector.go` is suspected.)
> 3. Live example in CNPG default queries: `config/manager/default-monitoring.yaml` should have `pg_stat_replication: primary: true` or similar.
>
> Cite exact file:line references. Reply ≤200 words."

### P5. Tempo `metricsGenerator` `local-blocks` storage requirements

> "We use grafana-community `tempo-distributed` chart 2.19.0 (appVersion 2.10.5), pinned in `scripts/common.sh:TEMPO_CHART_VERSION`. Current `monitoring/tempo/tempo-values.yaml` enables `local_blocks` processor with `max_block_bytes: 314572800`. Single-replica deployment with `metricsGenerator.replicas: 1`.
>
> Confirm:
> 1. Does `local_blocks` processor write blocks to a local disk, and is a PVC required for the metrics-generator pod?
> 2. The chart template `templates/metrics-generator/statefulset-metrics-generator.yaml` — does it default to a PVC, emptyDir, or no volume at all? Read the actual template.
> 3. If only emptyDir, what's the failure mode when the pod restarts (data loss for in-flight TraceQL local-blocks queries)?
>
> Sources: https://github.com/grafana-community/helm-charts/tree/main/charts/tempo-distributed and https://grafana.com/docs/tempo/latest/configuration/. Reply ≤300 words."

### P6. Self-service Grafana CR provisioning pathway

> "Working in /home/admin/projects/cnpg-playground/.claude/worktrees/cnpg-dev. The repo has central Grafana CRs in `monitoring/grafana/` (applied by `monitoring/setup.sh` via kustomize) and per-tenant CRs in `demo/yaml/self-service/grafana/` (e.g. `grafanadashboard-pgaudit-rbr-ver.yaml`).
>
> Trace exactly where the per-tenant CRs are applied. Read:
> 1. `demo/self-service-setup.sh`
> 2. `demo/setup.sh`
> 3. Any kustomization.yaml inside `demo/yaml/self-service/` subtree
> 4. `monitoring/setup.sh` (in case central pipeline also picks them up)
>
> Output: for each new file we want to add (`grafanadatasource-tempo-rbr-ver.yaml`, `grafanadatasource-mimir-tempo-rbr-ver.yaml`, `grafanadashboard-traefik-traces-rbr-ver.yaml`, `grafanadashboard-cnpg-custom-rbr-ver.yaml`), state the exact apply pathway and the line(s) in scripts to modify. Reply ≤400 words."

### P7. Live verify Traefik OTLP `service.name` attribute scope

> "After plan E.7 lands, Traefik v3.3 will be configured with `tracing.serviceName=traefik-${region}`. The Tempo dashboard panels use TraceQL `{resource.service.name=~\"$service\"}`. Question: does Traefik write `service.name` as an OTLP **resource** attribute, a span attribute, or both?
>
> Method: in a running playground (assume otel-collector deployed with `verbosity: detailed` debug exporter):
> 1. Force a request: `curl http://traefik.<dashed-ip>.sslip.io/dashboard/`
> 2. Read otel-collector logs: `kubectl -n otel logs deploy/otel-collector | grep -A30 'service.name'`
> 3. Identify in the dumped span whether `service.name` lives under `Resource attributes:` or `Attributes:` (span scope)
>
> Report: which scope, the exact resource/span attributes Traefik emits, and whether the TraceQL `resource.service.name` filter will match. If it doesn't match, propose the fallback TraceQL or the corrected service-name config. Reply ≤300 words."

### P8. Cross-reference Mimir tenant for Prometheus remote_write

> "Repo path: /home/admin/projects/cnpg-playground/.claude/worktrees/cnpg-dev. Investigate Mimir multi-tenancy assumptions:
>
> 1. Read `monitoring/prometheus-instance/prometheus-cr.yaml.tpl`. Does the Prometheus CR's `remoteWrite` block set an `X-Scope-OrgID` header? If so, what value?
> 2. Read `monitoring/mimir/mimir-values.yaml`. What are `auth.multitenancy_enabled` and `no_auth_tenant`?
> 3. Match-up: does `grafana_datasource_mimir.yaml` (header `X-Scope-OrgID: local`) read from the same tenant Prometheus writes to? Or are we reading an empty tenant today?
>
> Output a table: `Source → Tenant → Read by`. Identify any mismatch. If mismatch exists, recommend either updating Prometheus to write tenant `local`, or updating the datasource. Reply ≤300 words."

### P9. Bulk-replay test for tail-sampling correctness

> "After plan Part E lands and otel-collector is live, write a short test plan to verify tail-sampling behaves correctly in the playground. Constraints:
>
> 1. Generate exactly 100 traces: 5 errors (404 on `/nonexistent`), 5 slow (>500ms — use a sleep in the request path? Traefik dashboard returns fast — propose a target endpoint), 90 normal.
> 2. Expected outcome: all 5 errors kept (errors-policy), all 5 slow kept (slow-traces-policy), 9 of 90 normal kept (probabilistic 10%). Total ≈ 19 traces visible in Tempo Search.
> 3. Acceptance criteria with exact `tempo-cli search` or HTTP API queries to count traces by status_code.
>
> Output: shell script to drive load, kubectl/tempo-cli queries to count, and an explicit pass/fail rule. ≤400 words."

