# Monitoring

This directory enables monitoring of your CloudNativePG clusters using the official
[CloudNativePG Grafana Dashboard](https://github.com/cloudnative-pg/grafana-dashboards).
The included script installs the [Prometheus Operator](https://github.com/prometheus-operator/prometheus-operator)
(CRD controller only — no Prometheus pod), [Grafana Operator](https://github.com/grafana/grafana-operator),
[Alloy](https://grafana.com/docs/alloy/) (scraper + log collector), and
[Mimir](https://grafana.com/docs/mimir/) (long-term metrics store).
Alloy is the sole scraper; Mimir is the sole metrics backend.

---

## Setup

To install monitoring components for the environment you previously created (by
default consisting of two regions: `eu` and `us`), simply run:

```bash
./setup.sh
```

You may also specify one or more region names to match a customised setup:

```bash
# Monitoring setup for clusters named 'it' and 'de'
./setup.sh it de

# Monitoring setup for a single-region environment
./setup.sh local
```

The script will automatically deploy Alloy, Grafana, and the CloudNativePG dashboard in each region provided, plus Mimir and Tempo on the hub region.

---

## Accessing the Dashboard

Once installation completes, you can access Grafana via port forwarding.
The `setup.sh` script prints the exact commands needed.
For the default two-region environment, they look similar to:

```bash
kubectl port-forward service/grafana-service 3001:3000 -n grafana --context kind-k8s-eu
kubectl port-forward service/grafana-service 3002:3000 -n grafana --context kind-k8s-us
```

After forwarding the port, open your browser at:

```
http://localhost:3001
```

Log in using:

- **Username:** `admin`
- **Password:** `admin`

Grafana will prompt you to choose a new password at first login.


You can find the dashboard under `Home > Dashboards > grafana > CloudNativePG`.

![dashboard](image.png)

> **Note:** Grafana Live is disabled (`max_connections: 0`) to prevent
> WebSocket connection buildup that can exhaust kubectl port-forward
> streams and cause timeout errors. This means real-time dashboard
> streaming is unavailable, but all other Grafana features work normally
> when accessed via port-forward.

## Resource Ownership

| Resource | Owner |
|---|---|
| Prometheus Operator CRDs and controller | Helm — `kube-prometheus-stack` chart (release `kube-prometheus-stack`, namespace `prometheus-operator`) |
| kube-state-metrics | Helm — `kube-prometheus-stack` chart |
| node-exporter DaemonSet | Helm — `kube-prometheus-stack` chart (tolerations: `operator: Exists` to cover all nodes) |
| Grafana Operator controller | Helm — `grafana-operator` chart (release `grafana-operator`, namespace `grafana`) |
| Grafana instance, datasource, dashboards | Plain manifests — `monitoring/grafana/` |
| Loki single-binary | Helm — `loki` chart (namespace `grafana`, S3 backend via RustFS, 20Gi PVC, 3d retention) |
| Alloy (scraper + log collector) | Helm — `alloy` chart (namespace `grafana`, scrapes ServiceMonitors/PodMonitors + CNPG pods + all-pods + Traefik + k8s events, remote_write → Mimir) |
| Traefik `IngressRoute` for Grafana | Plain template — `monitoring/grafana/ingressroute.yaml.tpl` |
| Mimir (long-term metrics, sole backend) | Helm — `mimir-distributed` chart (namespace `mimir`, hub region only, RustFS S3) |
| Mimir Ruler IngressRoute (multi-region) | Plain template — `monitoring/mimir/ingressroute-ruler.yaml.tpl` |
| Tempo (distributed tracing) | Helm — `tempo-distributed` chart (namespace `tempo`, hub region only, RustFS S3) |

Chart versions are pinned in `scripts/common.sh` as `KUBE_PROMETHEUS_STACK_CHART_VERSION`
and `GRAFANA_OPERATOR_CHART_VERSION`. Values overrides are in
`monitoring/kube-prometheus-stack-values.yaml`.

## Metrics Scrape Architecture

Alloy is the sole scraper. There is **no Prometheus pod**. The kube-prometheus-stack chart
installs only: prometheus-operator (reconciles CRDs — required by Alloy's discovery),
kube-state-metrics, node-exporter, and pre-built ServiceMonitors (kubelet, kube-controller-manager,
kube-scheduler, kube-proxy, etcd, coreDNS, kube-apiserver).

```
ServiceMonitors ──┐
PodMonitors    ───┼──> Alloy (per region) ──remote_write──> Mimir hub (X-Scope-OrgID: <region>)
Probes         ──┘                                           │
                                                             ├──> Mimir Ruler (PrometheusRule sync)
                                                             └──> Grafana datasources:
                                                                   • uid: prometheus  (alias, default)
                                                                   • uid: mimir        (explicit)
                                                                   • uid: mimir-tempo  (tenant: tempo)
```

`PrometheusRule` CRs are synced to Mimir Ruler via Alloy's `mimir.rules.kubernetes` component.
No rules exist today — create a `PrometheusRule` CR and it syncs within seconds.

### Debugging Metrics

- **Alloy status / config**: `kubectl -n grafana port-forward svc/alloy 12345:12345` → `http://localhost:12345/`
- **Mimir ad-hoc query**: `kubectl -n mimir port-forward svc/mimir-nginx 8080:80`
  then `curl -H "X-Scope-OrgID: local" 'http://localhost:8080/prometheus/api/v1/query?query=up'`
- **Grafana**: use `DS_PROMETHEUS` (uid `prometheus`, default) or `DS_MIMIR` (uid `mimir`).
  Both alias the same Mimir backend with per-region tenant scoping.
  Use `DS_MIMIR_TEMPO` for span-metrics (tenant `tempo`).

## Dashboards

| Dashboard | Source | Notes |
|---|---|---|
| CloudNativePG cluster | `grafana_dashboard.yaml` — URL import | CNPG official dashboard |
| pgaudit Audit Logs | `grafana_dashboard_pgaudit.yaml` — inline JSON | Loki datasource |
| Node Exporter Full | `grafana_dashboard_node_exporter.yaml` — grafana.com id `1860` | Per-node CPU/mem/disk/network |
| kube-state-metrics v2 | `grafana_dashboard_kube_state.yaml` — grafana.com id `13332` | Workload counts and resource usage |
| k8s Views / Global | `grafana_dashboard_k8s_global.yaml` — grafana.com id `15760` | Cluster-wide overview |
| k8s Views / Pods | `grafana_dashboard_k8s_pods.yaml` — grafana.com id `15759` | Per-pod detail |
| Kubernetes Events | `grafana_dashboard_k8s_events.yaml` — inline JSON | Loki-backed table; namespace/type/reason filters |
| Kubernetes Pod Logs | `grafana_dashboard_k8s_pod_logs.yaml` — inline JSON | Loki-backed explorer; namespace/pod/container filters |

`grafanaCom.id` dashboards require outbound internet from the `grafana` namespace at apply time.

`kubeControllerManager`, `kubeScheduler`, `kubeProxy`, and `kubeEtcd` ServiceMonitors require
cluster recreation with `kubeadmConfigPatches` binding metrics to `0.0.0.0` (see `k8s/kind-cluster.yaml`).
Run `./demo/teardown.sh && ./scripts/setup.sh && ./monitoring/setup.sh` to apply the patches.

**Security note — etcd metrics port 2381:** `etcd` exposes an HTTP-only, unauthenticated metrics
endpoint on port 2381 (separate from the TLS client port 2379). It exposes runtime metrics only
(no key/value data). Acceptable for a local playground; do not expose outside the kind docker
network in non-playground environments.

## Traefik Access Logs

Traefik emits JSON access logs on stdout; Alloy routes them through a dedicated
`traefik_access` pipeline with `method`, `status`, and `route` promoted as Loki labels.
Traefik pods are excluded from the generic `system_logs` pipeline to avoid double-shipping.

**PII watchpoint:** Traefik JSON access logs include the full `RequestPath` with query string.
Any token or credential leaked into a URL parameter is retained in Loki for the chunk-store
retention window. Rotate any such token immediately; Traefik does not strip URL parameters.

Example queries:
```
{app="traefik", status=~"5.."}
{app="traefik", method="GET"} | json | duration > 500
```

## Tempo Tracing

Traefik exports OTLP traces to Tempo. Hub region uses gRPC in-cluster
(`tempo-distributor.tempo.svc.cluster.local:4317`); non-hub regions use HTTP/4318
via a sslip.io IngressRoute on the hub.

**Sampling:** `tracing.sampleRate: 1.0` (100%) — acceptable for playground, tune down for
production by setting `--set 'tracing.sampleRate=0.1'` at Traefik install.

**RouterName cardinality:** Traefik's `RouterName` field is promoted as a Loki label.
If the number of distinct routes exceeds ~50 consider demoting `route` to a parsed field only.

**Tempo metricsGenerator** emits `traces_service_graph_*` and `traces_spanmetrics_*` histograms
with `traceID` exemplars to Mimir (tenant `tempo`). Mimir histogram exemplars → click → Tempo trace.

**Pre-built Traefik/Tempo dashboard** (RED panels, service-graph node panel, traceID-pivot widgets)
is a follow-up task — flag in backlog.

## PodMonitor

To enable Alloy to scrape metrics from your PostgreSQL pods, create a `PodMonitor`
resource as described in the
[documentation](https://cloudnative-pg.io/documentation/current/monitoring/#creating-a-podmonitor).
Alloy discovers `PodMonitor` CRs cluster-wide via `prometheus.operator.podmonitors` and
forwards scraped metrics to Mimir automatically — no further configuration needed.

