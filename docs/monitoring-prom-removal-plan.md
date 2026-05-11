# Plan — Replace Prometheus CR with Alloy + Mimir (Full Removal)

## Context

Closes the last "Out of Scope" item from `docs/monitoring-kind-mimir-plan.md`: **Replacing the existing Prometheus datasource**. Scope expanded after interactive prompts to full removal of the playground's bespoke Prometheus CR. Mimir becomes the sole metrics store; Alloy becomes the sole scraper.

### Locked decisions (interactive)

| # | Question | Choice |
|---|---|---|
| 1 | Scope | **Full removal — delete Prometheus CR + `monitoring/prometheus-instance/`** |
| 2 | UID strategy | **Dual datasource: alias DS at `uid: prometheus` AND keep `uid: mimir`** |
| 3 | Multi-region tenant default | **Per-region — each region's Grafana queries own tenant** |
| 4 | Self-service (`grafana-rbr-ver`) | **Mirror the change** |
| 5 | Scrape replacement | **Extend Alloy with `prometheus.operator.servicemonitors`** |
| 6 | Alerting rules | **Mimir Ruler via Alloy `mimir.rules.kubernetes` (scaffolding only — repo has zero `PrometheusRule` CRs today)** |
| 7 | Debug UX | **Lose Prom Web UI; document Mimir query path** |

### Current state (verified)

- `monitoring/grafana/grafana_datasource.yaml` — local Prom DS (`name: prometheus`, `DS_PROMETHEUS`, URL `prometheus-operated.prometheus-operator.svc:9090`)
- `monitoring/grafana/grafana_datasource_mimir.yaml` — Mimir hub DS (`uid: mimir`, hardcoded tenant `local`)
- `monitoring/grafana/grafana_datasource_mimir_tempo.yaml` — Mimir tenant `tempo` for span metrics
- Imported dashboards (`grafana_dashboard_k8s_global.yaml`, `_pods.yaml`, `_node_exporter.yaml`) carry `inputName: DS_PROMETHEUS` → `datasourceName: DS_MIMIR` remap
- Inline dashboards under `monitoring/grafana/dashboards/*.json` reference `"type": "prometheus"` panel-level DS (UID-by-default — solved by alias DS at `uid: prometheus`)
- `monitoring/prometheus-instance/` — `prometheus-cr.yaml.tpl` + `prometheus-rbac.yaml` + `kustomization.yaml`
- `monitoring/setup.sh` — two apply steps (kustomize RBAC at L53-54; envsubst CR at L114-116)
- `monitoring/kube-prometheus-stack-values.yaml` — bundled `prometheus: { enabled: false }` already (no change needed)
- `monitoring/alloy/alloy-config.river` — 180 lines: logs/traces only; no metrics components today
- Alloy chart `1.8.0` already installed per region (`monitoring/setup.sh` L265-269)
- Repo grep `kind: PrometheusRule` → **zero matches**
- `demo/yaml/self-service/grafana/grafanadatasource-prometheus-rbr-ver.yaml` — symmetric per-region Prom DS for `grafana-rbr-ver`

### End-state topology

```
ServiceMonitors ──┐
PodMonitors    ───┼──> Alloy (per region) ──remote_write──> Mimir hub (tenant=${REGION})
PrometheusRules ──┘                                          │
                                                             ├──> Mimir Ruler (rules tenant=${REGION})
                                                             └──> Grafana DS:
                                                                   • uid:prometheus  (alias, region tenant)
                                                                   • uid:mimir       (explicit, region tenant)
                                                                   • uid:mimir-tempo (tenant=tempo, unchanged)
```

---

## Part A — Alloy as ServiceMonitor/PodMonitor scraper

### A.1 Patch — `monitoring/alloy/alloy-config.river`

Append a new metrics branch after the existing logs/traces blocks. Reference: `prometheus.operator.servicemonitors` discovers all `monitoring.coreos.com/v1 ServiceMonitor` CRs cluster-wide and forwards built scrape configs to a `prometheus.remote_write` receiver.

```hcl
// === Metrics: ServiceMonitor + PodMonitor scrape → Mimir remote_write ===

// Hub region uses in-cluster Service; non-hub regions push via sslip.io.
// MIMIR_PUSH_URL substituted at install time by monitoring/setup.sh.
prometheus.remote_write "mimir" {
  endpoint {
    url = "${MIMIR_PUSH_URL}"
    headers = {
      "X-Scope-OrgID" = "${REGION}",
    }
    queue_config {
      capacity           = 10000
      max_shards         = 10
      max_samples_per_send = 2000
    }
  }
  external_labels = {
    cluster = "${REGION}",
  }
}

prometheus.operator.servicemonitors "scrape" {
  forward_to = [prometheus.remote_write.mimir.receiver]
  // Cluster-wide discovery — no namespace filter
}

prometheus.operator.podmonitors "scrape" {
  forward_to = [prometheus.remote_write.mimir.receiver]
}

prometheus.operator.probes "scrape" {
  forward_to = [prometheus.remote_write.mimir.receiver]
}
```

> The current `alloy-config.river` is rendered via `--set-file alloy.configMap.content=...` (no envsubst step today). Adding `${MIMIR_PUSH_URL}`/`${REGION}` requires either (a) running the file through `envsubst` in `monitoring/setup.sh` before `--set-file`, or (b) injecting via Alloy's `--config.file.env.*` env-expansion. Use **(a)** for consistency with existing `*.tpl` pattern. Rename `alloy-config.river` → `alloy-config.river.tpl`.

### A.2 Patch — `monitoring/alloy/alloy-values.yaml`

Extend `rbac.extraRules` so Alloy can read ServiceMonitor/PodMonitor/Probe/PrometheusRule CRs:

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
        - services            # NEW — ServiceMonitor target resolution
        - endpoints           # NEW
        - configmaps          # NEW — scrape config CMs (e.g. additional)
        - secrets             # NEW — TLS / basic_auth from ServiceMonitor refs
      verbs: ["get", "list", "watch"]
    - apiGroups: ["monitoring.coreos.com"]
      resources:
        - servicemonitors
        - podmonitors
        - probes
        - prometheusrules
      verbs: ["get", "list", "watch"]
    - apiGroups: ["discovery.k8s.io"]
      resources: ["endpointslices"]
      verbs: ["get", "list", "watch"]
    - nonResourceURLs: ["/metrics", "/metrics/cadvisor", "/metrics/probes"]
      verbs: ["get"]
```

### A.3 Patch — `monitoring/setup.sh` — render Alloy config

Replace the `--set-file` line with an `envsubst` pipeline. Insert before `helm_upgrade_install alloy`:

```bash
RENDERED_ALLOY_CONFIG="$(mktemp)"
REGION="${region}" MIMIR_PUSH_URL="${MIMIR_PUSH_URL}" \
    envsubst '${REGION} ${MIMIR_PUSH_URL}' \
    < "${GIT_REPO_ROOT}/monitoring/alloy/alloy-config.river.tpl" \
    > "${RENDERED_ALLOY_CONFIG}"

helm_upgrade_install alloy alloy \
    grafana "${CONTEXT_NAME}" "${ALLOY_CHART_VERSION}" \
    --repo-url https://grafana.github.io/helm-charts \
    --values "${GIT_REPO_ROOT}/monitoring/alloy/alloy-values.yaml" \
    --set-file "alloy.configMap.content=${RENDERED_ALLOY_CONFIG}"

rm -f "${RENDERED_ALLOY_CONFIG}"
```

`MIMIR_PUSH_URL` is already computed earlier in the per-region loop for the (about-to-be-deleted) Prom CR remoteWrite block — **reuse it**.

### A.4 Watchpoint — metric keep-list lost

The deleted `prometheus-cr.yaml.tpl` carried `writeRelabelConfigs` keep-list:
```
regex: '(up|scrape_.*|kube_.*|node_.*|kubelet_.*|apiserver_.*|cnpg_.*|pg_.*)'
```

To preserve disk-budget guarantees on RustFS, port the same keep-list to `prometheus.remote_write.mimir`:

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
  external_labels = { cluster = "${REGION}" }
}
```

Expanded slightly: added `traces_.*` (Tempo metrics-generator already remoteWrites these to tenant `tempo` — not affected, but kept for symmetry if any service exports `traces_*` natively) and `process_.*`/`go_.*` (default exporter metrics) for debug visibility.

---

## Part B — Mimir Ruler scaffolding via Alloy `mimir.rules.kubernetes`

### B.1 Why now if zero `PrometheusRule` CRs exist?

Anticipates first-rule landing. Authoring a rule later means just creating a `PrometheusRule` CR — no scraper reconfiguration. Component reads CRs continuously; new rules sync within seconds.

### B.2 Append to `monitoring/alloy/alloy-config.river.tpl`

```hcl
// === PrometheusRule → Mimir Ruler ===
mimir.rules.kubernetes "rules" {
  // Hub region — in-cluster Service; non-hub — sslip.io (resolved via MIMIR_PUSH_URL host)
  address    = "${MIMIR_RULER_URL}"
  tenant_id  = "${REGION}"

  // Watch all namespaces by default; constrain via label selector later if noisy.
  rule_selector       = {}
  rule_namespace_selector = {}
}
```

`MIMIR_RULER_URL` derivation in `setup.sh`:

```bash
if [[ "${region}" == "${HUB_REGION}" ]]; then
    MIMIR_RULER_URL="http://mimir-ruler.mimir.svc.cluster.local:8080"
else
    HUB_TRAEFIK_IP="$(get_traefik_lb_ip "${HUB_CONTEXT}" 30)"
    HUB_TRAEFIK_DASHED="$(ip_to_dashed "${HUB_TRAEFIK_IP}")"
    MIMIR_RULER_URL="http://mimir-ruler.${HUB_TRAEFIK_DASHED}.sslip.io"
fi
```

### B.3 New file — `monitoring/mimir/ingressroute-ruler.yaml.tpl` (multi-region only)

```yaml
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: mimir-ruler
  namespace: mimir
spec:
  entryPoints: [web]
  routes:
    - match: Host(`mimir-ruler.${TRAEFIK_IP_DASHED}.sslip.io`)
      kind: Rule
      services:
        - name: mimir-ruler
          port: 8080
```

Apply only when `${#REGIONS[@]} -gt 1` and `region == HUB_REGION` — mirror Mimir push IngressRoute pattern.

### B.4 Add envsubst var

In `monitoring/setup.sh` Alloy render step:

```bash
envsubst '${REGION} ${MIMIR_PUSH_URL} ${MIMIR_RULER_URL}'
```

---

## Part C — Grafana datasource swap

### C.1 New file — `monitoring/grafana/grafana_datasource_mimir.yaml.tpl` (replaces existing `.yaml`)

Per-region tenant via `${REGION}` substitution:

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
    uid: mimir
    type: prometheus
    access: proxy
    url: http://mimir-nginx.mimir.svc.cluster.local/prometheus
    isDefault: false
    jsonData:
      httpHeaderName1: X-Scope-OrgID
      timeInterval: 15s
      exemplarTraceIdDestinations:
        - name: traceID
          datasourceUid: tempo
    secureJsonData:
      httpHeaderValue1: ${REGION}
```

### C.2 New file — `monitoring/grafana/grafana_datasource_prometheus_alias.yaml.tpl`

Alias DS at `uid: prometheus` — same Mimir backend, marked `isDefault: true`. Solves inline community-dashboard JSON that hardcodes `"datasource":{"uid":"prometheus"}`.

```yaml
apiVersion: grafana.integreatly.org/v1beta1
kind: GrafanaDatasource
metadata:
  name: prometheus
  namespace: grafana
spec:
  instanceSelector:
    matchLabels:
      dashboards: grafana
  allowCrossNamespaceImport: true
  datasource:
    name: DS_PROMETHEUS         # legacy display name — keeps inputName remap unnecessary
    uid: prometheus              # ← matches `"uid":"prometheus"` in imported dashboards
    type: prometheus
    access: proxy
    url: http://mimir-nginx.mimir.svc.cluster.local/prometheus
    isDefault: true
    jsonData:
      httpHeaderName1: X-Scope-OrgID
      timeInterval: 15s
      exemplarTraceIdDestinations:
        - name: traceID
          datasourceUid: tempo
    secureJsonData:
      httpHeaderValue1: ${REGION}
```

> Two GrafanaDatasource CRs, one `uid: prometheus` and one `uid: mimir`, both pointing at Mimir with the same per-region tenant header. Grafana renders them as two separate selectable datasources in the picker; dashboards land on whichever UID they reference. Operator-level allows the duplication — UIDs are the constraint, names are display-only.

### C.3 Delete — `monitoring/grafana/grafana_datasource.yaml`

The old local-Prom DS. Removed from kustomization (see C.5).

### C.4 Patch — `monitoring/grafana/grafana_datasource_mimir_tempo.yaml`

Unchanged; tenant header stays `tempo` (span-metrics tenant is global, not per-region).

### C.5 Patch — `monitoring/grafana/kustomization.yaml`

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: grafana
resources:
  - grafana_instance.yaml
  # grafana_datasource.yaml       ← REMOVED (local Prom)
  - grafana_datasource_loki.yaml
  - grafana_dashboard.yaml
  - grafana_dashboard_pgaudit.yaml
  - grafana_dashboard_node_exporter.yaml
  - grafana_dashboard_kube_state.yaml
  - grafana_dashboard_k8s_global.yaml
  - grafana_dashboard_k8s_pods.yaml
  - grafana_dashboard_k8s_events.yaml
  - grafana_dashboard_k8s_pod_logs.yaml
  # grafana_datasource_mimir.yaml         ← REMOVED (templated by setup.sh now)
  - grafana_datasource_mimir_tempo.yaml
  - grafana_datasource_tempo.yaml
  - grafana_dashboard_cnpg_custom.yaml
  - grafana_dashboard_traefik_traces.yaml
```

Mimir DS + alias DS applied via `envsubst | kubectl apply` from `monitoring/setup.sh` (see C.6) — kustomize can't expand env vars.

### C.6 Patch — `monitoring/setup.sh` Grafana section

Inside per-region loop, after `kubectl kustomize monitoring/grafana | kubectl apply`:

```bash
echo "📊 Applying Mimir datasource (tenant=${region}) + prometheus alias..."
REGION="${region}" envsubst '${REGION}' \
    < "${GIT_REPO_ROOT}/monitoring/grafana/grafana_datasource_mimir.yaml.tpl" \
    | kubectl --context "${CONTEXT_NAME}" apply -f -

REGION="${region}" envsubst '${REGION}' \
    < "${GIT_REPO_ROOT}/monitoring/grafana/grafana_datasource_prometheus_alias.yaml.tpl" \
    | kubectl --context "${CONTEXT_NAME}" apply -f -
```

### C.7 Patch — dashboard input remaps (optional cleanup)

`grafana_dashboard_k8s_global.yaml`, `_pods.yaml`, `_node_exporter.yaml` carry:
```yaml
datasources:
  - inputName: "DS_PROMETHEUS"
    datasourceName: "DS_MIMIR"
```

With the alias DS in place (UID `prometheus`, name `DS_PROMETHEUS`), these remaps are redundant. **Leave them in** — they're harmless and document intent. If they cause Grafana operator confusion, drop to:
```yaml
datasources:
  - inputName: "DS_PROMETHEUS"
    datasourceName: "DS_PROMETHEUS"
```
(no-op rename, but explicit).

---

## Part D — Remove Prometheus CR + scaffolding

### D.1 Delete

- `monitoring/prometheus-instance/prometheus-cr.yaml.tpl`
- `monitoring/prometheus-instance/prometheus-rbac.yaml`
- `monitoring/prometheus-instance/kustomization.yaml`
- `monitoring/prometheus-instance/` (empty dir)

### D.2 Patch — `monitoring/setup.sh`

Remove L52-55 (kustomize RBAC apply) and L113-116 (envsubst CR apply). Keep the `MIMIR_PUSH_URL` derivation block — Alloy needs it now (Part A.3).

```bash
# DELETE:
#     kubectl kustomize ${GIT_REPO_ROOT}/monitoring/prometheus-instance | \
#         kubectl --context=${CONTEXT_NAME} apply --force-conflicts --server-side -f -
#
# DELETE:
#     REGION="${region}" MIMIR_PUSH_URL="${MIMIR_PUSH_URL}" \
#         envsubst '${REGION} ${MIMIR_PUSH_URL}' \
#         < "${GIT_REPO_ROOT}/monitoring/prometheus-instance/prometheus-cr.yaml.tpl" \
#         | kubectl --context "${CONTEXT_NAME}" apply --force-conflicts --server-side -f -
```

### D.3 Patch — `monitoring/teardown.sh`

Add explicit cleanup of any leftover Prometheus CR from previous installs (idempotency):

```bash
kubectl --context "${CONTEXT_NAME}" -n prometheus-operator \
    delete prometheus.monitoring.coreos.com prometheus --ignore-not-found
kubectl --context "${CONTEXT_NAME}" -n prometheus-operator \
    delete sa,clusterrole,clusterrolebinding prometheus --ignore-not-found
```

### D.4 No-op — `monitoring/kube-prometheus-stack-values.yaml`

`prometheus: { enabled: false }` already set. `prometheusOperator: { enabled: true }` stays — operator reconciles ServiceMonitor/PodMonitor/PrometheusRule CRs, which Alloy now reads directly. No CR provisioning by operator (no `Prometheus` CR exists for it to manage).

---

## Part E — Self-service (`grafana-rbr-ver`) mirror

### E.1 Delete — `demo/yaml/self-service/grafana/grafanadatasource-prometheus-rbr-ver.yaml`

Old local-Prom DS for self-service Grafana.

### E.2 New file — `demo/yaml/self-service/grafana/grafanadatasource-mimir-rbr-ver.yaml.tpl`

```yaml
apiVersion: grafana.integreatly.org/v1beta1
kind: GrafanaDatasource
metadata:
  name: mimir-rbr-ver
  namespace: grafana-rbr-ver
spec:
  instanceSelector:
    matchLabels:
      dashboards: grafana-rbr-ver
  allowCrossNamespaceImport: true
  datasource:
    name: DS_MIMIR
    uid: mimir-rbr-ver
    type: prometheus
    access: proxy
    url: http://mimir-nginx.mimir.svc.cluster.local/prometheus
    isDefault: false
    jsonData:
      httpHeaderName1: X-Scope-OrgID
      timeInterval: 15s
      exemplarTraceIdDestinations:
        - name: traceID
          datasourceUid: tempo-rbr-ver
    secureJsonData:
      httpHeaderValue1: ${REGION}
```

### E.3 New file — `demo/yaml/self-service/grafana/grafanadatasource-prometheus-alias-rbr-ver.yaml.tpl`

```yaml
apiVersion: grafana.integreatly.org/v1beta1
kind: GrafanaDatasource
metadata:
  name: prometheus-rbr-ver
  namespace: grafana-rbr-ver
spec:
  instanceSelector:
    matchLabels:
      dashboards: grafana-rbr-ver
  allowCrossNamespaceImport: true
  datasource:
    name: DS_PROMETHEUS
    uid: prometheus-rbr-ver       # rbr-ver suffix per existing UID-isolation pattern
    type: prometheus
    access: proxy
    url: http://mimir-nginx.mimir.svc.cluster.local/prometheus
    isDefault: true
    jsonData:
      httpHeaderName1: X-Scope-OrgID
      timeInterval: 15s
    secureJsonData:
      httpHeaderValue1: ${REGION}
```

> **UID suffix `rbr-ver`** mandatory per existing pattern (memory: "self-service Grafana dashboard UIDs get `-rbr-ver` suffix to prevent GrafanaOperator collision"). Same applies to datasources sharing CRD scope across the two Grafana instances.

### E.4 Patch — `demo/self-service-setup.sh`

Replace the existing rbr-ver Prom DS apply line with the two new envsubst-rendered files. Sketch:

```bash
for f in grafanadatasource-mimir-rbr-ver grafanadatasource-prometheus-alias-rbr-ver; do
    REGION="${region}" envsubst '${REGION}' \
        < "${GIT_REPO_ROOT}/demo/yaml/self-service/grafana/${f}.yaml.tpl" \
        | kubectl --context "${CONTEXT_NAME}" apply -f -
done
```

Adapt to the existing loop structure in `demo/self-service-setup.sh` (currently does flat `kubectl apply -f` per file).

### E.5 Self-service dashboards — check for `uid: prometheus-rbr-ver` references

Existing rbr-ver dashboards under `demo/yaml/self-service/grafana/*-rbr-ver.yaml` likely target `DS_PROMETHEUS`/UID `prometheus`. With UID `prometheus-rbr-ver` (E.3), update dashboard `datasource.uid` references accordingly OR have the alias DS use `uid: prometheus` (no suffix) — verify GrafanaOperator collision behavior first. Recommend testing UID-suffix path; fall back to no-suffix if operator allows (cross-instance label selector should prevent collision).

---

## Part F — Documentation

### F.1 Patch — `monitoring/README.md`

Add a section after the existing Mimir block:

```markdown
## Metrics scrape architecture

Alloy is the sole scraper. ServiceMonitor / PodMonitor / Probe / PrometheusRule CRs
are discovered cluster-wide by `prometheus.operator.*` components and forwarded to
Mimir (`X-Scope-OrgID: <region>`).

There is **no Prometheus pod**. The kube-prometheus-stack chart installs only:
- prometheus-operator (reconciles CRDs — required by Alloy's discovery)
- kube-state-metrics
- node-exporter
- pre-built ServiceMonitors (kubelet, kube-controller-manager, kube-scheduler, kube-proxy, etcd, coreDns, kube-apiserver)

### Debugging metrics

- **Alloy status / config**: `kubectl -n grafana port-forward svc/alloy 12345:12345` → `http://localhost:12345/`
- **Mimir ad-hoc query**: `kubectl -n mimir port-forward svc/mimir-nginx 8080:80`
  then `curl -H "X-Scope-OrgID: local" 'http://localhost:8080/prometheus/api/v1/query?query=up'`
- **Grafana**: use either `DS_PROMETHEUS` (uid `prometheus`) or `DS_MIMIR` (uid `mimir`). Both alias the same Mimir, region-scoped tenant. Use `DS_MIMIR_TEMPO` for span-metrics (tenant `tempo`).

### Alerting

`PrometheusRule` CRs sync to Mimir Ruler via Alloy's `mimir.rules.kubernetes`
component. Repo carries no rules today — author one and apply; sync happens
within seconds. Tenant scoping mirrors metrics (rule fires in `<region>` tenant
and reads only that region's series unless `monitoring.grafana.com/source_tenants`
annotation federates).
```

### F.2 Update `docs/IST.md` / `docs/SOLL.md` if present

Memory mentions `docs/IST.md` + `docs/SOLL.md` (W1-W8 roadmap). Reflect Prom CR removal in current state inventory if those docs cover monitoring.

---

## Part G — Verification

### G.1 Scrape coverage

```bash
# Alloy ServiceMonitor CRDs discovered — top-level .targets doesn't exist; use debugInfo
kubectl --context kind-k8s-local -n grafana port-forward svc/alloy 12345 &
sleep 2
curl -s http://localhost:12345/api/v0/web/components/prometheus.operator.servicemonitors.scrape \
    | python3 -c "import sys,json; d=json.load(sys.stdin); print(len([x for x in d.get('debugInfo',[]) if x.get('name')=='crds']))"
# expect: >= 10 (all kube-prometheus-stack SMs; 10 confirmed on kind-k8s-local)
```

### G.2 Mimir series count (tenant scoping works)

```bash
kubectl -n mimir port-forward svc/mimir-nginx 8080:80 &
sleep 2

# Region tenant
curl -s -H "X-Scope-OrgID: local" \
    'http://localhost:8080/prometheus/api/v1/query?query=count(up)' \
    | jq '.data.result[0].value[1]'
# expect: > 0

# Cross-region (multi-region only)
curl -s -H "X-Scope-OrgID: eu" 'http://localhost:8080/prometheus/api/v1/label/cluster/values'
# expect: ["eu"]   (not ["eu","us"]; per-region scoping enforced)
```

### G.3 Grafana datasource picker

- Open Grafana → Connections → Datasources
- Expect exactly: `DS_PROMETHEUS` (default), `DS_MIMIR`, `DS_MIMIR_TEMPO`, `DS_TEMPO`, `DS_LOKI`
- **Not present**: any DS pointing at `prometheus-operated.prometheus-operator.svc:9090`
- Explore → `DS_PROMETHEUS` → `up{job="kubelet"}` → returns series
- Explore → `DS_MIMIR` → same query → identical series

### G.4 Imported dashboards render

- `k8s/views/global` (id 15757), `k8s/views/pods` (15759), `node-exporter-full` (1860):
  All panels populate without "Datasource not found" errors. Tests both alias DS path (uid: prometheus) and explicit Mimir path.

### G.5 No Prometheus CR remains

```bash
kubectl --context kind-k8s-local get prometheus -A
# expect: No resources found
kubectl --context kind-k8s-local -n prometheus-operator get pods | grep -i 'prometheus-prometheus-0\|^prometheus'
# expect: empty (only prometheus-operator-* deployment pod remains)
```

### G.6 PrometheusRule scaffold

```bash
# Apply a sample rule
cat <<'EOF' | kubectl apply -f -
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: smoke-test
  namespace: default
spec:
  groups:
    - name: smoke
      rules:
        - record: smoke:up:count
          expr: count(up)
EOF

# Verify it lands in Mimir Ruler
curl -s -H "X-Scope-OrgID: local" http://localhost:8080/api/v1/rules | jq '.data.groups[].rules[] | select(.name=="smoke:up:count")'
# expect: rule object returned

# Verify Alloy is rendering the record
curl -s -H "X-Scope-OrgID: local" \
    'http://localhost:8080/prometheus/api/v1/query?query=smoke:up:count'
# expect: scalar > 0 after ~1m

kubectl delete prometheusrule -n default smoke-test
```

### G.7 Self-service Grafana

- Open `grafana-rbr-ver` UI
- Datasource picker shows `DS_PROMETHEUS` (uid `prometheus-rbr-ver`) + `DS_MIMIR` (uid `mimir-rbr-ver`)
- rbr-ver dashboards render without DS errors

---

## File-level Changeset Summary

### Modify

- `monitoring/alloy/alloy-config.river` → rename `.tpl`, add Parts A.1 + B.2 blocks
- `monitoring/alloy/alloy-values.yaml` — extra RBAC (Part A.2)
- `monitoring/setup.sh` — envsubst-render Alloy config; drop Prom CR apply; add Mimir+alias DS apply; (multi-region) apply mimir-ruler IngressRoute
- `monitoring/teardown.sh` — explicit Prom CR / RBAC cleanup
- `monitoring/grafana/kustomization.yaml` — remove `grafana_datasource.yaml` + `grafana_datasource_mimir.yaml`
- `monitoring/README.md` — scrape architecture + debug + alerting section
- `demo/self-service-setup.sh` — apply two new rbr-ver datasource templates
- `demo/yaml/self-service/grafana/*-rbr-ver.yaml` dashboards — update datasource UID refs if collision

### Create

- `monitoring/alloy/alloy-config.river.tpl` (from existing `.river` + new blocks)
- `monitoring/grafana/grafana_datasource_mimir.yaml.tpl` (templated replacement)
- `monitoring/grafana/grafana_datasource_prometheus_alias.yaml.tpl` (alias DS)
- `monitoring/mimir/ingressroute-ruler.yaml.tpl` (multi-region ruler push)
- `demo/yaml/self-service/grafana/grafanadatasource-mimir-rbr-ver.yaml.tpl`
- `demo/yaml/self-service/grafana/grafanadatasource-prometheus-alias-rbr-ver.yaml.tpl`

### Delete

- `monitoring/prometheus-instance/prometheus-cr.yaml.tpl`
- `monitoring/prometheus-instance/prometheus-rbac.yaml`
- `monitoring/prometheus-instance/kustomization.yaml`
- `monitoring/prometheus-instance/` (dir)
- `monitoring/grafana/grafana_datasource.yaml`
- `monitoring/grafana/grafana_datasource_mimir.yaml` (replaced by `.tpl`)
- `demo/yaml/self-service/grafana/grafanadatasource-prometheus-rbr-ver.yaml`

### Reused utilities

- `helm_upgrade_install`, `get_cluster_context`, `get_traefik_lb_ip`, `ip_to_dashed` — `scripts/common.sh`
- `MIMIR_PUSH_URL` derivation already in `monitoring/setup.sh` per-region loop
- `envsubst` + `*.tpl` rendering pattern — repo-wide

---

## Risks / Watchpoints

| Risk | Mitigation |
|---|---|
| Alloy 1.8.0 `prometheus.operator.servicemonitors` doesn't honor `*Selector: {}` empty matchers | Test against running cluster; if buggy, set explicit `match_expressions: []`. Component changelog through 1.x stable. |
| Series volume jumps after scrape switch (different default keep-list) | Preserve relabel keep-list from old Prom CR (Part A.4). Monitor RustFS bucket size delta in first hour. |
| Two GrafanaDatasource CRs with same backend URL trigger operator dedup | GrafanaOperator dedups by UID, not URL — confirmed via spec. Two distinct UIDs OK. |
| Inline community dashboards reference both `"uid":"prometheus"` AND `"name":"DS_PROMETHEUS"` inconsistently | Alias DS covers both: same `name: DS_PROMETHEUS` + `uid: prometheus`. Verify panel-level overrides per dashboard. |
| Per-region tenant header forces multi-tenant Grafana → users can't see cross-region in one panel | Add a third "all" DS later if needed: `uid: mimir-all`, header `__all__`. Out of scope. |
| `mimir.rules.kubernetes` requires Mimir Ruler `enabled: true` AND `ruler_storage` configured | Already set per `monitoring/kind-mimir-plan.md` B.3 (`mimir-ruler` bucket + `ruler: { replicas: 1 }`). Verify pod healthy before enabling Alloy rules block. |
| Non-hub Alloy can't reach `mimir-ruler.<hub>.sslip.io` until hub Tempo plan's IngressRoute pattern is mirrored for ruler | New `monitoring/mimir/ingressroute-ruler.yaml.tpl` (B.3) applied on hub. |
| Self-service `rbr-ver` dashboard UID collisions if alias DS uses `uid: prometheus` (no suffix) across two Grafana instances | Use `uid: prometheus-rbr-ver` suffix per existing memory pattern; update rbr-ver dashboard JSON refs. |
| Alloy RBAC expansion grants cluster-wide `secrets` read (needed for ServiceMonitor TLS refs) | Documented elevation; acceptable in playground. Production: scope to known namespaces via `prometheus.operator.servicemonitors`'s `namespaces` block. |
| Loss of Prom UI breaks any external bookmark/automation referencing `:9090/api/v1/query` | None today (verified zero ref in repo); document new query endpoint in `monitoring/README.md`. |
| `kube-prometheus-stack` operator could attempt to manage an absent Prometheus CR | Operator only acts on CRs that exist. Absence = no-op. No deployment created. |
| `prometheus.operator.servicemonitors` does NOT auto-scrape Alloy's own `/metrics` (no ServiceMonitor exists for Alloy) | Add a minimal `ServiceMonitor` for Alloy itself OR an explicit `prometheus.scrape` block targeting Alloy's port. Recommend adding ServiceMonitor for consistency. |
| `cluster=${REGION}` external_label conflicts with `cluster` label set by some exporters | Old Prom CR set the same external label. No diff vs. baseline. |
| Mimir ruler `tenant_id` mismatch between sync target and metric tenant | Both set to `${REGION}` — rules read same-tenant series natively. No federation needed for single-tenant playground. |

---

## Suggested Commit Sequence

1. **Commit 1** — `feat(alloy): scrape ServiceMonitors → remote_write to Mimir`
   Touches: `monitoring/alloy/alloy-config.river{→.tpl}`, `monitoring/alloy/alloy-values.yaml`, `monitoring/setup.sh` (Alloy render block + `MIMIR_PUSH_URL` reuse).
   Validation: G.1 + G.2 (Alloy components healthy, Mimir series count > 0 from new scraper). Prom CR still running in parallel — both write to Mimir; expect doubled samples briefly. **No reverse compatibility hacks needed** because the keep-list dedupes by series.

2. **Commit 2** — `feat(grafana): add Mimir-backed `prometheus` alias datasource`
   Touches: `monitoring/grafana/grafana_datasource_prometheus_alias.yaml.tpl` (new), `monitoring/grafana/grafana_datasource_mimir.yaml{→.tpl}`, `monitoring/grafana/kustomization.yaml`, `monitoring/setup.sh` (DS apply block).
   Validation: G.3 (datasource picker shows both UIDs); existing imported dashboards still render via old local Prom DS too (parallel).

3. **Commit 3** — `feat(monitoring): mirror change to grafana-rbr-ver (self-service)`
   Touches: `demo/yaml/self-service/grafana/grafanadatasource-{mimir,prometheus-alias}-rbr-ver.yaml.tpl` (new), `demo/self-service-setup.sh`, rbr-ver dashboards if UID conflict.
   Validation: G.7.

4. **Commit 4** — `feat(monitoring): mimir.rules.kubernetes for Mimir Ruler sync`
   Touches: `monitoring/alloy/alloy-config.river.tpl` (B.2 block), `monitoring/setup.sh` (`MIMIR_RULER_URL` + envsubst extra var), `monitoring/mimir/ingressroute-ruler.yaml.tpl` (new).
   Validation: G.6 (smoke-test rule round-trip).

5. **Commit 5** — `chore(monitoring): remove Prometheus CR — Mimir is sole metrics store`
   Touches: delete `monitoring/prometheus-instance/`, delete `monitoring/grafana/grafana_datasource.yaml`, `monitoring/setup.sh` (drop Prom apply blocks), `monitoring/teardown.sh` (idempotent cleanup), `monitoring/README.md`.
   Validation: G.4 + G.5 (Prom pod gone, dashboards still render — alias DS carries the load).

---

## Out of Scope

- HTTPS for Alloy → Mimir push and Alloy → Ruler sync (uses Vault PKI / Traefik TLS wildcard later)
- Per-tenant Grafana org_mapping (Dex group → Mimir tenant) — single tenant per region today
- Cross-region rollup dashboards (single panel showing eu+us+local) — would require third DS at `__all__`
- Alertmanager routing (no alerting destinations defined; Mimir Alertmanager is enabled but receivers default to noop)
- Migrating away from `kube-prometheus-stack` chart entirely — operator still useful for ServiceMonitor CRDs
- Reintroducing a Prometheus UI shim (e.g. `vmui` or `grafana-explore-as-default`) — Mimir nginx exposes the Prometheus query API; that's enough for debug
- Mimir multi-tenant federation queries — `source_tenants` annotation supported but no current use case
- Per-namespace selector tightening on `prometheus.operator.servicemonitors` — playground keeps cluster-wide
