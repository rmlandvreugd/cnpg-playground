# Plan — Namespace Scope Tightening + Alertmanager Routing

## Context

Follow-up to `docs/monitoring-prom-removal-plan.md`. Closes two "Out of Scope" items:

1. **Per-namespace selector tightening** on Alloy `prometheus.operator.servicemonitors` — currently scrapes cluster-wide; restrict via label-based allowlist
2. **Alertmanager routing** — wire Mimir Ruler `alertmanager_url` to bundled Mimir AM AND set up Grafana Alerting via Grafana-operator CRs for both `grafana` + `grafana-rbr-ver` instances

Pairs with `docs/monitoring-signals-plan.md` (fleet dashboards + federation).

### Locked decisions (interactive)

| # | Question | Choice |
|---|---|---|
| 1 | Namespace scope | **Apply now — label-based allowlist** (`monitoring/scrape=enabled`) |
| 2 | Alertmanager split | **Mimir Ruler for recording rules; Grafana Alerting for alerting rules** |
| 3 | Mimir AM | **Keep enabled + wire `alertmanager_url`** (both-path setup) |
| 4 | Grafana Alerting scope | **Both Grafana instances, separate contact points** |
| 5 | Contact point | **Null/log default + Slack webhook scaffold via env** |

### Current state (verified)

- `monitoring/mimir/mimir-values.yaml` — `alertmanager: { replicas: 1, persistentVolume: { size: 1Gi } }` enabled; ruler enabled; no `alertmanager_url` set yet
- Alloy `prometheus.operator.{servicemonitors,podmonitors,probes}` planned for prom-removal but no namespace selector
- Repo namespaces in use: `cnpg-system`, `grafana`, `mimir`, `otel`, `tempo`, `prometheus-operator`, `loki` (?), `default`, `demo-local-db` (`CNPG_DEMO_NAMESPACE`), `rbr-ver-db`, `vault`, `dex`, `cert-manager`, `traefik`, `external-secrets`
- No existing `GrafanaContactPoint`/`GrafanaNotificationPolicy`/`GrafanaAlertRuleGroup` CRs in repo
- Grafana CRs: `grafana` (main, `monitoring/grafana/grafana_instance.yaml`) and `grafana-rbr-ver` (self-service, `demo/yaml/self-service/grafana/`)
- Alloy `prometheus.operator.servicemonitors` docs confirm: `namespaces = [...]` accepts static name list; **no native label-based namespace selector** (Alloy issue #209 open)

---

## Part A — Namespace allowlist via label

### A.1 Label scheme

| Namespace | Label `monitoring/scrape` | Why |
|---|---|---|
| `cnpg-system` | `enabled` | CNPG operator metrics |
| `grafana` | `enabled` | Loki, Alloy itself, Grafana, Tempo (if not own ns) |
| `mimir` | `enabled` | Mimir components |
| `otel` | `enabled` | OTel Collector |
| `tempo` | `enabled` | Tempo distributed |
| `prometheus-operator` | `enabled` | kube-state-metrics, node-exporter, prom-operator |
| `traefik` | `enabled` | Traefik metrics + access |
| `external-secrets` | `enabled` | ESO operator metrics |
| `vault` | `enabled` | Vault stats (if exporter present) |
| `dex` | `enabled` | Dex stats |
| `cert-manager` | `enabled` | cert-manager controller metrics |
| `kube-system` | `enabled` | coreDns, kube-proxy, kubelet target Service lives here |
| `default` | `enabled` | `verstappen` CNPG cluster (rbr-ver-db) sits in `default`? Verify; if in `rbr-ver-db`, skip default |
| `demo-local-db` (`CNPG_DEMO_NAMESPACE`) | `enabled` | demo CNPG clusters |
| `rbr-ver-db` | `enabled` | self-service CNPG cluster |
| Any unlabeled namespace | absent | NOT scraped |

> Adding a new ServiceMonitor in an unlabeled namespace is silently ignored. Document in `monitoring/README.md`.

### A.2 Setup script labels infrastructure namespaces

#### A.2.1 New helper — `scripts/funcs_namespace_scrape_label.sh`

```bash
# Label a namespace for scrape inclusion. Idempotent.
label_namespace_for_scrape() {
    local context="$1"
    local namespace="$2"
    kubectl --context "${context}" label namespace "${namespace}" \
        monitoring/scrape=enabled --overwrite
}

# Get pipe-separated list of labeled namespaces for envsubst.
get_scrape_namespaces() {
    local context="$1"
    kubectl --context "${context}" get namespaces \
        -l monitoring/scrape=enabled \
        -o jsonpath='{range .items[*]}{.metadata.name}{","}{end}' | sed 's/,$//'
}
```

Source from `scripts/common.sh`.

#### A.2.2 Patch — `monitoring/setup.sh`

After creating each namespace via `kubectl create namespace ... | kubectl apply -f -`, immediately label:

```bash
kubectl --context "${CONTEXT_NAME}" create namespace mimir --dry-run=client -o yaml \
    | kubectl --context "${CONTEXT_NAME}" apply -f -
label_namespace_for_scrape "${CONTEXT_NAME}" mimir
```

Repeat for `otel`, `tempo`, `grafana`, `prometheus-operator`, `cnpg-system`.

#### A.2.3 Patch — `scripts/setup.sh`

Label the infrastructure namespaces created in the bootstrap phase: `traefik`, `cert-manager`, `external-secrets`, `vault`, `dex`, `kube-system`.

#### A.2.4 Patch — `demo/setup.sh`

After creating `${CNPG_DEMO_NAMESPACE}` (`demo-local-db`), label it.

#### A.2.5 Patch — `demo/self-service-setup.sh`

Label `rbr-ver-db` (self-service tenant DB namespace) after creation.

### A.3 Alloy config consumes the namespace list

#### A.3.1 Render namespace list at install time

In `monitoring/setup.sh` Alloy block (after rendering MIMIR_PUSH_URL etc.):

```bash
SCRAPE_NAMESPACES_CSV="$(get_scrape_namespaces "${CONTEXT_NAME}")"
# Convert CSV to River list syntax: ["a","b","c"]
SCRAPE_NAMESPACES_RIVER="$(echo "${SCRAPE_NAMESPACES_CSV}" | awk -F, '{
    out="["
    for (i=1;i<=NF;i++) {
        out=out "\"" $i "\""
        if (i<NF) out=out ","
    }
    out=out "]"
    print out
}')"
# yields: ["cnpg-system","default","demo-local-db","grafana","kube-system","mimir","otel","tempo","traefik","prometheus-operator","cert-manager","external-secrets","vault","dex","rbr-ver-db"]
```

#### A.3.2 Patch — `monitoring/alloy/alloy-config.river.tpl`

Replace cluster-wide `prometheus.operator.*` blocks (from prom-removal-plan Part A.1) with namespace-scoped variants:

```hcl
prometheus.operator.servicemonitors "scrape" {
  forward_to = [prometheus.remote_write.mimir.receiver]
  namespaces = ${SCRAPE_NAMESPACES_RIVER}
}

prometheus.operator.podmonitors "scrape" {
  forward_to = [prometheus.remote_write.mimir.receiver]
  namespaces = ${SCRAPE_NAMESPACES_RIVER}
}

prometheus.operator.probes "scrape" {
  forward_to = [prometheus.remote_write.mimir.receiver]
  namespaces = ${SCRAPE_NAMESPACES_RIVER}
}

mimir.rules.kubernetes "rules" {
  address    = "${MIMIR_RULER_URL}"
  tenant_id  = "${REGION}"
  rule_namespaces = ${SCRAPE_NAMESPACES_RIVER}
}
```

Add `${SCRAPE_NAMESPACES_RIVER}` to the `envsubst` allowlist.

### A.4 New-namespace workflow

`monitoring/README.md` section:

```markdown
### Adding a new namespace to scrape

1. Label it: `kubectl label namespace <name> monitoring/scrape=enabled`
2. Re-run `monitoring/setup.sh` to regenerate Alloy config with the new namespace
   in the static list, OR `helm upgrade alloy` manually.

Why a re-run is required: Alloy's `prometheus.operator.servicemonitors` accepts a
static namespace list at config time. There is no native label-based namespace
selector (Alloy issue #209).

ServiceMonitor / PodMonitor / Probe CRs in unlabeled namespaces are silently
ignored. PrometheusRule CRs follow the same scope.
```

### A.5 Watchpoint — label drift

A namespace can be created post-bootstrap (e.g. user `kubectl create namespace foo`). Setup script won't auto-relabel. Document the manual label step.

Optional improvement: a small `Job` that watches namespace creations and labels by convention. Out of scope.

---

## Part B — Mimir Ruler → Mimir Alertmanager wiring

### B.1 Patch — `monitoring/mimir/mimir-values.yaml`

Configure Ruler to push alerts to bundled Alertmanager:

```yaml
mimir:
  structuredConfig:
    # ... existing common/blocks_storage etc. ...
    ruler:
      alertmanager_url: http://mimir-alertmanager.mimir.svc.cluster.local:8080/alertmanager
      poll_interval: 1m
      evaluation_interval: 1m
    alertmanager:
      external_url: http://mimir-alertmanager.mimir.svc.cluster.local:8080/alertmanager
```

Mimir Ruler's `alertmanager_url` uses the in-cluster nginx-fronted Alertmanager. Single-region: works directly. Multi-region: same URL (all regions push rules to hub Mimir which has the AM).

### B.2 New file — `monitoring/mimir/alertmanager-config.yaml`

Default Alertmanager config (null receiver). Mounted via `--set-file` similar to runtime-config (per signals-plan B.3).

```yaml
template_files: {}

alertmanager_config: |
  global:
    resolve_timeout: 5m

  route:
    receiver: 'null-default'
    group_by: ['alertname', 'region', 'tenant']
    group_wait: 30s
    group_interval: 5m
    repeat_interval: 4h
    routes:
      - matchers:
          - severity = critical
        receiver: 'slack-critical'
      - matchers:
          - severity = warning
        receiver: 'slack-warnings'

  receivers:
    - name: 'null-default'
      # No webhook — alerts logged to Mimir AM stderr.

    - name: 'slack-critical'
      slack_configs:
        - api_url: 'SLACK_WEBHOOK_PLACEHOLDER'   # replaced at install time via envsubst
          channel: '#alerts-critical'
          send_resolved: true

    - name: 'slack-warnings'
      slack_configs:
        - api_url: 'SLACK_WEBHOOK_PLACEHOLDER'
          channel: '#alerts-warnings'
          send_resolved: true
```

> Mimir AM is multi-tenant. The single-config file above is the **default** config used by every tenant that has no per-tenant config uploaded via `mimirtool alertmanager load`. Per-tenant config uploads supported via Alertmanager API; out of scope for default playground setup.

### B.3 Patch — `monitoring/setup.sh` (hub Mimir install)

Upload the default Alertmanager config per tenant after Mimir install:

```bash
if [[ "${region}" == "${HUB_REGION}" ]]; then
    # ... existing mimir install ...

    # Upload default AM config to each tenant
    AM_CONFIG_TMP="$(mktemp)"
    SLACK_WEBHOOK_URL="${SLACK_WEBHOOK_URL:-https://hooks.slack.com/services/INVALID/INVALID/INVALID}" \
        envsubst '${SLACK_WEBHOOK_URL}' \
        < "${GIT_REPO_ROOT}/monitoring/mimir/alertmanager-config.yaml" \
        | sed "s|SLACK_WEBHOOK_PLACEHOLDER|${SLACK_WEBHOOK_URL}|g" \
        > "${AM_CONFIG_TMP}"

    for tenant in "${REGIONS[@]}"; do
        kubectl --context "${CONTEXT_NAME}" -n mimir run am-config-${tenant} \
            --rm -i --restart=Never \
            --image=grafana/mimirtool:latest \
            --command -- mimirtool alertmanager load /tmp/am.yaml \
                --address http://mimir-nginx.mimir.svc.cluster.local \
                --id ${tenant} < "${AM_CONFIG_TMP}"
    done
    rm -f "${AM_CONFIG_TMP}"
fi
```

> Alternative: pre-create a ConfigMap with the AM config and let Mimir AM read it via `-alertmanager.configs.fallback` flag. Simpler. Document trade-off.

### B.4 New file — `monitoring/mimir/ingressroute-am.yaml.tpl` (multi-region only)

For multi-region setups, expose AM UI on hub for debugging:

```yaml
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: mimir-am
  namespace: mimir
spec:
  entryPoints: [web]
  routes:
    - match: Host(`mimir-am.${TRAEFIK_IP_DASHED}.sslip.io`)
      kind: Rule
      services:
        - name: mimir-alertmanager
          port: 8080
```

Apply on hub only when `${#REGIONS[@]} -gt 1`.

---

## Part C — Grafana Alerting via Grafana-operator CRs

### C.1 New file — `monitoring/grafana/grafana_contact_point_null.yaml`

Default contact point: `null`-like receiver that just logs.

```yaml
apiVersion: grafana.integreatly.org/v1beta1
kind: GrafanaContactPoint
metadata:
  name: contact-null-log
  namespace: grafana
spec:
  instanceSelector:
    matchLabels:
      dashboards: grafana
  name: null-log
  type: webhook
  settings:
    url: http://example.invalid/null
    httpMethod: POST
  disableResolveMessage: true
```

> Grafana operator's `GrafanaContactPoint` supports types: `email`, `slack`, `webhook`, `pagerduty`, etc. For null/log behavior, point a `webhook` type at a non-routable URL and accept the bounced delivery in the Grafana logs. Cleaner: use `type: webhook` + httpd-style internal route, but for playground the `example.invalid` placeholder is fine.

### C.2 New file — `monitoring/grafana/grafana_contact_point_slack.yaml.tpl`

Slack scaffold; webhook URL injected via env at install time.

```yaml
apiVersion: grafana.integreatly.org/v1beta1
kind: GrafanaContactPoint
metadata:
  name: contact-slack
  namespace: grafana
spec:
  instanceSelector:
    matchLabels:
      dashboards: grafana
  name: slack
  type: slack
  settings:
    url: ${SLACK_WEBHOOK_URL}
    title: '[{{ .Status }}] {{ .CommonLabels.alertname }}'
    text: |
      {{ range .Alerts -}}
      *Severity:* {{ .Labels.severity }}
      *Region:* {{ .Labels.region }}
      *Description:* {{ .Annotations.description }}
      {{ end -}}
```

`monitoring/setup.sh` only applies this CR when `${SLACK_WEBHOOK_URL}` is non-empty:

```bash
if [[ -n "${SLACK_WEBHOOK_URL:-}" ]]; then
    SLACK_WEBHOOK_URL="${SLACK_WEBHOOK_URL}" envsubst '${SLACK_WEBHOOK_URL}' \
        < "${GIT_REPO_ROOT}/monitoring/grafana/grafana_contact_point_slack.yaml.tpl" \
        | kubectl --context "${CONTEXT_NAME}" apply -f -
fi
```

Document `SLACK_WEBHOOK_URL` env var in `scripts/common.sh` with empty default + README explanation.

### C.3 New file — `monitoring/grafana/grafana_notification_policy.yaml`

Routes alerts: `severity=critical` → Slack (if configured), else → null-log.

```yaml
apiVersion: grafana.integreatly.org/v1beta1
kind: GrafanaNotificationPolicy
metadata:
  name: notification-policy
  namespace: grafana
spec:
  instanceSelector:
    matchLabels:
      dashboards: grafana
  route:
    receiver: null-log
    group_by: [alertname, region]
    group_wait: 30s
    group_interval: 5m
    repeat_interval: 4h
    routes:
      - matchers:
          - severity = critical
        receiver: slack
        continue: false
      - matchers:
          - severity = warning
        receiver: slack
        continue: false
```

> Grafana operator's `GrafanaNotificationPolicy` is a singleton per instance (root route only). Sub-routes go in the `routes` array. If `slack` contact point absent (Slack URL unset), Grafana falls back to default receiver — handle gracefully via `null-log` default.

### C.4 New file — `monitoring/grafana/grafana_alert_rule_group_smoke.yaml`

Sample alerting rule (smoke test). Fires when fewer than expected CNPG pods running.

```yaml
apiVersion: grafana.integreatly.org/v1beta1
kind: GrafanaAlertRuleGroup
metadata:
  name: alerts-cnpg
  namespace: grafana
spec:
  instanceSelector:
    matchLabels:
      dashboards: grafana
  folderRef: monitoring-alerts          # GrafanaFolder ref below
  interval: 1m
  rules:
    - title: CNPGClusterUnreachable
      uid: cnpg-cluster-unreachable
      condition: B
      data:
        - refId: A
          datasourceUid: mimir-fleet
          model:
            expr: 'absent(cnpg_pg_replication_lag) > 0'
            instant: true
        - refId: B
          datasourceUid: __expr__
          model:
            type: threshold
            conditions:
              - evaluator: {params: [0], type: gt}
                operator: {type: and}
                query: {params: [A]}
                reducer: {type: last}
      noDataState: NoData
      execErrState: Error
      for: 2m
      labels:
        severity: critical
        component: cnpg
      annotations:
        description: "No CNPG cluster reachable across any region for 2m"
```

### C.5 New file — `monitoring/grafana/grafana_folder_alerts.yaml`

```yaml
apiVersion: grafana.integreatly.org/v1beta1
kind: GrafanaFolder
metadata:
  name: monitoring-alerts
  namespace: grafana
spec:
  instanceSelector:
    matchLabels:
      dashboards: grafana
  title: Monitoring Alerts
```

### C.6 Patch — `monitoring/grafana/grafana_instance.yaml`

Enable alerting subsystem in main Grafana CR. Grafana operator v5 enables Unified Alerting by default but explicit config below disables legacy and tunes intervals:

```yaml
apiVersion: grafana.integreatly.org/v1beta1
kind: Grafana
metadata:
  name: grafana
  labels:
    dashboards: "grafana"
spec:
  config:
    log:
      mode: "console"
    security:
      admin_user: admin
      admin_password: admin
    live:
      max_connections: "0"
    unified_alerting:
      enabled: "true"
      min_interval: "10s"
    alerting:
      enabled: "false"        # disable legacy alerting (Grafana 11+ default)
  deployment:
    spec:
      template:
        spec:
          nodeSelector:
            node-role.kubernetes.io/infra: ""
```

### C.7 Patch — `monitoring/grafana/kustomization.yaml`

```yaml
resources:
  # ... existing ...
  - grafana_folder_alerts.yaml
  - grafana_contact_point_null.yaml
  # grafana_contact_point_slack.yaml.tpl  — applied by setup.sh conditionally
  - grafana_notification_policy.yaml
  - grafana_alert_rule_group_smoke.yaml
```

---

## Part D — rbr-ver Grafana Alerting

Mirror Part C for the `grafana-rbr-ver` instance. Separate contact points per locked decision.

### D.1 New files in `demo/yaml/self-service/grafana/`

- `grafanacontactpoint-null-rbr-ver.yaml`
- `grafanacontactpoint-slack-rbr-ver.yaml.tpl`
- `grafananotificationpolicy-rbr-ver.yaml`
- `grafanafolder-alerts-rbr-ver.yaml`
- `grafanaalertrulegroup-smoke-rbr-ver.yaml`

Same content as Part C with:
- `instanceSelector.matchLabels.dashboards: grafana-rbr-ver`
- `name` and rule `uid` suffixed `-rbr-ver`
- `folderRef: monitoring-alerts-rbr-ver`
- Slack channel can differ via separate env var `SLACK_WEBHOOK_URL_RBR_VER` (defaults to `${SLACK_WEBHOOK_URL}` if unset)

### D.2 Patch — `demo/self-service-setup.sh`

```bash
kubectl apply -f demo/yaml/self-service/grafana/grafanacontactpoint-null-rbr-ver.yaml
kubectl apply -f demo/yaml/self-service/grafana/grafananotificationpolicy-rbr-ver.yaml
kubectl apply -f demo/yaml/self-service/grafana/grafanafolder-alerts-rbr-ver.yaml
kubectl apply -f demo/yaml/self-service/grafana/grafanaalertrulegroup-smoke-rbr-ver.yaml

if [[ -n "${SLACK_WEBHOOK_URL_RBR_VER:-${SLACK_WEBHOOK_URL:-}}" ]]; then
    SLACK_WEBHOOK_URL="${SLACK_WEBHOOK_URL_RBR_VER:-${SLACK_WEBHOOK_URL}}" \
        envsubst '${SLACK_WEBHOOK_URL}' \
        < demo/yaml/self-service/grafana/grafanacontactpoint-slack-rbr-ver.yaml.tpl \
        | kubectl apply -f -
fi
```

---

## Verification

### V.1 Namespace allowlist enforced

```bash
# Create an unlabeled namespace with a ServiceMonitor
kubectl create namespace test-no-scrape
cat <<EOF | kubectl -n test-no-scrape apply -f -
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: dummy
spec:
  selector:
    matchLabels:
      app: nonexistent
  endpoints:
    - port: http
EOF

# Alloy must NOT pick it up
kubectl -n grafana port-forward svc/alloy 12345 &
sleep 2
curl -s http://localhost:12345/api/v0/web/components/prometheus.operator.servicemonitors.scrape \
    | jq '.targets[] | select(.namespace=="test-no-scrape")'
# expect: (empty)

# Label and reapply Alloy config
kubectl label namespace test-no-scrape monitoring/scrape=enabled
./monitoring/setup.sh    # re-render alloy config with new namespace list

# Now Alloy should pick up
curl -s http://localhost:12345/api/v0/web/components/prometheus.operator.servicemonitors.scrape \
    | jq '.targets[] | select(.namespace=="test-no-scrape")' \
    | head -1
# expect: object found

kubectl delete namespace test-no-scrape
```

### V.2 Mimir Ruler → Mimir AM wired

```bash
# Apply a sample alerting rule via PrometheusRule (Mimir Ruler path, NOT Grafana Alerting)
cat <<'EOF' | kubectl -n default apply -f -
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: smoke-alert-mimir
spec:
  groups:
    - name: smoke
      rules:
        - alert: AlwaysFiring
          expr: vector(1)
          for: 30s
          labels: { severity: warning }
          annotations: { summary: "smoke alert from Mimir Ruler" }
EOF

# Sync into Mimir
sleep 90

# Verify rule loaded in Mimir Ruler
curl -s -H 'X-Scope-OrgID: local' \
    'http://localhost:8080/prometheus/api/v1/rules' | jq '.data.groups[] | select(.name=="smoke")'
# expect: rule visible

# Verify alert reached Mimir AM
kubectl -n mimir port-forward svc/mimir-alertmanager 9093:8080 &
sleep 2
curl -s 'http://localhost:9093/alertmanager/api/v2/alerts' | jq '.[] | select(.labels.alertname=="AlwaysFiring")'
# expect: alert in firing state

kubectl -n default delete prometheusrule smoke-alert-mimir
```

### V.3 Grafana Alerting evaluates + routes

```bash
# Open Grafana UI → Alerts & IRM → Alert rules → confirm CNPGClusterUnreachable listed
# Manually break: kubectl scale ... CNPG primary to 0 → wait 2m → expect alert state=Alerting
# Check Grafana → Alerts → Logs (or operator logs) for routing decision: should go to null-log receiver

# If SLACK_WEBHOOK_URL set:
SLACK_WEBHOOK_URL=https://hooks.slack.com/real ./monitoring/setup.sh
# Re-trigger alert → check Slack channel
```

### V.4 rbr-ver Grafana Alerting

- Open `grafana-rbr-ver` UI
- Alerts & IRM → see rule `cnpg-cluster-unreachable-rbr-ver`
- Contact points list: `null-log-rbr-ver` + optional `slack-rbr-ver`

### V.5 Namespace label idempotency

```bash
./monitoring/setup.sh    # full run
./monitoring/setup.sh    # second run — labels should not flap or error
kubectl get ns -l monitoring/scrape=enabled --show-labels
# expect: all infra + demo + rbr-ver-db namespaces listed once each
```

---

## File-level Changeset Summary

### Modify

- `monitoring/alloy/alloy-config.river.tpl` — `namespaces = ${SCRAPE_NAMESPACES_RIVER}` on all `prometheus.operator.*` + `mimir.rules.kubernetes`
- `monitoring/setup.sh` — label namespaces, derive `SCRAPE_NAMESPACES_RIVER`, apply AM config + Slack contact point conditionally, query IngressRoute apply
- `scripts/setup.sh` — label infra namespaces post-creation
- `scripts/common.sh` — `SLACK_WEBHOOK_URL`, `SLACK_WEBHOOK_URL_RBR_VER` env vars with empty defaults
- `monitoring/mimir/mimir-values.yaml` — ruler `alertmanager_url`, alertmanager `external_url`
- `monitoring/grafana/grafana_instance.yaml` — `unified_alerting.enabled`, disable legacy alerting
- `monitoring/grafana/kustomization.yaml` — add 5 new alerting CRs
- `demo/setup.sh` — label `${CNPG_DEMO_NAMESPACE}`
- `demo/self-service-setup.sh` — label `rbr-ver-db`; apply 5 rbr-ver alerting CRs
- `monitoring/README.md` — namespace allowlist docs; alerting topology
- `monitoring/teardown.sh` — remove labels for clean teardown

### Create

- `scripts/funcs_namespace_scrape_label.sh`
- `monitoring/mimir/alertmanager-config.yaml`
- `monitoring/mimir/ingressroute-am.yaml.tpl` (multi-region)
- `monitoring/grafana/grafana_folder_alerts.yaml`
- `monitoring/grafana/grafana_contact_point_null.yaml`
- `monitoring/grafana/grafana_contact_point_slack.yaml.tpl`
- `monitoring/grafana/grafana_notification_policy.yaml`
- `monitoring/grafana/grafana_alert_rule_group_smoke.yaml`
- `demo/yaml/self-service/grafana/grafanafolder-alerts-rbr-ver.yaml`
- `demo/yaml/self-service/grafana/grafanacontactpoint-null-rbr-ver.yaml`
- `demo/yaml/self-service/grafana/grafanacontactpoint-slack-rbr-ver.yaml.tpl`
- `demo/yaml/self-service/grafana/grafananotificationpolicy-rbr-ver.yaml`
- `demo/yaml/self-service/grafana/grafanaalertrulegroup-smoke-rbr-ver.yaml`

---

## Risks / Watchpoints

| Risk | Mitigation |
|---|---|
| Alloy `prometheus.operator.servicemonitors` `namespaces = []` requires re-render on namespace add/remove | Documented in `monitoring/README.md`. Add namespace → label → re-run `monitoring/setup.sh`. |
| User-created namespace gets ServiceMonitors silently ignored | Default-deny security posture. Document explicitly so users opt-in via label. |
| `monitoring/scrape=enabled` label collides with another tool's label namespace | Use prefix-style label key (`monitoring/scrape` not `scrape`) — unlikely collision. |
| Slack webhook URL leakage if committed | Templates only — actual URL injected via env at install. Document `.env`-style override pattern. |
| Mimir AM default config receivers reference Slack even when no webhook configured | `null-default` is the root receiver; slack receivers are sub-routes with `matchers`. If webhook URL is placeholder, alerts firing with matched severity will fail-soft (Mimir AM logs delivery failure but doesn't crash). |
| Grafana operator `GrafanaAlertRuleGroup` schema doesn't render Prometheus expression directly — uses Grafana's expression model | The `data[0].model.expr` field holds PromQL. Operator translates. Validated via Grafana docs. |
| Mimir Ruler `alertmanager_url` requires multi-tenant header pass-through | Mimir Ruler injects `X-Scope-OrgID` per-rule-group tenant — handled internally. No nginx changes needed. |
| Non-hub regions can't reach Mimir AM directly (it's hub-only) | Mimir Ruler runs only on hub. Non-hub regions' rules are pushed to hub Ruler via Alloy `mimir.rules.kubernetes` → hub Ruler evaluates → hub AM dispatches. Loop closes within hub. |
| Grafana Alerting evaluates rules in Grafana process — not in Mimir | Recording rules stay in Mimir Ruler (efficient). Alerting rules in Grafana evaluate against Mimir DS — adds query load on Mimir querier. Acceptable for playground. |
| Slack webhook URL changes per deployment | Re-run `monitoring/setup.sh` with new env var; idempotent. |
| Grafana null-log receiver actually does POST to `example.invalid` causing log spam | Set `disableResolveMessage: true` (Part C.1) — reduces volume. Alternative: a small `nc -l` sidecar that swallows webhook POSTs. |
| `unified_alerting.enabled: "true"` config-key path may differ in newer Grafana | Spec uses Grafana `grafana.ini` flat-key style (`unified_alerting.enabled`). Verify against Grafana 11.x docs. |
| `GrafanaContactPoint` of type `webhook` requires reachable URL — `example.invalid` is non-routable | Acceptable for playground null/log behavior. Production: replace with real receiver. |
| Mimir AM single-binary chart deploys with persistent volume — survives restarts | Already set: `alertmanager.persistentVolume.size: 1Gi`. Sufficient for AM state (silences, notifications). |
| Mimir AM HTTP path is `/alertmanager/...` (not root) | `external_url` set to `.../alertmanager` (B.1). Mimir AM expects routed path prefix. |

---

## Suggested Commit Sequence

1. **Commit 1** — `feat(monitoring): label namespaces for scrape allowlist`
   Touches: `scripts/funcs_namespace_scrape_label.sh` (new), `monitoring/setup.sh`, `scripts/setup.sh`, `demo/setup.sh`, `demo/self-service-setup.sh`, `monitoring/README.md`, `monitoring/teardown.sh`.
   Validation: `kubectl get ns -l monitoring/scrape=enabled` lists expected namespaces.

2. **Commit 2** — `feat(alloy): scope ServiceMonitor/PodMonitor scrape to labeled namespaces`
   Touches: `monitoring/alloy/alloy-config.river.tpl`, `monitoring/setup.sh` (namespace-list render).
   Validation: V.1.

3. **Commit 3** — `feat(mimir): wire Ruler→Alertmanager with default null receiver`
   Touches: `monitoring/mimir/mimir-values.yaml`, `monitoring/mimir/alertmanager-config.yaml` (new), `monitoring/mimir/ingressroute-am.yaml.tpl` (new), `monitoring/setup.sh`.
   Validation: V.2.

4. **Commit 4** — `feat(grafana): Unified Alerting + null contact point + sample rule (main)`
   Touches: `monitoring/grafana/grafana_instance.yaml`, 5 new alerting CRs, `monitoring/grafana/kustomization.yaml`, `scripts/common.sh` (SLACK_WEBHOOK_URL env), `monitoring/setup.sh` (conditional slack apply).
   Validation: V.3.

5. **Commit 5** — `feat(self-service): mirror Grafana Alerting to grafana-rbr-ver`
   Touches: 5 new rbr-ver alerting CRs, `demo/self-service-setup.sh`.
   Validation: V.4.

---

## Out of Scope

- Per-tenant Mimir AM configs (only default config uploaded; tenants share until customized via API)
- HTTPS for Mimir AM IngressRoute — uses Vault PKI when wildcard certs land
- PagerDuty/Opsgenie/email contact points — Slack scaffold only
- Inhibition rules in Mimir AM (suppress flapping)
- Grafana Mute Timings — `GrafanaMuteTiming` CR supported but no schedule defined
- Multi-tenant Grafana org_mapping → AM routing isolation
- Alloy namespace label-based selector once Alloy issue #209 lands — revisit then
- Smoke alert rules beyond `CNPGClusterUnreachable` — add more during execution
- Automatic relabeling Job for namespaces created post-bootstrap
- Mimir AM HA replication (single replica is acceptable for playground)
