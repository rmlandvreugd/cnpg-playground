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
| 6 | CNPG alert library | **Import upstream `cnpg-default-alerts` + 3 gaps** (primary-down, backup-failure, missing-standby) — Part E |
| 7 | Inhibition + mute timings | **Mimir AM `inhibit_rules` + `GrafanaMuteTiming` CR** — playground default mute: nightly 02:00–04:00 UTC maintenance window (suppressible per env) — Part F |
| 8 | Severity taxonomy | **Three tiers**: `critical` (page/Slack #alerts-critical), `warning` (Slack #alerts-warnings), `info` (log only) — Part G.1 |
| 9 | Mimir AM HA | **3 replicas + memberlist gossip + S3-backed state fallback** (still single-namespace, single-region) — Part G.2 |
| 10 | Post-bootstrap namespace label automation | **Lightweight watcher Job** with `kubectl get ns --watch` + label-by-convention via a ConfigMap-driven allowlist — Part G.3 |

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

Replace cluster-wide `prometheus.operator.*` blocks (from prom-removal-plan Part A.1) with namespace-scoped variants. `prometheus.operator.*` uses a static `namespaces` list (rendered at install time via SCRAPE_NAMESPACES_RIVER). `mimir.rules.kubernetes` uses a dynamic `rule_namespace_selector` with label match — no `rule_namespaces` argument exists in Alloy.

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

  rule_namespace_selector {
    match_labels = {
      "monitoring/scrape" = "enabled",
    }
  }
}
```

Add `${SCRAPE_NAMESPACES_RIVER}` to the `envsubst` allowlist (for `prometheus.operator.*`). `mimir.rules.kubernetes` uses the label selector and requires no envsubst variable — the `rule_namespace_selector` is evaluated live by Alloy against the Kubernetes API.

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

### B.2 New file — `monitoring/mimir/alertmanager-config.yaml.tpl`

Default Alertmanager config template (null receiver + optional Slack). Rendered at install time via envsubst and injected via `--set-file alertmanager.fallbackConfig`. The mimir-distributed chart's `alertmanager.fallbackConfig` field accepts this as a string — it creates a ConfigMap and passes `-alertmanager.configs.fallback` to the Alertmanager component automatically.

```yaml
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

  - name: 'slack-critical'
    slack_configs:
      - api_url: '${SLACK_WEBHOOK_URL}'
        channel: '#alerts-critical'
        send_resolved: true

  - name: 'slack-warnings'
    slack_configs:
      - api_url: '${SLACK_WEBHOOK_URL}'
        channel: '#alerts-warnings'
        send_resolved: true
```

> Mimir AM is multi-tenant. This is the **fallback** config used by every tenant that has no per-tenant config uploaded via the Alertmanager API. When `SLACK_WEBHOOK_URL` is empty, Slack routes fire but fail-soft (delivery failure logged, Mimir AM does not crash). Per-tenant configs are out of scope.

### B.3 Patch — `monitoring/setup.sh` (hub Mimir helm install)

Replace the helm install command for Mimir (hub only) to inject the rendered AM fallback config via `--set-file`:

```bash
if [[ "${region}" == "${HUB_REGION}" ]]; then
    AM_CONFIG_TMP="$(mktemp)"
    SLACK_WEBHOOK_URL="${SLACK_WEBHOOK_URL:-https://hooks.slack.com/services/INVALID/INVALID/INVALID}" \
        envsubst '${SLACK_WEBHOOK_URL}' \
        < "${GIT_REPO_ROOT}/monitoring/mimir/alertmanager-config.yaml.tpl" \
        > "${AM_CONFIG_TMP}"

    helm upgrade --install mimir grafana/mimir-distributed \
        --namespace mimir --create-namespace \
        --version "${MIMIR_CHART_VERSION}" \
        -f "${GIT_REPO_ROOT}/monitoring/mimir/mimir-values.yaml" \
        --set-file "alertmanager.fallbackConfig=${AM_CONFIG_TMP}"

    rm -f "${AM_CONFIG_TMP}"
fi
```

> `--set-file` injects the rendered file contents as the chart value string. The mimir-distributed chart passes this via `-alertmanager.configs.fallback` — no `mimirtool`, no `kubectl run`, no per-tenant upload needed for the default config.

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

### C.3 Two files — notification policy (templated)

`GrafanaNotificationPolicy` is a singleton per Grafana instance. Routes referencing a missing contact point (`slack`) cause Grafana operator errors. Use two separate files with the same `metadata.name` — setup.sh applies the appropriate one idempotently.

#### `monitoring/grafana/grafana_notification_policy.yaml` — null-only (base)

Applied by setup.sh always. Applied by kustomization.yaml when setup.sh has not yet run.

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
```

#### `monitoring/grafana/grafana_notification_policy_slack.yaml.tpl` — with Slack routes

Applied by setup.sh over the null-only (same `metadata.name`, idempotent replace) only when `SLACK_WEBHOOK_URL` is non-empty.

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

In `monitoring/setup.sh`, after applying the null contact point:

```bash
# Always apply base null-only policy
kubectl --context "${CONTEXT_NAME}" apply -f \
    "${GIT_REPO_ROOT}/monitoring/grafana/grafana_notification_policy.yaml"

# Override with Slack routes only when webhook URL is set
if [[ -n "${SLACK_WEBHOOK_URL:-}" ]]; then
    kubectl --context "${CONTEXT_NAME}" apply -f \
        "${GIT_REPO_ROOT}/monitoring/grafana/grafana_notification_policy_slack.yaml.tpl"
fi
```

> The `.tpl` suffix on the Slack variant is intentional but the file contains no envsubst variables — the webhook URL lives in the contact point CR, not the policy. Re-running setup.sh without `SLACK_WEBHOOK_URL` rolls back to null-only (same name, `kubectl apply` replaces).

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
  # grafana_contact_point_slack.yaml.tpl       — applied by setup.sh when SLACK_WEBHOOK_URL set
  - grafana_notification_policy.yaml            # null-only base; setup.sh may override with _slack variant
  # grafana_notification_policy_slack.yaml.tpl — applied by setup.sh when SLACK_WEBHOOK_URL set
  - grafana_alert_rule_group_smoke.yaml
```

---

## Part D — rbr-ver Grafana Alerting

Mirror Part C for the `grafana-rbr-ver` instance. Separate contact points per locked decision.

### D.1 New files in `demo/yaml/self-service/grafana/`

#### `demo/yaml/self-service/grafana/grafanafolder-alerts-rbr-ver.yaml`

```yaml
apiVersion: grafana.integreatly.org/v1beta1
kind: GrafanaFolder
metadata:
  name: monitoring-alerts-rbr-ver
  namespace: grafana
spec:
  instanceSelector:
    matchLabels:
      dashboards: grafana-rbr-ver
  title: Monitoring Alerts
```

#### `demo/yaml/self-service/grafana/grafanacontactpoint-null-rbr-ver.yaml`

```yaml
apiVersion: grafana.integreatly.org/v1beta1
kind: GrafanaContactPoint
metadata:
  name: contact-null-log-rbr-ver
  namespace: grafana
spec:
  instanceSelector:
    matchLabels:
      dashboards: grafana-rbr-ver
  name: null-log-rbr-ver
  type: webhook
  settings:
    url: http://example.invalid/null
    httpMethod: POST
  disableResolveMessage: true
```

#### `demo/yaml/self-service/grafana/grafanacontactpoint-slack-rbr-ver.yaml.tpl`

Applied by `demo/self-service-setup.sh` when `SLACK_WEBHOOK_URL_RBR_VER` or `SLACK_WEBHOOK_URL` is set.

```yaml
apiVersion: grafana.integreatly.org/v1beta1
kind: GrafanaContactPoint
metadata:
  name: contact-slack-rbr-ver
  namespace: grafana
spec:
  instanceSelector:
    matchLabels:
      dashboards: grafana-rbr-ver
  name: slack-rbr-ver
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

#### `demo/yaml/self-service/grafana/grafananotificationpolicy-rbr-ver.yaml`

Null-only base policy (same two-file pattern as Part C.3):

```yaml
apiVersion: grafana.integreatly.org/v1beta1
kind: GrafanaNotificationPolicy
metadata:
  name: notification-policy-rbr-ver
  namespace: grafana
spec:
  instanceSelector:
    matchLabels:
      dashboards: grafana-rbr-ver
  route:
    receiver: null-log-rbr-ver
    group_by: [alertname, region]
    group_wait: 30s
    group_interval: 5m
    repeat_interval: 4h
```

#### `demo/yaml/self-service/grafana/grafananotificationpolicy-rbr-ver-slack.yaml.tpl`

Override with Slack routes when webhook URL set (applied by `demo/self-service-setup.sh`):

```yaml
apiVersion: grafana.integreatly.org/v1beta1
kind: GrafanaNotificationPolicy
metadata:
  name: notification-policy-rbr-ver
  namespace: grafana
spec:
  instanceSelector:
    matchLabels:
      dashboards: grafana-rbr-ver
  route:
    receiver: null-log-rbr-ver
    group_by: [alertname, region]
    group_wait: 30s
    group_interval: 5m
    repeat_interval: 4h
    routes:
      - matchers:
          - severity = critical
        receiver: slack-rbr-ver
        continue: false
      - matchers:
          - severity = warning
        receiver: slack-rbr-ver
        continue: false
```

#### `demo/yaml/self-service/grafana/grafanaalertrulegroup-smoke-rbr-ver.yaml`

```yaml
apiVersion: grafana.integreatly.org/v1beta1
kind: GrafanaAlertRuleGroup
metadata:
  name: alerts-cnpg-rbr-ver
  namespace: grafana
spec:
  instanceSelector:
    matchLabels:
      dashboards: grafana-rbr-ver
  folderRef: monitoring-alerts-rbr-ver
  interval: 1m
  rules:
    - title: CNPGClusterUnreachable
      uid: cnpg-cluster-unreachable-rbr-ver
      condition: B
      data:
        - refId: A
          datasourceUid: mimir-fleet-rbr-ver
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

### D.2 Patch — `demo/self-service-setup.sh`

```bash
kubectl --context "${LOCAL_CONTEXT}" apply -f \
    demo/yaml/self-service/grafana/grafanafolder-alerts-rbr-ver.yaml
kubectl --context "${LOCAL_CONTEXT}" apply -f \
    demo/yaml/self-service/grafana/grafanacontactpoint-null-rbr-ver.yaml
kubectl --context "${LOCAL_CONTEXT}" apply -f \
    demo/yaml/self-service/grafana/grafanaalertrulegroup-smoke-rbr-ver.yaml

# Base null-only notification policy
kubectl --context "${LOCAL_CONTEXT}" apply -f \
    demo/yaml/self-service/grafana/grafananotificationpolicy-rbr-ver.yaml

# Override with Slack routes + contact point when webhook URL set
RBR_SLACK="${SLACK_WEBHOOK_URL_RBR_VER:-${SLACK_WEBHOOK_URL:-}}"
if [[ -n "${RBR_SLACK}" ]]; then
    SLACK_WEBHOOK_URL="${RBR_SLACK}" envsubst '${SLACK_WEBHOOK_URL}' \
        < demo/yaml/self-service/grafana/grafanacontactpoint-slack-rbr-ver.yaml.tpl \
        | kubectl --context "${LOCAL_CONTEXT}" apply -f -
    kubectl --context "${LOCAL_CONTEXT}" apply -f \
        demo/yaml/self-service/grafana/grafananotificationpolicy-rbr-ver-slack.yaml.tpl
fi
```

---

## Part E — CNPG alert library (Mimir Ruler path)

Imports the upstream `cloudnative-pg/cloudnative-pg` `cnpg-default-alerts` PrometheusRule (7 alerts) plus 3 gap-fillers (primary-down, backup-failure, missing-standby). Lives in the `cnpg-system` namespace (already labeled `monitoring/scrape=enabled` per Part A) so Alloy `mimir.rules.kubernetes` picks it up automatically.

### E.1 New file — `monitoring/cnpg/cnpg-default-alerts.yaml`

Verbatim upstream library + light annotation enrichment (runbook URLs, severity normalization).

```yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: cnpg-default-alerts
  namespace: cnpg-system
  labels:
    cnpg.io/managed: "true"
spec:
  groups:
    - name: cnpg.default
      interval: 30s
      rules:
        - alert: CNPGLongRunningTransaction
          expr: cnpg_backends_max_tx_duration_seconds > 300
          for: 1m
          labels:
            severity: warning
            component: cnpg
          annotations:
            summary: Long-running PostgreSQL transaction
            description: 'Pod {{ $labels.pod }} (region {{ $labels.region }}) has a transaction running >5m.'
            runbook_url: https://www.postgresql.org/docs/current/sql-explain.html

        - alert: CNPGBackendsWaiting
          expr: cnpg_backends_waiting_total > 300
          for: 1m
          labels:
            severity: warning
            component: cnpg
          annotations:
            summary: PostgreSQL backends waiting on locks
            description: 'Pod {{ $labels.pod }} (region {{ $labels.region }}) has >300 backends waiting >5m.'

        - alert: CNPGDatabaseXidAge
          expr: cnpg_pg_database_xid_age > 300000000
          for: 5m
          labels:
            severity: warning
            component: cnpg
          annotations:
            summary: Frozen XID age approaching wraparound risk
            description: 'Pod {{ $labels.pod }} (region {{ $labels.region }}) XID age {{ $value }} — vacuum freeze needed.'

        - alert: CNPGReplicationLag
          expr: cnpg_pg_replication_lag > 30
          for: 2m
          labels:
            severity: warning
            component: cnpg
          annotations:
            summary: Replication lag >30s
            description: 'Standby {{ $labels.pod }} (region {{ $labels.region }}) lagging {{ $value | humanizeDuration }} behind primary.'
            runbook_url: https://cloudnative-pg.io/documentation/current/replication/

        - alert: CNPGReplicationLagCritical
          expr: cnpg_pg_replication_lag > 300
          for: 2m
          labels:
            severity: critical
            component: cnpg
          annotations:
            summary: Replication lag CRITICAL >5m
            description: 'Standby {{ $labels.pod }} (region {{ $labels.region }}) lagging {{ $value | humanizeDuration }} — data loss risk on failover.'

        - alert: CNPGWALArchiveFailing
          expr: (cnpg_pg_stat_archiver_last_failed_time - cnpg_pg_stat_archiver_last_archived_time) > 1
          for: 5m
          labels:
            severity: critical
            component: cnpg
          annotations:
            summary: WAL archive failing
            description: 'Pod {{ $labels.pod }} (region {{ $labels.region }}) last archive failed AFTER last success — backup chain broken.'
            runbook_url: https://cloudnative-pg.io/documentation/current/backup_recovery/

        - alert: CNPGDeadlockConflicts
          expr: rate(cnpg_pg_stat_database_deadlocks[5m]) > 0.1
          for: 5m
          labels:
            severity: warning
            component: cnpg
          annotations:
            summary: Database deadlocks rising
            description: 'Pod {{ $labels.pod }} (region {{ $labels.region }}) deadlock rate {{ $value }}/s.'

        - alert: CNPGReplicaFailingReplication
          expr: cnpg_pg_replication_in_recovery > cnpg_pg_replication_is_wal_receiver_up
          for: 2m
          labels:
            severity: critical
            component: cnpg
          annotations:
            summary: Replica WAL receiver down
            description: 'Replica {{ $labels.pod }} (region {{ $labels.region }}) is in recovery but WAL receiver is NOT up.'

    - name: cnpg.gaps
      interval: 30s
      rules:
        - alert: CNPGPrimaryDown
          # Synthesized: no metric flows from a CNPG pod that's down. Detect via kube-state-metrics + role label.
          # Set kube_pod_labels{label_cnpg_io_cluster!=""} as the universe; 'role=primary' is on the metric series.
          # `absent_over_time` triggers when no primary metric reports for 2m.
          expr: |-
            (count by (region, namespace) (
              kube_pod_info{pod=~".+", namespace=~".+"}
                * on(pod, namespace) group_left(label_cnpg_io_cluster)
                kube_pod_labels{label_cnpg_io_cluster!=""}
            ))
            unless on (region, namespace)
            (count by (region, namespace) (cnpg_pg_replication_lag{role="primary"}))
          for: 2m
          labels:
            severity: critical
            component: cnpg
          annotations:
            summary: CNPG primary unreachable
            description: 'No primary metrics from CNPG cluster in namespace {{ $labels.namespace }} (region {{ $labels.region }}) for 2m.'

        - alert: CNPGBackupFailure
          # CNPG Backup CR status surfaces via cnpg_collector_backup_*; alternative: kube_state via Backup CR.
          # Uses Barman-cloud-plugin path; metric exposed by the plugin's exporter (if enabled).
          expr: |-
            (time() - cnpg_collector_last_available_backup_timestamp) > 86400
          for: 10m
          labels:
            severity: critical
            component: cnpg
          annotations:
            summary: CNPG backup older than 24h
            description: 'Cluster in namespace {{ $labels.namespace }} (region {{ $labels.region }}) last successful backup is {{ $value | humanizeDuration }} old.'

        - alert: CNPGMissingStandby
          # CNPG cluster declared with replicas > 1 but fewer standby pods reporting metrics.
          # cnpg_pg_replication_in_recovery == 1 on each standby. Compare against expected from CNPG cluster spec.
          # Heuristic: 2-node cluster expects 1 standby, 3-node expects 2.
          expr: |-
            (count by (region, namespace) (kube_pod_info{pod=~".+-[0-9]+"} * on(pod, namespace) group_left(label_cnpg_io_cluster) kube_pod_labels{label_cnpg_io_cluster!=""}))
            -
            (count by (region, namespace) (cnpg_pg_replication_lag) > 0)
            > 0
          for: 5m
          labels:
            severity: warning
            component: cnpg
          annotations:
            summary: CNPG standby pod missing
            description: 'Cluster in namespace {{ $labels.namespace }} (region {{ $labels.region }}) is missing {{ $value }} expected standby pod(s).'
```

### E.2 Where alerts route

These alerts have `severity` labels. Per locked decision #2:

- **Mimir Ruler evaluates** them (via Alloy `mimir.rules.kubernetes` → tenant `${REGION}`)
- **Mimir AM dispatches** notifications via routes wired in Part B.2 (fallback config: severity sub-routes → Slack receivers)

Grafana Unified Alerting does **not** also evaluate these — would cause double-fire. Confirm via `Alerts & IRM → Alert rules → External` shows them as "External" (Mimir Ruler origin) not Grafana-native.

### E.3 Per-region vs fleet alerts

Same CNPG alert library lands on every region's `cnpg-system` namespace. Each region's Alloy syncs it to its own tenant. Mimir Ruler evaluates per-tenant — three independent rule groups firing independently. Tagged via the `region` external label injected at remote_write time (signals plan F.1).

**Fleet-wide CNPG alerts** (e.g. "all regions' replication lag rising") use the `monitoring.grafana.com/source_tenants` annotation on a hub-only rule (signals plan F.4 pattern):

```yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: cnpg-fleet-alerts
  namespace: cnpg-system   # only applied on hub via setup.sh gate
  annotations:
    monitoring.grafana.com/source_tenants: "local|eu|us"
spec:
  groups:
    - name: cnpg.fleet
      interval: 1m
      rules:
        - alert: CNPGFleetWideReplicationDegraded
          expr: count(cnpg_pg_replication_lag > 30) >= 2
          for: 5m
          labels:
            severity: critical
            scope: fleet
          annotations:
            summary: ≥2 CNPG clusters lagging across the fleet
```

### E.4 Patch — `monitoring/setup.sh`

After existing CNPG PodMonitor apply block (line ~770 in current setup.sh):

```bash
if kubectl --context "${CONTEXT_NAME}" get namespace cnpg-system &>/dev/null; then
    echo "📊 Applying CNPG alert library..."
    kubectl --context "${CONTEXT_NAME}" apply -f \
        "${GIT_REPO_ROOT}/monitoring/cnpg/cnpg-default-alerts.yaml"

    if [[ "${region}" == "${HUB_REGION}" ]]; then
        kubectl --context "${CONTEXT_NAME}" apply -f \
            "${GIT_REPO_ROOT}/monitoring/cnpg/cnpg-fleet-alerts.yaml"
    else
        kubectl --context "${CONTEXT_NAME}" -n cnpg-system delete prometheusrule \
            cnpg-fleet-alerts --ignore-not-found
    fi
fi
```

---

## Part F — Inhibition rules + `GrafanaMuteTiming`

Closes flapping suppression + planned-maintenance silence. Two layers:

- **Mimir AM `inhibit_rules`** suppress one alert when another fires (cross-alert)
- **GrafanaMuteTiming + GrafanaNotificationPolicy.spec.route.mute_time_intervals** suppress notification during fixed wall-clock windows

### F.1 Patch — `monitoring/mimir/alertmanager-config.yaml.tpl`

Add `inhibit_rules` block. Pattern: a `critical` alert with the same `pod` label inhibits the `warning` version. Replication-lag is the canonical example (CNPGReplicationLagCritical inhibits CNPGReplicationLag for the same pod).

```yaml
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

inhibit_rules:
  - source_matchers:
      - severity = critical
    target_matchers:
      - severity = warning
    equal: [alertname, region, namespace, pod]

  # Primary-down inhibits replication-lag alerts for the same cluster — no point alerting on lag if primary is gone
  - source_matchers:
      - alertname = CNPGPrimaryDown
    target_matchers:
      - alertname =~ CNPGReplicationLag.*
    equal: [region, namespace]

  # WAL archive failing inhibits backup-stale (same root cause)
  - source_matchers:
      - alertname = CNPGWALArchiveFailing
    target_matchers:
      - alertname = CNPGBackupFailure
    equal: [region, namespace]

receivers:
  - name: 'null-default'

  - name: 'slack-critical'
    slack_configs:
      - api_url: '${SLACK_WEBHOOK_URL}'
        channel: '#alerts-critical'
        send_resolved: true

  - name: 'slack-warnings'
    slack_configs:
      - api_url: '${SLACK_WEBHOOK_URL}'
        channel: '#alerts-warnings'
        send_resolved: true
```

### F.2 New file — `monitoring/grafana/grafana_mute_timing_maintenance.yaml`

```yaml
apiVersion: grafana.integreatly.org/v1beta1
kind: GrafanaMuteTiming
metadata:
  name: maintenance-window-nightly
  namespace: grafana
spec:
  instanceSelector:
    matchLabels:
      dashboards: grafana
  name: maintenance-window-nightly
  editable: false
  time_intervals:
    - times:
        - start_time: "02:00"
          end_time: "04:00"
      location: "UTC"
      weekdays: ["monday:sunday"]
```

### F.3 New file — `monitoring/grafana/grafana_mute_timing_weekend.yaml`

Optional second mute timing (weekends — useful for non-prod environments).

```yaml
apiVersion: grafana.integreatly.org/v1beta1
kind: GrafanaMuteTiming
metadata:
  name: weekend-non-prod
  namespace: grafana
spec:
  instanceSelector:
    matchLabels:
      dashboards: grafana
  name: weekend-non-prod
  editable: false
  time_intervals:
    - weekdays: ["saturday", "sunday"]
      location: "UTC"
```

### F.4 Patch — `monitoring/grafana/grafana_notification_policy.yaml` + `_slack.yaml.tpl`

Reference the mute timing in the route. Add `mute_time_intervals:` to both base and slack variants:

```yaml
route:
  receiver: null-log
  group_by: [alertname, region]
  group_wait: 30s
  group_interval: 5m
  repeat_interval: 4h
  mute_time_intervals:
    - maintenance-window-nightly
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

> Both notification-policy variants pick up the `maintenance-window-nightly` mute. Weekend mute opt-in by adding `weekend-non-prod` to the same list.

### F.5 Patch — `monitoring/grafana/kustomization.yaml`

```yaml
resources:
  # ... existing ...
  - grafana_mute_timing_maintenance.yaml
  - grafana_mute_timing_weekend.yaml
```

### F.6 rbr-ver mirror

Mirror F.2 in `demo/yaml/self-service/grafana/grafanamutetiming-maintenance-rbr-ver.yaml` (selector `dashboards: grafana-rbr-ver`) + add `mute_time_intervals: [maintenance-window-nightly-rbr-ver]` to `grafananotificationpolicy-rbr-ver*.yaml`. Apply block already present in `demo/self-service-setup.sh`.

---

## Part G — Severity taxonomy, Mimir AM HA, post-bootstrap label Job

### G.1 Severity taxonomy (locked)

| Severity | Channel | Auto-routes | When to use |
|---|---|---|---|
| `critical` | `slack-critical` (Mimir AM) / `slack` (Grafana) | Page-equivalent | Data-at-risk, customer-visible outage, SLO breach. Examples: CNPGPrimaryDown, CNPGWALArchiveFailing, CNPGReplicationLagCritical, CNPGReplicaFailingReplication, CNPGBackupFailure, CNPGFleetWideReplicationDegraded. |
| `warning` | `slack-warnings` (Mimir AM) / `slack` (Grafana) | Working hours | Capacity trends, recoverable degradation. Examples: CNPGReplicationLag, CNPGBackendsWaiting, CNPGLongRunningTransaction. |
| `info` | `null-log` (both) | None — log only | Diagnostic context, e.g. config drift detected, recording-rule output present. No alert rules ship at `info` by default. |

Convention enforced by:
- Lint in `monitoring/setup.sh`: `kubectl get prometheusrule -A -o json | jq '.items[].spec.groups[].rules[] | select(.labels.severity | IN("critical","warning","info") | not)'` — non-empty result → exit 1 with offending list. **Add at end of setup.sh.**
- README section in `monitoring/README.md`.

### G.2 Mimir AM HA — 3 replicas + memberlist gossip

#### G.2.1 Patch — `monitoring/mimir/mimir-values.yaml`

```yaml
alertmanager:
  replicas: 3                                # was: 1
  persistentVolume:
    size: 1Gi
  statefulSet:
    enabled: true                            # required for stable network identity used by memberlist seed list

mimir:
  structuredConfig:
    # ... existing ...
    alertmanager:
      external_url: http://mimir-alertmanager.mimir.svc.cluster.local:8080/alertmanager
      sharding_ring:
        replication_factor: 3
        heartbeat_period: 15s
        heartbeat_timeout: 1m
    memberlist:
      cluster_label: cnpg-playground-mimir   # prevent cross-stack gossip if another Mimir lives in the same network
      cluster_label_verification_disabled: false
      gossip_interval: 200ms
      gossip_nodes: 3
      pullpush_interval: 30s
      randomize_node_name: true
```

> Mimir AM uses the same memberlist KV store that the ingester/distributor/ring do, so no extra service. State backup lives in S3 (already configured via `alertmanager_storage.s3.bucket_name: mimir-alertmanager`). On replica restart, state recovers from peer first; falls back to S3 if peers unavailable.

#### G.2.2 nodeSelector / tolerations

The existing `nodeSelector: { node-role.kubernetes.io/infra: "" }` already applies to all Mimir components. With 3 AM replicas, ensure ≥3 infra-tainted nodes exist on the hub kind cluster (`scripts/setup.sh` provisions 1 by default — bump to 3 or temporarily allow worker nodes for AM).

Pragmatic playground tweak: pin AM-only to a more permissive node selector:

```yaml
alertmanager:
  replicas: 3
  nodeSelector:
    kubernetes.io/os: linux
  tolerations: []                            # override the global infra-only toleration for AM
```

#### G.2.3 Verification — peer discovery

```bash
kubectl --context kind-k8s-local -n mimir exec mimir-alertmanager-0 -- \
    wget -q -O - http://localhost:8080/multitenant_alertmanager/status | grep -A2 'Peers'
# expect: 2 healthy peers listed (mimir-alertmanager-1, mimir-alertmanager-2)
```

### G.3 Post-bootstrap namespace label watcher Job

Eliminates the "user creates namespace, forgets label, ServiceMonitors silently ignored" footgun. Lightweight Kubernetes Job runs once at end of `monitoring/setup.sh`, then a CronJob re-checks daily.

#### G.3.1 New file — `monitoring/alloy/namespace-labeler-config.yaml.tpl`

ConfigMap-driven allowlist of namespace **patterns** to auto-label. Pattern match means new prod-style namespaces opt-in via naming convention, not manual label.

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: namespace-labeler-config
  namespace: monitoring-system   # new utility namespace; or reuse `mimir`
data:
  patterns.txt: |
    # one regex per line; new namespace matching ANY line gets labeled monitoring/scrape=enabled
    ^cnpg-.*$
    ^.*-db$
    ^demo-.*$
    ^rbr-.*$
```

> Explicit-pattern model means infra namespaces (`vault`, `cert-manager`, `external-secrets`, `traefik`, `dex`) still get labeled imperatively in `scripts/setup.sh` (existing approach from A.2.3) — the watcher handles only user-created tenant DBs.

#### G.3.2 New file — `monitoring/alloy/namespace-labeler-job.yaml.tpl`

```yaml
apiVersion: batch/v1
kind: CronJob
metadata:
  name: namespace-labeler
  namespace: monitoring-system
spec:
  schedule: "0 * * * *"   # hourly — namespace creation is rare
  concurrencyPolicy: Forbid
  successfulJobsHistoryLimit: 1
  failedJobsHistoryLimit: 1
  jobTemplate:
    spec:
      ttlSecondsAfterFinished: 300
      template:
        spec:
          serviceAccountName: namespace-labeler
          restartPolicy: OnFailure
          containers:
            - name: labeler
              image: bitnami/kubectl:1.31
              command: [/bin/sh, -c]
              args:
                - |
                  set -eu
                  PATTERNS="/etc/labeler/patterns.txt"
                  while read -r ns; do
                    [ -z "${ns}" ] && continue
                    has_label=$(kubectl get ns "${ns}" -o jsonpath='{.metadata.labels.monitoring/scrape}')
                    if [ "${has_label}" = "enabled" ]; then continue; fi
                    matched=0
                    while IFS= read -r pat; do
                      [ -z "${pat}" ] && continue
                      case "${pat}" in '#'*) continue ;; esac
                      if echo "${ns}" | grep -qE "${pat}"; then matched=1; break; fi
                    done < "${PATTERNS}"
                    if [ "${matched}" = 1 ]; then
                      echo "labeling ${ns}"
                      kubectl label ns "${ns}" monitoring/scrape=enabled --overwrite
                    fi
                  done < <(kubectl get ns -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')
              volumeMounts:
                - { name: cfg, mountPath: /etc/labeler }
          volumes:
            - name: cfg
              configMap: { name: namespace-labeler-config }
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: namespace-labeler
  namespace: monitoring-system
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: namespace-labeler
rules:
  - apiGroups: [""]
    resources: [namespaces]
    verbs: [get, list, patch, label]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: namespace-labeler
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: namespace-labeler
subjects:
  - kind: ServiceAccount
    name: namespace-labeler
    namespace: monitoring-system
```

> **Important caveat**: even after the labeler runs, Alloy's `prometheus.operator.servicemonitors { namespaces = [...] }` is a STATIC list rendered at Alloy install. New-namespace scrape still requires `monitoring/setup.sh` re-run to re-render Alloy. The labeler **prevents the forgotten-label footgun**, but doesn't bypass Alloy issue #209. README must document both steps. **When Alloy #209 lands, the labeler becomes the sole hook needed** — keep this Job in place so the migration is trivial.

#### G.3.3 Patch — `monitoring/setup.sh`

Apply once per region, after all other monitoring infra is up:

```bash
kubectl --context "${CONTEXT_NAME}" create namespace monitoring-system \
    --dry-run=client -o yaml | kubectl --context "${CONTEXT_NAME}" apply -f -
label_namespace_for_scrape "${CONTEXT_NAME}" monitoring-system

kubectl --context "${CONTEXT_NAME}" apply -f \
    "${GIT_REPO_ROOT}/monitoring/alloy/namespace-labeler-config.yaml.tpl"
kubectl --context "${CONTEXT_NAME}" apply -f \
    "${GIT_REPO_ROOT}/monitoring/alloy/namespace-labeler-job.yaml.tpl"

# Trigger immediate run instead of waiting for first cron tick
kubectl --context "${CONTEXT_NAME}" -n monitoring-system create job --from=cronjob/namespace-labeler \
    namespace-labeler-bootstrap-$(date +%s)
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

### V.6 CNPG alert library applied + visible in Mimir Ruler

```bash
# After setup.sh, alert rules synced to Mimir
kubectl -n cnpg-system get prometheusrule cnpg-default-alerts -o jsonpath='{.spec.groups[*].name}'
# expect: "cnpg.default cnpg.gaps"

curl -s -H 'X-Scope-OrgID: local' \
    'http://localhost:8080/prometheus/api/v1/rules' | \
    jq '[.data.groups[].rules[] | select(.labels.component=="cnpg") | .name] | length'
# expect: 11  (8 default + 3 gap-fillers)

# Hub-only fleet alert
curl -s -H 'X-Scope-OrgID: local' \
    'http://localhost:8080/prometheus/api/v1/rules' | \
    jq '.data.groups[] | select(.name=="cnpg.fleet")'
# expect (hub): object visible
# (non-hub): kubectl -n cnpg-system get prometheusrule cnpg-fleet-alerts → NotFound
```

### V.7 Inhibition rules fire

```bash
# Force CNPGReplicationLagCritical + CNPGReplicationLag for same pod simultaneously
# (Set replication_lag artificially via psql, or use a fake series via Alloy 'localfile' source)

# Mimir AM should only DISPATCH the critical (warning inhibited)
kubectl -n mimir port-forward svc/mimir-alertmanager 9093:8080 &
sleep 2
curl -s 'http://localhost:9093/alertmanager/api/v2/alerts' | \
    jq '[.[] | select(.labels.alertname=="CNPGReplicationLag") | .status.silencedBy] | length'
# expect: > 0  (warning inhibited)

curl -s 'http://localhost:9093/alertmanager/api/v2/alerts' | \
    jq '[.[] | select(.labels.alertname=="CNPGReplicationLagCritical")] | length'
# expect: 1   (critical still firing)
```

### V.8 Mute timing active during window

```bash
# Check current notification policy reflects mute timing
kubectl -n grafana get grafananotificationpolicy notification-policy \
    -o jsonpath='{.spec.route.mute_time_intervals}'
# expect: ["maintenance-window-nightly"]

# Manually trigger an alert during 02-04 UTC → check Grafana → Alerts → State history
# expect: alert state "Pending" then NOT dispatched (mute active)
```

### V.9 Mimir AM HA quorum

```bash
# 3 replicas up
kubectl -n mimir get pods -l app.kubernetes.io/component=alertmanager
# expect: 3/3 Ready

# Peer discovery
for i in 0 1 2; do
  echo "=== alertmanager-$i ==="
  kubectl -n mimir exec mimir-alertmanager-$i -- \
      wget -q -O - http://localhost:8080/multitenant_alertmanager/status | grep -E 'Peer|Cluster'
done
# expect: each replica sees the other 2 as healthy peers

# Kill one replica; AM cluster keeps dispatching
kubectl -n mimir delete pod mimir-alertmanager-1
sleep 30
curl -s 'http://localhost:9093/alertmanager/api/v2/status' | jq '.cluster.status'
# expect: "ready"
```

### V.10 Namespace labeler

```bash
# Create a namespace matching the pattern allowlist (`^.*-db$`)
kubectl create namespace test-foo-db

# Wait for cron tick or trigger manually
kubectl -n monitoring-system create job --from=cronjob/namespace-labeler labeler-test-$(date +%s)
kubectl -n monitoring-system wait --for=condition=complete job -l job-name=labeler-test-* --timeout=60s

# Confirm labeled
kubectl get ns test-foo-db -o jsonpath='{.metadata.labels.monitoring/scrape}'
# expect: enabled

# Create a namespace NOT matching any pattern
kubectl create namespace test-foo-random
kubectl -n monitoring-system create job --from=cronjob/namespace-labeler labeler-test2-$(date +%s)
sleep 5
kubectl get ns test-foo-random -o jsonpath='{.metadata.labels.monitoring/scrape}'
# expect: (empty)

kubectl delete namespace test-foo-db test-foo-random
```

### V.11 Severity taxonomy lint

```bash
# Setup.sh exits non-zero if any rule has invalid severity
kubectl get prometheusrule -A -o json | \
    jq '.items[].spec.groups[].rules[] | select(.alert) | select(.labels.severity | IN("critical","warning","info") | not)'
# expect: (empty)
```

---

## File-level Changeset Summary

### Modify

- `monitoring/alloy/alloy-config.river.tpl` — `namespaces = ${SCRAPE_NAMESPACES_RIVER}` on `prometheus.operator.*`; `rule_namespace_selector { match_labels }` on `mimir.rules.kubernetes` (no envsubst var)
- `monitoring/setup.sh` — label namespaces, derive `SCRAPE_NAMESPACES_RIVER`, render+inject AM fallback config via `--set-file`, apply Slack contact point + notification policy conditionally
- `scripts/setup.sh` — label infra namespaces post-creation
- `scripts/common.sh` — `SLACK_WEBHOOK_URL`, `SLACK_WEBHOOK_URL_RBR_VER` env vars with empty defaults
- `monitoring/mimir/mimir-values.yaml` — ruler `alertmanager_url`, alertmanager `external_url`
- `monitoring/grafana/grafana_instance.yaml` — `unified_alerting.enabled`, disable legacy alerting
- `monitoring/grafana/kustomization.yaml` — add folder, null contact point, null-only notification policy, alert rule group
- `demo/setup.sh` — label `${CNPG_DEMO_NAMESPACE}`
- `demo/self-service-setup.sh` — label `rbr-ver-db`; apply 5+ rbr-ver alerting CRs
- `monitoring/README.md` — namespace allowlist docs; alerting topology; severity taxonomy table (Part G.1); namespace-labeler caveat
- `monitoring/teardown.sh` — remove labels for clean teardown; delete `monitoring-system` namespace + labeler CronJob
- `monitoring/mimir/mimir-values.yaml` — Part G.2: `alertmanager.replicas: 3`, `statefulSet.enabled: true`, memberlist tunings, AM-only nodeSelector relax
- `monitoring/mimir/alertmanager-config.yaml.tpl` — Part F.1 `inhibit_rules` block added
- `monitoring/grafana/grafana_notification_policy.yaml` + `_slack.yaml.tpl` — Part F.4 `mute_time_intervals: [maintenance-window-nightly]`

### Create

- `scripts/funcs_namespace_scrape_label.sh`
- `monitoring/mimir/alertmanager-config.yaml.tpl` — AM fallback config template (rendered + injected via `--set-file`)
- `monitoring/mimir/ingressroute-am.yaml.tpl` (multi-region AM UI exposure)
- `monitoring/grafana/grafana_folder_alerts.yaml`
- `monitoring/grafana/grafana_contact_point_null.yaml`
- `monitoring/grafana/grafana_contact_point_slack.yaml.tpl`
- `monitoring/grafana/grafana_notification_policy.yaml` — null-only base (in kustomization)
- `monitoring/grafana/grafana_notification_policy_slack.yaml.tpl` — Slack routes override (setup.sh only)
- `monitoring/grafana/grafana_alert_rule_group_smoke.yaml`
- `monitoring/grafana/grafana_mute_timing_maintenance.yaml` — Part F.2 nightly mute
- `monitoring/grafana/grafana_mute_timing_weekend.yaml` — Part F.3 weekend mute (optional)
- `monitoring/cnpg/cnpg-default-alerts.yaml` — Part E.1 — upstream library + gap-fillers
- `monitoring/cnpg/cnpg-fleet-alerts.yaml` — Part E.3 — hub-only federated fleet alerts
- `monitoring/alloy/namespace-labeler-config.yaml.tpl` — Part G.3.1 — pattern allowlist ConfigMap
- `monitoring/alloy/namespace-labeler-job.yaml.tpl` — Part G.3.2 — labeler CronJob + RBAC
- `demo/yaml/self-service/grafana/grafanafolder-alerts-rbr-ver.yaml`
- `demo/yaml/self-service/grafana/grafanacontactpoint-null-rbr-ver.yaml`
- `demo/yaml/self-service/grafana/grafanacontactpoint-slack-rbr-ver.yaml.tpl`
- `demo/yaml/self-service/grafana/grafananotificationpolicy-rbr-ver.yaml` — null-only base
- `demo/yaml/self-service/grafana/grafananotificationpolicy-rbr-ver-slack.yaml.tpl` — Slack routes override
- `demo/yaml/self-service/grafana/grafanaalertrulegroup-smoke-rbr-ver.yaml`
- `demo/yaml/self-service/grafana/grafanamutetiming-maintenance-rbr-ver.yaml` — Part F.6 — nightly mute for rbr-ver

---

## Risks / Watchpoints

| Risk | Mitigation |
|---|---|
| Alloy `prometheus.operator.servicemonitors` `namespaces = []` requires re-render on namespace add/remove | Documented in `monitoring/README.md`. Add namespace → label → re-run `monitoring/setup.sh`. |
| User-created namespace gets ServiceMonitors silently ignored | Default-deny security posture. Document explicitly so users opt-in via label. |
| `monitoring/scrape=enabled` label collides with another tool's label namespace | Use prefix-style label key (`monitoring/scrape` not `scrape`) — unlikely collision. |
| Slack webhook URL leakage if committed | Templates only — actual URL injected via env at install. Document `.env`-style override pattern. |
| Mimir AM fallback config references Slack even when no webhook configured | Root receiver is `null-default`; Slack receivers only triggered by severity sub-routes. When `SLACK_WEBHOOK_URL` is the placeholder value, delivery fails silently (Mimir AM logs error, does not crash). Acceptable for playground. |
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
| Mimir AM HA quorum: bumping to 3 replicas needs 3 schedulable nodes on hub kind cluster | Part G.2.2 relaxes AM-only nodeSelector to remove the infra-node-only constraint. Alternative: `scripts/setup.sh` provisions 3 infra-tainted nodes. |
| 3 AM replicas amplify Slack delivery: each replica might dispatch independently | Memberlist clustering dedupes via gossip. Verified by Mimir docs — "When you operate Alertmanager as a cluster, the deduplication is automatic." Confirm post-deploy via Slack message volume (expect 1 per alert, not 3). |
| `cnpg_collector_last_available_backup_timestamp` requires Barman-cloud-plugin metrics exporter enabled | Plugin must be configured per cluster (`ObjectStore.spec.instanceSidecarConfiguration.env` includes prometheus exporter port). For clusters without the plugin, the CNPGBackupFailure alert silently doesn't fire (no metric). Document in `monitoring/README.md`. |
| Missing-standby alert uses kube-state-metrics + heuristic (count CNPG pods vs metric-emitting pods) | Heuristic is fragile when pods are mid-rolling-update. Mitigation: 5m `for:` window gives time to settle. Future improvement: query CNPG Cluster CR `.spec.instances` via kube-state-metrics CR-watch addon. |
| GrafanaMuteTiming `weekdays: ["monday:sunday"]` syntax (range) needs grafana-operator v5.5+ | Verified in current grafana-operator (v5.x). Fallback: enumerate `["monday","tuesday",...]`. |
| Namespace-labeler CronJob hourly cycle leaves up-to-1-hour window where ServiceMonitors in a new namespace are invisible | Pattern allowlist catches well-known names. For ad-hoc namespaces, user still runs `kubectl label ns ... monitoring/scrape=enabled` manually + re-runs `setup.sh`. Documented in README. |
| `inhibit_rules.target_matchers.alertname =~ CNPGReplicationLag.*` regex on `alertname` requires Mimir AM v0.27+ matcher v2 | Confirmed shipped in mimir-distributed chart bundled AM. Verify via `mimir-alertmanager --version` post-deploy. |
| Severity-lint in setup.sh can block legitimate rules from third-party charts (e.g. kube-prometheus-stack) | Lint runs at END of setup, after all charts. Add an exception list of namespaces to skip (e.g. `kube-system`) in the jq expression. Document. |
| `cnpg-fleet-alerts` PrometheusRule on hub uses `source_tenants` annotation — depends on Alloy 1.8+ | Memory confirms Alloy version. Verify `mimir.rules.kubernetes.address` returns annotation-aware behavior in `helm get values alloy`. |

---

## Suggested Commit Sequence

1. **Commit 1** — `feat(monitoring): label namespaces for scrape allowlist`
   Touches: `scripts/funcs_namespace_scrape_label.sh` (new), `monitoring/setup.sh`, `scripts/setup.sh`, `demo/setup.sh`, `demo/self-service-setup.sh`, `monitoring/README.md`, `monitoring/teardown.sh`.
   Validation: `kubectl get ns -l monitoring/scrape=enabled` lists expected namespaces.

2. **Commit 2** — `feat(alloy): scope ServiceMonitor/PodMonitor scrape to labeled namespaces`
   Touches: `monitoring/alloy/alloy-config.river.tpl`, `monitoring/setup.sh` (namespace-list render).
   Validation: V.1.

3. **Commit 3** — `feat(mimir): wire Ruler→Alertmanager with default null receiver`
   Touches: `monitoring/mimir/mimir-values.yaml`, `monitoring/mimir/alertmanager-config.yaml.tpl` (new), `monitoring/mimir/ingressroute-am.yaml.tpl` (new), `monitoring/setup.sh` (render + `--set-file`).
   Validation: V.2.

4. **Commit 4** — `feat(grafana): Unified Alerting + null contact point + sample rule (main)`
   Touches: `monitoring/grafana/grafana_instance.yaml`, 5 new alerting CRs, `monitoring/grafana/kustomization.yaml`, `scripts/common.sh` (SLACK_WEBHOOK_URL env), `monitoring/setup.sh` (conditional slack apply).
   Validation: V.3.

5. **Commit 5** — `feat(self-service): mirror Grafana Alerting to grafana-rbr-ver`
   Touches: 5 new rbr-ver alerting CRs, `demo/self-service-setup.sh`.
   Validation: V.4.

6. **Commit 6** — `feat(cnpg): import upstream alert library + 3 gap alerts`
   Touches: `monitoring/cnpg/cnpg-default-alerts.yaml` (new), `monitoring/cnpg/cnpg-fleet-alerts.yaml` (new), `monitoring/setup.sh` (Part E.4 apply block).
   Validation: V.6.

7. **Commit 7** — `feat(monitoring): Mimir AM inhibit rules + Grafana mute timings`
   Touches: `monitoring/mimir/alertmanager-config.yaml.tpl` (inhibit_rules), `monitoring/grafana/grafana_mute_timing_{maintenance,weekend}.yaml` (new), `monitoring/grafana/grafana_notification_policy{,_slack}.yaml.tpl` (mute_time_intervals), `monitoring/grafana/kustomization.yaml`, rbr-ver mute timing mirror.
   Validation: V.7, V.8.

8. **Commit 8** — `feat(monitoring): Mimir AM HA (3 replicas + memberlist gossip)`
   Touches: `monitoring/mimir/mimir-values.yaml`.
   Validation: V.9.

9. **Commit 9** — `feat(monitoring): post-bootstrap namespace labeler CronJob + severity taxonomy lint`
   Touches: `monitoring/alloy/namespace-labeler-config.yaml.tpl` (new), `monitoring/alloy/namespace-labeler-job.yaml.tpl` (new), `monitoring/setup.sh` (Part G.3.3 apply + severity lint at exit), `monitoring/README.md` (taxonomy table).
   Validation: V.10, V.11.

---

## Out of Scope

- Per-tenant Mimir AM configs (only default config uploaded; tenants share until customized via API)
- HTTPS for Mimir AM IngressRoute — uses Vault PKI when wildcard certs land
- PagerDuty/Opsgenie/email contact points — Slack scaffold only
- Multi-tenant Grafana org_mapping → AM routing isolation
- Alloy namespace label-based selector once Alloy issue #209 lands — revisit then
- Slack webhook URL via Vault ExternalSecret — `SLACK_WEBHOOK_URL` env-var injection retained for simplicity. Migration to ESO + `secretKeyRef` deferred to next round.
- CNPG-specific Grafana Alerting rules (Grafana Unified Alerting layer) — duplicates Mimir Ruler path; keep alerts on Mimir Ruler only. Grafana Alerting reserved for cross-DS rules.
- Multi-region Mimir AM (still single hub region, 3 replicas in one cluster)
- Custom alert templates / runbook-URL standardization beyond `runbook_url` annotation
- Alert-volume rate-limiting in Slack (Slack throttles natively at 1/s/channel)
- `monitoring-system` utility namespace consolidation (currently new; could fold into `mimir` or `grafana`)
