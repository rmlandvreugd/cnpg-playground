# Monitoring Extension — Kubernetes Core Metrics, Logs & Events

**Status:** Plan locked, awaiting execution
**Date:** 2026-05-07
**Branch:** `vault` (worktree: `cnpg-dev`)
**Scope:** Extend the existing Prometheus + Grafana + Loki + Alloy stack so that the playground surfaces full Kubernetes core observability (node metrics, control-plane metrics, system pod logs, cluster events) alongside the current CNPG-only view.

---

## 1. Current State (IST)

### 1.1 Metrics

| Component | Status | Notes |
|---|---|---|
| `kube-prometheus-stack` chart | Installed | Bundled `prometheus`, `grafana`, `alertmanager`, `nodeExporter` all **disabled**. `prometheusOperator` + `kubeStateMetrics` enabled. |
| Custom `Prometheus` CR | `monitoring/prometheus-instance/deploy_prometheus.yaml` | Only `podMonitorSelector: {}` is set. `serviceMonitorSelector`, `ruleSelector`, `probeSelector` are **absent → match nothing**. kube-state-metrics' ServiceMonitor is therefore never scraped. |
| RBAC (Prometheus SA) | ClusterRole grants nodes/services/endpoints/pods/configmaps/endpointslices/ingresses + `/metrics` | Sufficient for cluster-wide scrape. |
| Node-level metrics | **Missing** | No `node-exporter` DaemonSet → no per-node CPU/mem/disk/network. |
| Control-plane metrics | **Missing** | kubelet, kube-apiserver, coreDns, kube-proxy, kube-controller-manager, kube-scheduler, kube-etcd ServiceMonitors not driven. |

### 1.2 Logs

| Component | Status | Notes |
|---|---|---|
| Loki | Installed | Single-binary, S3 (RustFS) backend, `replication_factor: 1`, 7d retention, 5Gi PVC. |
| Alloy | Installed | Discovers **only** pods with `cnpg.io/cluster` label. pgaudit regex pipeline → Loki. |
| System pod logs | **Missing** | kube-system, monitoring, vault, etc. not collected. |

### 1.3 Events

| Component | Status |
|---|---|
| Kubernetes events ingestion | **Missing** |

### 1.4 Dashboards

| Dashboard | Source |
|---|---|
| CloudNativePG cluster | `grafana_dashboard.yaml` (URL import) |
| pgaudit Audit Logs | `grafana_dashboard_pgaudit.yaml` (inline JSON) |
| k8s overview / nodes / pods / events / pod logs | **Missing** |

---

## 2. Target State (SOLL)

A single Grafana per region exposes:

- **Cluster overview** — node CPU/mem/disk, pod density, kube-state metrics
- **Node detail** — per-node node-exporter
- **Workload detail** — k8s views per pod, container restarts, OOM kills
- **Events** — Loki-backed table, filterable by namespace/type/reason
- **Pod logs** — Loki-backed log explorer cluster-wide
- **CNPG cluster + pgaudit** — unchanged

Prometheus scrapes all kube-prometheus-stack-bundled ServiceMonitors plus existing CNPG PodMonitors. Alloy collects every pod's logs (with CNPG pod logs still routed through pgaudit pipeline) and ingests Kubernetes events into Loki.

---

## 3. Locked Decisions

| Decision | Choice | Rationale |
|---|---|---|
| Loki sizing | PVC **20Gi**, retention **3d** | Cluster-wide log volume far exceeds CNPG-only baseline |
| Dashboards | `spec.grafanaCom.id` auto-import | Operator pulls from grafana.com at apply time; minimal repo footprint |
| Control-plane scrape (`kubeControllerManager`/`Scheduler`/`Etcd`) | **Keep enabled** | DOWN targets in kind tolerated; rules still useful for non-kind use |
| Execution | **Staged commits (3 steps)** | Each step independently testable and bisectable |

---

## 4. Staged Commits

### Commit 1 — Metrics: enable cluster-wide scraping

**Goal:** Prometheus scrapes all kube-prometheus-stack bundled ServiceMonitors plus node-exporter; existing PodMonitors keep working.

**Files**

#### 4.1.1 `monitoring/prometheus-instance/deploy_prometheus.yaml`

Replace the `Prometheus` CR `spec` with all selectors open:

```yaml
apiVersion: monitoring.coreos.com/v1
kind: Prometheus
metadata:
  name: prometheus
spec:
  serviceAccountName: prometheus
  podMonitorSelector: {}
  podMonitorNamespaceSelector: {}
  serviceMonitorSelector: {}
  serviceMonitorNamespaceSelector: {}
  ruleSelector: {}
  ruleNamespaceSelector: {}
  probeSelector: {}
  probeNamespaceSelector: {}
  nodeSelector:
    node-role.kubernetes.io/infra: ""
```

**Verify:** ClusterRoleBinding subject `namespace: default` is rewritten to `prometheus-operator` by the Kustomization `namespace:` directive. If kustomize does not rewrite subjects, change `subjects[0].namespace` to `prometheus-operator` explicitly.

#### 4.1.2 `monitoring/kube-prometheus-stack-values.yaml`

Replace contents with:

```yaml
prometheus:
  enabled: false
grafana:
  enabled: false
alertmanager:
  enabled: false

prometheusOperator:
  enabled: true

kubeStateMetrics:
  enabled: true

nodeExporter:
  enabled: true
prometheus-node-exporter:
  tolerations:
    - operator: Exists  # cover all nodes including infra/control-plane

kubeApiServer:
  enabled: true
kubelet:
  enabled: true
  serviceMonitor:
    cAdvisor: true
    probes: true
coreDns:
  enabled: true
kubeProxy:
  enabled: true

# Kept enabled per locked decision; DOWN targets expected in kind
kubeControllerManager:
  enabled: true
kubeScheduler:
  enabled: true
kubeEtcd:
  enabled: true

defaultRules:
  create: true
```

**Validation**

```bash
kubectl --context kind-k8s-eu -n prometheus-operator get servicemonitor
# expect: kube-state-metrics, node-exporter, kubelet, kube-apiserver, coredns, kube-proxy, +3 control-plane SMs

kubectl --context kind-k8s-eu -n prometheus-operator port-forward svc/prometheus-operated 9090
# Open http://localhost:9090/targets
# Expect: most targets UP; kubeControllerManager/Scheduler/Etcd DOWN on kind (acceptable)
```

**Commit message**

```
feat(monitoring): scrape full k8s core metrics

Open all selectors on the playground Prometheus CR (serviceMonitor, rule,
probe) so the kube-prometheus-stack-bundled ServiceMonitors are picked up.
Enable node-exporter and the bundled kubelet/apiserver/coreDns/kubeProxy
ServiceMonitors. kubeControllerManager/Scheduler/Etcd are kept enabled;
their endpoints bind 127.0.0.1 in kind so they will appear DOWN.
```

---

### Commit 2 — Logs & Events: cluster-wide via Alloy

**Goal:** Alloy scrapes every pod's logs (with CNPG pods still routed through the pgaudit pipeline) and ingests Kubernetes events into Loki. Loki sized for the larger volume.

**Files**

#### 4.2.1 `monitoring/alloy/alloy-config.river`

Append after the existing CNPG/pgaudit pipeline (do not remove existing blocks):

```river
// === Cluster-wide pod logs (system + workload) ===
discovery.kubernetes "all_pods" {
  role = "pod"
}

discovery.relabel "all_pods" {
  targets = discovery.kubernetes.all_pods.targets

  rule {
    source_labels = ["__meta_kubernetes_namespace"]
    target_label  = "namespace"
  }
  rule {
    source_labels = ["__meta_kubernetes_pod_name"]
    target_label  = "pod"
  }
  rule {
    source_labels = ["__meta_kubernetes_pod_container_name"]
    target_label  = "container"
  }
  rule {
    source_labels = ["__meta_kubernetes_pod_node_name"]
    target_label  = "node"
  }
  rule {
    source_labels = ["__meta_kubernetes_pod_label_app_kubernetes_io_name"]
    target_label  = "app"
  }
  // Drop CNPG pods here — they are already shipped via cnpg_logs → pgaudit pipeline
  rule {
    source_labels = ["__meta_kubernetes_pod_label_cnpg_io_cluster"]
    action        = "drop"
    regex         = ".+"
  }
}

loki.source.kubernetes "system_logs" {
  targets    = discovery.relabel.all_pods.output
  forward_to = [loki.write.grafana_loki.receiver]
}

// === Kubernetes events ===
loki.source.kubernetes_events "k8s_events" {
  job_name   = "k8s-events"
  log_format = "logfmt"
  forward_to = [loki.process.events.receiver]
}

loki.process "events" {
  stage.labels {
    values = {
      "namespace" = "namespace",
      "reason"    = "reason",
      "type"      = "type",
      "kind"      = "kind",
    }
  }
  forward_to = [loki.write.grafana_loki.receiver]
}
```

#### 4.2.2 `monitoring/alloy/alloy-values.yaml`

Extend RBAC. Append to the existing `rbac:` block:

```yaml
rbac:
  create: true
  extraRules:
    - apiGroups: [""]
      resources:
        - events
        - pods
        - pods/log
        - namespaces
        - nodes
        - nodes/proxy
      verbs: ["get", "list", "watch"]
```

#### 4.2.3 `monitoring/loki/loki-values.yaml`

Three changes:

```yaml
loki:
  limits_config:
    retention_period: 3d        # was 7d
    ingestion_rate_mb: 32       # was 16
    ingestion_burst_size_mb: 64 # was 32

singleBinary:
  persistence:
    size: 20Gi                  # was 5Gi
```

**Validation**

```bash
# Alloy components healthy
kubectl --context kind-k8s-eu -n grafana logs deploy/alloy | grep -i error

# Loki reachable + receiving streams
kubectl --context kind-k8s-eu -n grafana port-forward svc/loki 3100
curl -s http://localhost:3100/loki/api/v1/labels | jq

# Grafana Explore queries
# {namespace="kube-system"}                  → kube-system pod logs
# {job="k8s-events"}                         → events stream
# {cluster="pg-local"} |= "AUDIT"            → unchanged pgaudit path
```

**Commit message**

```
feat(monitoring): collect cluster-wide pod logs and k8s events

Extend Alloy to scrape every pod's logs (CNPG pods continue to route
through the existing pgaudit pipeline via the cnpg_logs scraper; the new
all_pods scraper drops them to avoid double-shipping). Add a
loki.source.kubernetes_events component for Kubernetes events. Bump
Alloy RBAC to cover events/pods/log/namespaces/nodes. Resize Loki
storage to 20Gi and shorten retention to 3d to absorb the larger volume.
```

---

### Commit 3 — Dashboards: k8s overview, events, pod logs

**Goal:** Grafana shows out-of-the-box k8s overview, node detail, kube-state, plus custom Loki dashboards for events and pod logs.

**Files (all new)**

#### 4.3.1 `monitoring/grafana/grafana_dashboard_node_exporter.yaml`

```yaml
apiVersion: grafana.integreatly.org/v1beta1
kind: GrafanaDashboard
metadata:
  name: node-exporter-full
  namespace: grafana
spec:
  instanceSelector:
    matchLabels:
      dashboards: "grafana"
  grafanaCom:
    id: 1860
```

#### 4.3.2 `monitoring/grafana/grafana_dashboard_kube_state.yaml`

```yaml
apiVersion: grafana.integreatly.org/v1beta1
kind: GrafanaDashboard
metadata:
  name: kube-state-metrics-v2
  namespace: grafana
spec:
  instanceSelector:
    matchLabels:
      dashboards: "grafana"
  grafanaCom:
    id: 13332
```

#### 4.3.3 `monitoring/grafana/grafana_dashboard_k8s_global.yaml`

```yaml
apiVersion: grafana.integreatly.org/v1beta1
kind: GrafanaDashboard
metadata:
  name: k8s-views-global
  namespace: grafana
spec:
  instanceSelector:
    matchLabels:
      dashboards: "grafana"
  grafanaCom:
    id: 15760
```

#### 4.3.4 `monitoring/grafana/grafana_dashboard_k8s_pods.yaml`

```yaml
apiVersion: grafana.integreatly.org/v1beta1
kind: GrafanaDashboard
metadata:
  name: k8s-views-pods
  namespace: grafana
spec:
  instanceSelector:
    matchLabels:
      dashboards: "grafana"
  grafanaCom:
    id: 15759
```

#### 4.3.5 `monitoring/grafana/grafana_dashboard_k8s_events.yaml`

Custom dashboard, Loki datasource, table panel + filters:

```yaml
apiVersion: grafana.integreatly.org/v1beta1
kind: GrafanaDashboard
metadata:
  name: k8s-events
  namespace: grafana
spec:
  instanceSelector:
    matchLabels:
      dashboards: "grafana"
  json: |
    {
      "title": "Kubernetes Events",
      "uid": "k8s-events",
      "schemaVersion": 39,
      "version": 1,
      "refresh": "30s",
      "time": {"from": "now-1h", "to": "now"},
      "templating": {
        "list": [
          {"name":"datasource","label":"Loki","type":"datasource","query":"loki","hide":0},
          {"name":"namespace","label":"Namespace","type":"query",
           "datasource":{"type":"loki","uid":"${datasource}"},
           "query":{"label":"namespace","type":1},"refresh":2,"multi":true,"includeAll":true,"allValue":".+"},
          {"name":"type","label":"Type","type":"query",
           "datasource":{"type":"loki","uid":"${datasource}"},
           "query":{"label":"type","type":1},"refresh":2,"multi":true,"includeAll":true,"allValue":".+"},
          {"name":"reason","label":"Reason","type":"query",
           "datasource":{"type":"loki","uid":"${datasource}"},
           "query":{"label":"reason","type":1},"refresh":2,"multi":true,"includeAll":true,"allValue":".+"}
        ]
      },
      "panels": [
        {
          "id": 1, "title": "Event Rate", "type": "timeseries",
          "gridPos": {"x":0,"y":0,"w":24,"h":6},
          "datasource": {"type":"loki","uid":"${datasource}"},
          "targets": [{"refId":"A","expr":"sum by (type) (rate({job=\"k8s-events\", namespace=~\"$namespace\", type=~\"$type\", reason=~\"$reason\"}[1m]))"}]
        },
        {
          "id": 2, "title": "Events", "type": "logs",
          "gridPos": {"x":0,"y":6,"w":24,"h":18},
          "datasource": {"type":"loki","uid":"${datasource}"},
          "options": {"showTime": true, "wrapLogMessage": true, "sortOrder": "Descending"},
          "targets": [{"refId":"A","expr":"{job=\"k8s-events\", namespace=~\"$namespace\", type=~\"$type\", reason=~\"$reason\"}"}]
        }
      ]
    }
```

#### 4.3.6 `monitoring/grafana/grafana_dashboard_k8s_pod_logs.yaml`

Live pod log explorer, Loki datasource, namespace/pod/container filters:

```yaml
apiVersion: grafana.integreatly.org/v1beta1
kind: GrafanaDashboard
metadata:
  name: k8s-pod-logs
  namespace: grafana
spec:
  instanceSelector:
    matchLabels:
      dashboards: "grafana"
  json: |
    {
      "title": "Kubernetes Pod Logs",
      "uid": "k8s-pod-logs",
      "schemaVersion": 39,
      "version": 1,
      "refresh": "10s",
      "time": {"from": "now-15m", "to": "now"},
      "templating": {
        "list": [
          {"name":"datasource","label":"Loki","type":"datasource","query":"loki","hide":0},
          {"name":"namespace","label":"Namespace","type":"query",
           "datasource":{"type":"loki","uid":"${datasource}"},
           "query":{"label":"namespace","type":1},"refresh":2,"multi":false,"includeAll":false},
          {"name":"pod","label":"Pod","type":"query",
           "datasource":{"type":"loki","uid":"${datasource}"},
           "query":{"label":"pod","stream":"{namespace=\"$namespace\"}","type":1},"refresh":2,"multi":false,"includeAll":false},
          {"name":"container","label":"Container","type":"query",
           "datasource":{"type":"loki","uid":"${datasource}"},
           "query":{"label":"container","stream":"{namespace=\"$namespace\", pod=\"$pod\"}","type":1},"refresh":2,"multi":true,"includeAll":true,"allValue":".+"}
        ]
      },
      "panels": [
        {
          "id": 1, "title": "Log Rate", "type": "timeseries",
          "gridPos": {"x":0,"y":0,"w":24,"h":6},
          "datasource": {"type":"loki","uid":"${datasource}"},
          "targets": [{"refId":"A","expr":"sum by (container) (rate({namespace=\"$namespace\", pod=\"$pod\", container=~\"$container\"}[1m]))"}]
        },
        {
          "id": 2, "title": "Logs", "type": "logs",
          "gridPos": {"x":0,"y":6,"w":24,"h":18},
          "datasource": {"type":"loki","uid":"${datasource}"},
          "options": {"showTime": true, "wrapLogMessage": true, "sortOrder": "Descending"},
          "targets": [{"refId":"A","expr":"{namespace=\"$namespace\", pod=\"$pod\", container=~\"$container\"}"}]
        }
      ]
    }
```

#### 4.3.7 `monitoring/grafana/kustomization.yaml`

Add the six new resources to the existing list. Final list expected:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: grafana
resources:
  - grafana_instance.yaml
  - grafana_datasource.yaml
  - grafana_datasource_loki.yaml
  - grafana_dashboard.yaml
  - grafana_dashboard_pgaudit.yaml
  - grafana_dashboard_node_exporter.yaml
  - grafana_dashboard_kube_state.yaml
  - grafana_dashboard_k8s_global.yaml
  - grafana_dashboard_k8s_pods.yaml
  - grafana_dashboard_k8s_events.yaml
  - grafana_dashboard_k8s_pod_logs.yaml
```

#### 4.3.8 `monitoring/README.md`

Extend the **Resource Ownership** table with rows for node-exporter, Loki, Alloy (system + events), and the six new dashboards. Add a short **Dashboards** subsection enumerating the imported grafana.com IDs and the two custom Loki dashboards.

**Validation**

```bash
# Each new dashboard reconciled
kubectl --context kind-k8s-eu -n grafana get grafanadashboards

# Visit Grafana
# - Node Exporter Full → node CPU/mem/disk panels populated
# - kube-state-metrics-v2 → workload counts populated
# - k8s Views / Global, Pods → cluster + per-pod views populated
# - Kubernetes Events → table populated, filters work
# - Kubernetes Pod Logs → namespace dropdown lists kube-system, grafana, etc.
# - CNPG cluster + pgaudit dashboards → unchanged
```

**Commit message**

```
feat(monitoring): add k8s overview, events and pod log dashboards

Provision four community dashboards via grafanaCom.id (Node Exporter
Full 1860, kube-state-metrics-v2 13332, k8s Views Global 15760, k8s
Views Pods 15759) plus two custom Loki dashboards for cluster events
and pod log exploration. Extend the kustomization and README accordingly.
```

---

## 5. Risks & Watchpoints

| Risk | Mitigation |
|---|---|
| Datasource UID mismatch — community dashboards expect `prometheus` / `loki` UIDs | Existing `GrafanaDatasource` is named `prometheus`; verify Loki datasource resource name post-install. Fix UIDs in dashboard JSON if needed. |
| Loki single-binary saturates 20Gi under load | Monitor `loki_ingester_memory_chunks` and PVC use; bump to 50Gi or shrink retention to 1d if needed. |
| `grafanaCom.id` requires Grafana outbound internet | Current Grafana spec has no proxy override; confirm cluster egress from `grafana` namespace works. |
| RBAC merge — `extraRules` may not append on all chart versions | If Alloy reports forbidden on events, replace the chart-managed ClusterRole with a manual one. |
| ClusterRoleBinding subject namespace (`default` vs `prometheus-operator`) | Run `kubectl auth can-i get nodes --as=system:serviceaccount:prometheus-operator:prometheus` after Commit 1; if forbidden, hard-set the binding namespace. |
| kind 127.0.0.1 binding | DOWN targets on kubeControllerManager/Scheduler/Etcd are accepted per locked decision; document in README. |

---

## 6. Rollback

Each commit is independently revertible:

- **Commit 1**: `git revert` restores prior `Prometheus` CR (PodMonitor-only) and prior chart values; node-exporter DaemonSet removed via Helm upgrade.
- **Commit 2**: `git revert` restores prior Alloy config (CNPG only) and prior Loki sizing; existing log streams in Loki age out per retention.
- **Commit 3**: `git revert` deletes the new `GrafanaDashboard` resources via kustomize re-apply; Grafana operator removes them.

Re-run `monitoring/setup.sh <region>` after any revert to converge.

---

## 7. Out of Scope

- Alertmanager / alert rules
- Tempo / traces
- Mimir migration
- Grafana SSO / Dex integration (handled in `vault` branch separately)
- pgBouncer / pooler-local-ro metrics (Phase 3 in `docs/SOLL.md`)
