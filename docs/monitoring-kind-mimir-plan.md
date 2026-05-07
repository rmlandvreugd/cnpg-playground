# Plan — kind Control-Plane Metrics + Mimir + Traefik Access Logs + Tempo Tracing

## Context

Four follow-on workstreams branching off `docs/monitoring-k8s-core-plan.md`:

1. **kind control-plane metrics** — `kube-controller-manager`, `kube-scheduler`, `kube-proxy`, and `etcd` bind their metrics endpoints to `127.0.0.1` by default in kubeadm-bootstrapped clusters (which kind uses). The current playground keeps the corresponding ServiceMonitors enabled but accepts DOWN targets. This plan flips them to `0.0.0.0` via `kubeadmConfigPatches` so the bundled kube-prometheus-stack ServiceMonitors actually scrape successfully.
2. **Grafana Mimir integration** — Add Mimir as long-term, multi-region metrics storage behind the existing per-region Prometheus instances. Each region's Prometheus continues to scrape locally, then `remoteWrite`s to a single Mimir hub backed by RustFS S3. Grafana gains a Mimir datasource for cross-region queries.
3. **Traefik access logs in Loki** — Enable Traefik JSON access log on stdout; Alloy splits Traefik pod logs into a dedicated `loki.process` pipeline with `method` / `status` / `route` promoted to Loki labels. Existing `system_logs` pipeline gets a Traefik drop rule so logs aren't double-shipped.
4. **Grafana Tempo + Traefik OTLP tracing** — Tempo on the hub region (RustFS S3 backend), Traefik exports OTLP traces (gRPC in-cluster on hub; HTTP/4318 cross-region via sslip.io). Grafana datasources cross-link the three signals: Mimir histogram exemplars → Tempo span → Loki logs → back to Tempo.

**Primary target: single-region (`local`).** Multi-region (`eu`/`us`) must continue to work; the design treats the first region in `REGIONS` as the "hub" host of Mimir + Tempo, with other regions pushing in via Traefik.

**Locked decisions (from interactive prompts):**

- Coexist: Prometheus keeps scraping; adds `spec.remoteWrite` → Mimir.
- Mimir classic architecture, monolithic single-binary, **no Kafka**.
- kind kubeadm patch applied now; plan documents the `demo/teardown.sh` + `scripts/setup.sh` recreate cycle.
- Tracing backend: **Grafana Tempo** (`tempo-distributed` chart, replicas=1, RustFS S3 bucket `tempo`).
- Multi-region tracing: **hub on `REGIONS[0]`** (mirrors Mimir hub design).
- OTLP transport: **gRPC in-cluster, HTTP/4318 cross-region via sslip.io IngressRoute**. No otel-collector.
- Sampling: **100%** (`tracing.sampleRate: 1.0`); document tunability for prod.
- Cross-signal correlation: **all three** — Mimir exemplars + Tempo↔Loki + Loki→Tempo derived fields.
- Access logs: **JSON format on Traefik stdout** + Alloy `stage.json` parsing with `method`/`status`/`route` label promotion.

---

## Part A — kind Control-Plane Metrics

### A.1 Why the current state fails

`kubeadm` defaults bind:

| Component | Default bind | Default port |
|---|---|---|
| `kube-controller-manager` | `127.0.0.1` | 10257 |
| `kube-scheduler` | `127.0.0.1` | 10259 |
| `kube-proxy` | `127.0.0.1` | 10249 |
| `etcd` `--listen-metrics-urls` | `http://127.0.0.1:2381` | 2381 |

Any pod outside the host network (i.e. Prometheus on a worker) cannot reach those endpoints. The `kube-prometheus-stack` chart provides ServiceMonitors that target the kube-system Service backing each component; with the default kind bind, those targets show DOWN.

### A.2 Patch — `k8s/kind-cluster.yaml.tpl` and `k8s/kind-cluster.yaml`

Extend the **control-plane node's** existing `kubeadmConfigPatches` block. The `.tpl` already has a `ClusterConfiguration` patch for OIDC; merge new fields into the same block. Add a second patch entry for `KubeProxyConfiguration`.

**`k8s/kind-cluster.yaml.tpl`** — replace the control-plane node block with:

```yaml
- role: control-plane
  extraMounts:
    - hostPath: ${DEX_TLS_DIR}/ca-chain.pem
      containerPath: /etc/kubernetes/oidc/dex-ca.pem
      readOnly: true
  kubeadmConfigPatches:
    - |
      kind: ClusterConfiguration
      apiServer:
        extraArgs:
          oidc-issuer-url: https://${DEX_HOST}:${DEX_PORT}/dex
          oidc-ca-file: /etc/kubernetes/oidc/dex-ca.pem
          oidc-client-id: kubernetes
          oidc-username-claim: email
          oidc-username-prefix: "oidc:"
          oidc-groups-claim: groups
          oidc-groups-prefix: "oidc:"
      controllerManager:
        extraArgs:
          bind-address: 0.0.0.0
      scheduler:
        extraArgs:
          bind-address: 0.0.0.0
      etcd:
        local:
          extraArgs:
            listen-metrics-urls: http://0.0.0.0:2381
    - |
      kind: KubeProxyConfiguration
      metricsBindAddress: 0.0.0.0
```

**`k8s/kind-cluster.yaml`** (no-OIDC variant) — replace the control-plane node block with:

```yaml
- role: control-plane
  kubeadmConfigPatches:
    - |
      kind: ClusterConfiguration
      controllerManager:
        extraArgs:
          bind-address: 0.0.0.0
      scheduler:
        extraArgs:
          bind-address: 0.0.0.0
      etcd:
        local:
          extraArgs:
            listen-metrics-urls: http://0.0.0.0:2381
    - |
      kind: KubeProxyConfiguration
      metricsBindAddress: 0.0.0.0
```

### A.3 kube-prometheus-stack — point kubeEtcd ServiceMonitor at port 2381

The chart's default `kubeEtcd.service.targetPort` is `2379` (the etcd client port, TLS). Our patch exposes the metrics-only listener on `2381` (HTTP, no TLS). Override:

**`monitoring/kube-prometheus-stack-values.yaml`** — append:

```yaml
kubeEtcd:
  enabled: true
  service:
    enabled: true
    port: 2381
    targetPort: 2381
  serviceMonitor:
    scheme: http
    insecureSkipVerify: true
```

`kubeControllerManager`, `kubeScheduler`, `kubeProxy` already use the correct bundled ServiceMonitor wiring once binds move off loopback — no extra values needed (already enabled per `docs/monitoring-k8s-core-plan.md` Commit 1).

### A.4 Recreate cycle (required)

`kubeadmConfigPatches` apply only at cluster bootstrap. Existing clusters must be torn down and recreated:

```bash
./demo/teardown.sh
./scripts/setup.sh           # picks up new kind-cluster.yaml(.tpl)
./monitoring/setup.sh        # rolls Prometheus stack with kubeEtcd override
```

### A.5 Security note (single-region playground)

Binding control-plane component metrics to `0.0.0.0` makes them reachable from any pod on the kind docker network:

- `kube-controller-manager` (`10257/https`) and `kube-scheduler` (`10259/https`) require **bearer-token auth** — RBAC-protected, safe.
- `kube-proxy` (`10249/http`) is plain HTTP but exposes only operational metrics.
- **etcd `2381` is HTTP, unauthenticated.** It exposes etcd's own runtime metrics but not key/value data. Acceptable for a local playground; **document this** in `monitoring/README.md`.

For production, the canonical alternative is to scrape etcd via the existing `2379` client port using the etcd peer/client certificate (PodMonitor with TLS + cert from the `etcd-certs` Secret). Out of scope here.

---

## Part B — Mimir Integration

### B.1 Topology

| Mode | Mimir | Prometheus push target |
|---|---|---|
| Single-region (`local`) | runs in `local` cluster, namespace `mimir` | `http://mimir-nginx.mimir.svc.cluster.local/api/v1/push` |
| Multi-region (`eu`+`us`+…) | runs in **first** region from `REGIONS[]` (the "hub") | other regions: `http://mimir-push.<hub-traefik-ip-dashed>.sslip.io/api/v1/push`, header `X-Scope-OrgID: <region>` |

Hub region selection: `HUB_REGION="${REGIONS[0]}"`. Single-region case collapses to "hub == only region", local cluster service URL.

### B.2 Helm chart and mode

- Chart: `grafana/mimir-distributed` (OCI: `oci://ghcr.io/grafana/helm-charts/mimir-distributed`).
- **Classic architecture** (no Kafka): set
  ```yaml
  kafka:
    enabled: false
  mimir:
    structuredConfig:
      ingest_storage:
        enabled: false
  ```
- **Monolithic compaction**: set replicas to 1 across all components (override defaults). The chart still spins separate Deployments/StatefulSets per role but pinned at `replicas: 1` keeps the footprint small.
- Storage: S3 → existing RustFS bucket `mimir`. Reuses the same `objectstore-local` Service + Endpoints pattern that Loki uses.

### B.3 New file — `monitoring/mimir/mimir-values.yaml`

```yaml
# Classic architecture, monolithic-style single-replica deployment for the playground.
# Storage: RustFS S3 (in-cluster Service objectstore-local in the mimir namespace).

kafka:
  enabled: false

minio:
  enabled: false  # bundled MinIO unused — RustFS provides S3

mimir:
  structuredConfig:
    ingest_storage:
      enabled: false
    common:
      storage:
        backend: s3
        s3:
          endpoint: objectstore-local.mimir.svc.cluster.local:9000
          region: us-east-1
          insecure: true
          # access_key_id / secret_access_key injected via env vars below
          access_key_id: ${RUSTFS_ROOT_USER}
          secret_access_key: ${RUSTFS_ROOT_PASSWORD}
    blocks_storage:
      s3:
        bucket_name: mimir-blocks
    alertmanager_storage:
      s3:
        bucket_name: mimir-alertmanager
    ruler_storage:
      s3:
        bucket_name: mimir-ruler
    multitenancy_enabled: true
    limits:
      ingestion_rate: 100000
      ingestion_burst_size: 200000

# Pin every component to single replica — playground footprint
distributor:    { replicas: 1 }
ingester:       { replicas: 1, persistentVolume: { size: 5Gi } }
querier:        { replicas: 1 }
query_frontend: { replicas: 1 }
query_scheduler: { replicas: 1 }
store_gateway:  { replicas: 1, persistentVolume: { size: 5Gi } }
compactor:      { replicas: 1, persistentVolume: { size: 5Gi } }
ruler:          { replicas: 1 }
alertmanager:   { replicas: 1, persistentVolume: { size: 1Gi } }
overrides_exporter: { replicas: 1 }

nginx:
  replicas: 1
  service:
    type: ClusterIP

# Keep on infra nodes
nodeSelector:
  node-role.kubernetes.io/infra: ""
tolerations:
  - key: node-role.kubernetes.io/infra
    operator: Exists
    effect: NoSchedule
```

> Schema check: `mimir.structuredConfig` is the chart's documented escape-hatch for raw `mimir.yaml`. `s3.access_key_id`/`secret_access_key` accept `${VAR}` env-substituted at config render time when the chart's `extraEnv` plumbing is used; if the chart version does not expand env in structuredConfig, fall back to `helm --set 'mimir.structuredConfig.common.storage.s3.access_key_id=...'` from the orchestrator (mirroring the existing Loki pattern in `monitoring/setup.sh`).

### B.4 New file — `monitoring/mimir/objectstore-bridge.yaml.tpl`

Mirror the Loki pattern: rendered by `setup.sh`, wires the in-cluster `objectstore-local` Service+Endpoints in the `mimir` namespace pointing at the host RustFS container.

```yaml
apiVersion: v1
kind: Service
metadata:
  name: objectstore-local
  namespace: mimir
spec:
  ports:
    - name: s3
      port: 9000
      targetPort: 9000
---
apiVersion: v1
kind: Endpoints
metadata:
  name: objectstore-local
  namespace: mimir
subsets:
  - addresses:
      - ip: ${OBJECTSTORE_IP}
    ports:
      - name: s3
        port: 9000
```

### B.5 New file — `monitoring/mimir/ingressroute.yaml.tpl` (multi-region only)

Renders only when `${#REGIONS[@]} -gt 1` and current region is the hub.

```yaml
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: mimir-push
  namespace: mimir
spec:
  entryPoints: [web]
  routes:
    - match: Host(`mimir-push.${TRAEFIK_IP_DASHED}.sslip.io`)
      kind: Rule
      services:
        - name: mimir-nginx
          port: 80
```

### B.6 Patch — `monitoring/prometheus-instance/deploy_prometheus.yaml`

Add `remoteWrite` to the `Prometheus` CR. The remote URL is templated by `setup.sh` based on hub vs non-hub region:

```yaml
spec:
  # ... existing fields (selectors from previous plan) ...
  remoteWrite:
    - url: ${MIMIR_PUSH_URL}
      headers:
        X-Scope-OrgID: ${REGION}
      writeRelabelConfigs:
        - sourceLabels: [__name__]
          regex: '(up|scrape_.*|kube_.*|node_.*|kubelet_.*|apiserver_.*|cnpg_.*|pg_.*)'
          action: keep
```

`setup.sh` substitutes:

- `MIMIR_PUSH_URL` = `http://mimir-nginx.mimir.svc.cluster.local/api/v1/push` for the hub region; `http://mimir-push.<hub-traefik-ip-dashed>.sslip.io/api/v1/push` for non-hub regions.
- `REGION` = current region (used as Mimir tenant ID).

The relabel keep-list trims junk so RustFS doesn't fill up; expandable later.

### B.7 New file — `monitoring/grafana/grafana_datasource_mimir.yaml`

Adds Mimir as a Prometheus-typed datasource so dashboards can switch via dropdown. Deployed only on the hub region's Grafana (other regions still get a same-namespace Prom datasource).

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
    type: prometheus
    access: proxy
    url: http://mimir-nginx.mimir.svc.cluster.local
    jsonData:
      httpHeaderName1: X-Scope-OrgID
      timeInterval: 15s
    secureJsonData:
      httpHeaderValue1: __all__   # cross-tenant read; replace with per-region UID via Grafana templating later
```

For per-region dashboards in multi-region, the `X-Scope-OrgID` header can be templated via Grafana variable at dashboard level instead of datasource — out of scope for this plan.

### B.8 Patch — `monitoring/setup.sh`

New region-aware logic, in the per-region loop:

```bash
HUB_REGION="${REGIONS[0]}"
HUB_CONTEXT="$(get_cluster_context "${HUB_REGION}")"

for region in "${REGIONS[@]}"; do
    CONTEXT_NAME="$(get_cluster_context "${region}")"

    if [[ "${region}" == "${HUB_REGION}" ]]; then
        # 1. Render objectstore-bridge for mimir ns
        # 2. Helm install grafana/mimir-distributed
        # 3. If multi-region: render ingressroute.yaml.tpl
        # 4. Compute MIMIR_PUSH_URL = http://mimir-nginx.mimir.svc.cluster.local/api/v1/push
    else
        # Compute MIMIR_PUSH_URL via hub Traefik IP:
        HUB_TRAEFIK_IP="$(get_traefik_lb_ip "${HUB_CONTEXT}" 30)"
        HUB_TRAEFIK_DASHED="$(ip_to_dashed "${HUB_TRAEFIK_IP}")"
        MIMIR_PUSH_URL="http://mimir-push.${HUB_TRAEFIK_DASHED}.sslip.io/api/v1/push"
    fi

    # Render & apply prometheus-instance with MIMIR_PUSH_URL + REGION substituted
    REGION="${region}" MIMIR_PUSH_URL="${MIMIR_PUSH_URL}" \
        envsubst '${REGION} ${MIMIR_PUSH_URL}' \
        < "${GIT_REPO_ROOT}/monitoring/prometheus-instance/deploy_prometheus.yaml.tpl" \
        | kubectl --context "${CONTEXT_NAME}" apply -f -
done
```

Convert `monitoring/prometheus-instance/deploy_prometheus.yaml` → `.tpl` (mirroring the existing `*.tpl` + `envsubst` pattern in the repo). Keep the `kustomization.yaml` building the rest.

### B.9 New file — `monitoring/mimir/kustomization.yaml`

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: mimir
resources: []  # values + ingressroute applied via setup.sh; placeholder for future static manifests
```

### B.10 Pin chart version

Add to `scripts/common.sh`:

```bash
MIMIR_CHART_VERSION="5.x.y"  # latest classic-mode-friendly release at apply time
```

Used by `helm_upgrade_install` in setup.sh.

---

## Part C — Traefik Access Logs in Loki

### C.1 Why

Traefik default = no access log. Operational visibility (per-request status, route, latency, traceID) requires a JSON-format access log on stdout, then parsed by Alloy into Loki streams. Alloy's existing `discovery.kubernetes "all_pods"` already collects every pod's stdout, but the Traefik access log lines are currently un-labelled and inseparable from runtime logs. Part C splits them into a dedicated Alloy pipeline with field-promoted labels.

### C.2 Patch — `traefik/values.yaml`

Append:

```yaml
accessLog:
  format: json
  filePath: ""           # stdout — Alloy already tails all pod stdout
  bufferingSize: 0       # immediate flush; playground volume is low
  fields:
    defaultMode: keep
    headers:
      defaultMode: drop  # PII safety — drop request headers by default
      names:
        User-Agent: keep
        X-Forwarded-For: keep
```

### C.3 Patch — `monitoring/alloy/alloy-config.river`

**Insert** before the existing `loki.source.kubernetes "system_logs"` block:

```hcl
// === Traefik access-log branch ===
discovery.relabel "traefik_pods" {
  targets = discovery.kubernetes.all_pods.targets

  rule {
    source_labels = ["__meta_kubernetes_pod_label_app_kubernetes_io_name"]
    regex         = "traefik"
    action        = "keep"
  }
  rule {
    source_labels = ["__meta_kubernetes_namespace"]
    target_label  = "namespace"
  }
  rule {
    source_labels = ["__meta_kubernetes_pod_name"]
    target_label  = "pod"
  }
  rule {
    target_label = "app"
    replacement  = "traefik"
  }
}

loki.source.kubernetes "traefik_access" {
  targets    = discovery.relabel.traefik_pods.output
  forward_to = [loki.process.traefik_access.receiver]
}

loki.process "traefik_access" {
  // Lines that don't parse as JSON pass through unmodified
  stage.json {
    expressions = {
      method   = "RequestMethod",
      status   = "DownstreamStatus",
      host     = "RequestHost",
      route    = "RouterName",
      service  = "ServiceName",
      duration = "Duration",
      trace_id = "traceID",
    }
  }

  // Promote LOW-cardinality fields to Loki labels (queryable as {label=...})
  // Keep host/duration/trace_id as parsed fields only — high cardinality
  stage.labels {
    values = {
      method = "method",
      status = "status",
      route  = "route",
    }
  }

  forward_to = [loki.write.grafana_loki.receiver]
}
```

**Extend** the existing `discovery.relabel "all_pods"` block — add a Traefik drop rule alongside the CNPG drop, so Traefik pods aren't double-shipped:

```hcl
// Drop CNPG pods here — already shipped via cnpg_logs → pgaudit pipeline
rule {
  source_labels = ["__meta_kubernetes_pod_label_cnpg_io_cluster"]
  action        = "drop"
  regex         = ".+"
}
// Drop Traefik pods — shipped via traefik_access pipeline above
rule {
  source_labels = ["__meta_kubernetes_pod_label_app_kubernetes_io_name"]
  action        = "drop"
  regex         = "traefik"
}
```

### C.4 PII watchpoint

Traefik JSON access log contains the full `RequestPath` including query string. Any token leaked into a URL parameter is retained in Loki for the chunk-store retention window. Document in `monitoring/README.md`: rotate any token leaked into a URL; Traefik does **not** strip URL params.

### C.5 LogQL examples

```
# Top 10 routes returning 5xx in last 15 min
topk(10, sum by (route) (count_over_time({app="traefik", status=~"5.."}[15m])))

# 95th percentile request duration per service
quantile_over_time(0.95, {app="traefik"} | json | unwrap duration [5m]) by (service)

# All requests for a specific traceID (pivot from Tempo span → Loki)
{app="traefik"} | json | trace_id="<traceID>"
```

---

## Part D — Tempo + Traefik Tracing

### D.1 Topology

| Mode | Tempo | Traefik OTLP target |
|---|---|---|
| Single-region (`local`) | runs in `local`, ns `tempo` | gRPC `tempo-distributor.tempo.svc.cluster.local:4317` |
| Multi-region (`eu`+`us`+…) | runs on hub (`REGIONS[0]`), ns `tempo` | hub: gRPC ClusterIP. Non-hub: HTTP `http://tempo-otlp.<hub-traefik-ip-dashed>.sslip.io/v1/traces` |

Mixed transport per locked decision: gRPC stays in-cluster (lowest overhead, native batching); HTTP/4318 carries cross-region traffic (sslip.io routable, no TCP/SNI plumbing — symmetric with Mimir push).

### D.2 Helm chart and mode

- Chart: `grafana/tempo-distributed` (OCI: `oci://ghcr.io/grafana/helm-charts/tempo-distributed`).
- Single-binary-style: pin every role to `replicas: 1`. The chart still spins per-role Deployments/StatefulSets; we accept the footprint for parity with Mimir.
- Storage: RustFS S3 bucket `tempo`, mirroring Loki/Mimir bucket-init pattern.
- No bundled MinIO sidecar.
- `metricsGenerator` enabled — emits service-graph and span-metrics histograms with traceID exemplars, remote-written to Mimir for Grafana correlation.

### D.3 New file — `monitoring/tempo/tempo-values.yaml`

```yaml
# Single-replica tempo-distributed; RustFS S3 backend; OTLP gRPC + HTTP receivers.

minio:
  enabled: false  # bundled MinIO unused — RustFS provides S3

storage:
  trace:
    backend: s3
    s3:
      bucket: tempo
      endpoint: objectstore-local.tempo.svc.cluster.local:9000
      region: us-east-1
      insecure: true
      # access_key / secret_key injected via --set in setup.sh
      # (mirrors Loki/Mimir credential plumbing)

# Pin all roles to single replica
ingester:        { replicas: 1, persistence: { enabled: true, size: 5Gi } }
distributor:     { replicas: 1 }
compactor:       { replicas: 1 }
querier:         { replicas: 1 }
queryFrontend:   { replicas: 1 }

metricsGenerator:
  enabled: true
  replicas: 1
  config:
    registry:
      external_labels:
        source: tempo
    storage:
      remote_write:
        - url: http://mimir-nginx.mimir.svc.cluster.local/api/v1/push
          headers:
            X-Scope-OrgID: tempo

overrides:
  defaults:
    metrics_generator:
      processors: [service-graphs, span-metrics]

distributor:
  config:
    receivers:
      otlp:
        protocols:
          grpc:
            endpoint: 0.0.0.0:4317
          http:
            endpoint: 0.0.0.0:4318

nodeSelector:
  node-role.kubernetes.io/infra: ""
tolerations:
  - key: node-role.kubernetes.io/infra
    operator: Exists
    effect: NoSchedule
```

> Schema check: tempo-distributed receiver config exposed under `distributor.config.receivers` in chart versions ≥1.x; the structuredConfig shape may shift between minor releases. Validate with `helm show values` at the pinned `TEMPO_CHART_VERSION`.

### D.4 New file — `monitoring/tempo/objectstore-bridge.yaml.tpl`

Mirror Mimir's bridge — rendered by `monitoring/setup.sh`, points the in-cluster `objectstore-local` Service+Endpoints in `tempo` namespace at the host RustFS container.

```yaml
apiVersion: v1
kind: Service
metadata:
  name: objectstore-local
  namespace: tempo
spec:
  ports:
    - name: s3
      port: 9000
      targetPort: 9000
---
apiVersion: v1
kind: Endpoints
metadata:
  name: objectstore-local
  namespace: tempo
subsets:
  - addresses:
      - ip: ${OBJECTSTORE_IP}
    ports:
      - name: s3
        port: 9000
```

### D.5 New file — `monitoring/tempo/ingressroute.yaml.tpl` (multi-region only)

Renders only when current region is hub and `${#REGIONS[@]} -gt 1`.

```yaml
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: tempo-otlp-http
  namespace: tempo
spec:
  entryPoints: [web]
  routes:
    - match: Host(`tempo-otlp.${TRAEFIK_IP_DASHED}.sslip.io`)
      kind: Rule
      services:
        - name: tempo-distributor
          port: 4318
```

### D.6 New file — `monitoring/tempo/kustomization.yaml`

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: tempo
resources: []  # values + bridge + ingressroute applied via setup.sh
```

### D.7 Patch — `traefik/values.yaml` (tracing block)

Append:

```yaml
tracing:
  serviceName: traefik
  sampleRate: 1.0          # 100% sampling — playground; tune down for prod
  otlp:
    enabled: true
    # transport (grpc vs http) and endpoint set at install time via --set
    # because hub uses gRPC ClusterIP and non-hub uses HTTP sslip.io
  globalAttributes:
    deployment.environment: playground
```

Per-region `--set` overrides applied at Traefik install (see D.8):

```bash
# Hub region — gRPC in-cluster
--set 'tracing.otlp.grpc.enabled=true'
--set 'tracing.otlp.grpc.endpoint=tempo-distributor.tempo.svc.cluster.local:4317'
--set 'tracing.otlp.grpc.insecure=true'
--set "tracing.serviceName=traefik-${region}"
--set "tracing.globalAttributes.cluster=${region}"

# Non-hub region — HTTP via hub Traefik IngressRoute
--set 'tracing.otlp.http.enabled=true'
--set "tracing.otlp.http.endpoint=http://tempo-otlp.${HUB_TRAEFIK_DASHED}.sslip.io/v1/traces"
--set "tracing.serviceName=traefik-${region}"
--set "tracing.globalAttributes.cluster=${region}"
```

> Watchpoint: Traefik 3.3 OTLP option names — `tracing.otlp.grpc.*` / `tracing.otlp.http.*` — confirmed in Traefik static configuration reference, exposed via Helm chart 39.x. Validate with `helm show values oci://ghcr.io/traefik/helm/traefik --version ${TRAEFIK_CHART_VERSION}` before bumping.

### D.8 Patch — install ordering across `scripts/setup.sh` and `monitoring/setup.sh`

**Issue:** `scripts/setup.sh` installs Traefik per region in its main loop; `monitoring/setup.sh` runs afterward and installs Tempo on the hub. Non-hub Traefik instances cannot resolve `tempo-otlp.<hub-ip>.sslip.io` until hub Tempo + hub IngressRoute exist.

**Resolution (chosen — minimal phase-ordering churn):**

1. In `scripts/setup.sh`, **hub-region Traefik** install adds gRPC tracing flags inline (Tempo's in-cluster Service is created later, but Traefik will retry until reachable):

   ```bash
   if [[ "${region}" == "${HUB_REGION:-${REGIONS[0]}}" ]]; then
       TRACING_SET_ARGS=(
         --set "tracing.otlp.grpc.enabled=true"
         --set "tracing.otlp.grpc.endpoint=tempo-distributor.tempo.svc.cluster.local:4317"
         --set "tracing.otlp.grpc.insecure=true"
       )
   else
       # Non-hub Traefik: install WITHOUT tracing initially. monitoring/setup.sh
       # will helm-upgrade these once hub Tempo IngressRoute exists.
       TRACING_SET_ARGS=()
   fi

   helm_upgrade_install traefik \
       oci://ghcr.io/traefik/helm/traefik \
       traefik "${CONTEXT_NAME}" "${TRAEFIK_CHART_VERSION}" \
       --values "${GIT_REPO_ROOT}/traefik/values.yaml" \
       --set "tracing.serviceName=traefik-${region}" \
       --set "tracing.globalAttributes.cluster=${region}" \
       "${TRACING_SET_ARGS[@]}"
   ```

2. In `monitoring/setup.sh`, after hub Tempo install + IngressRoute apply:

   ```bash
   HUB_TRAEFIK_IP="$(get_traefik_lb_ip "${HUB_CONTEXT}" 30)"
   HUB_TRAEFIK_DASHED="$(ip_to_dashed "${HUB_TRAEFIK_IP}")"

   for region in "${REGIONS[@]}"; do
       if [[ "${region}" != "${HUB_REGION}" ]]; then
           echo "🔁 Reapplying Traefik on '${region}' to enable OTLP HTTP push to hub Tempo..."
           NON_HUB_CTX="$(get_cluster_context "${region}")"
           helm_upgrade_install traefik \
               oci://ghcr.io/traefik/helm/traefik \
               traefik "${NON_HUB_CTX}" "${TRAEFIK_CHART_VERSION}" \
               --values "${GIT_REPO_ROOT}/traefik/values.yaml" \
               --set "tracing.otlp.http.enabled=true" \
               --set "tracing.otlp.http.endpoint=http://tempo-otlp.${HUB_TRAEFIK_DASHED}.sslip.io/v1/traces" \
               --set "tracing.serviceName=traefik-${region}" \
               --set "tracing.globalAttributes.cluster=${region}"
       fi
   done
   ```

3. Hub Tempo install block in `monitoring/setup.sh` (per-region loop, hub branch):

   ```bash
   if [[ "${region}" == "${HUB_REGION}" ]]; then
       echo "🪣 Creating Tempo S3 bucket..."
       kubectl --context "${CONTEXT_NAME}" -n grafana delete pod tempo-bucket-init --ignore-not-found
       kubectl run tempo-bucket-init --restart=Never \
           --image=minio/mc:latest \
           --namespace=grafana \
           --context="${CONTEXT_NAME}" \
           --command -- sh -c "mc alias set store http://objectstore-local:9000 '${RUSTFS_ROOT_USER}' '${RUSTFS_ROOT_PASSWORD}' >/dev/null 2>&1 \
               && mc mb --ignore-existing store/tempo \
               && echo '✅ Bucket tempo ready'"
       kubectl --context "${CONTEXT_NAME}" -n grafana wait pod/tempo-bucket-init \
           --for=condition=Ready --timeout=60s 2>/dev/null \
           && kubectl --context "${CONTEXT_NAME}" -n grafana logs pod/tempo-bucket-init \
           || echo "  ⚠️  Bucket init may have failed — verify: kubectl run mc ... mc mb store/tempo"
       kubectl --context "${CONTEXT_NAME}" -n grafana delete pod tempo-bucket-init --ignore-not-found

       OBJECTSTORE_IP="${OBJECTSTORE_IP}" envsubst '${OBJECTSTORE_IP}' \
           < "${GIT_REPO_ROOT}/monitoring/tempo/objectstore-bridge.yaml.tpl" \
           | kubectl --context "${CONTEXT_NAME}" apply -f -

       helm_upgrade_install tempo \
           oci://ghcr.io/grafana/helm-charts/tempo-distributed \
           tempo "${CONTEXT_NAME}" "${TEMPO_CHART_VERSION}" \
           --values "${GIT_REPO_ROOT}/monitoring/tempo/tempo-values.yaml" \
           --set "storage.trace.s3.access_key=${RUSTFS_ROOT_USER}" \
           --set "storage.trace.s3.secret_key=${RUSTFS_ROOT_PASSWORD}"

       if [[ ${#REGIONS[@]} -gt 1 ]]; then
           TRAEFIK_IP_DASHED="${TRAEFIK_IP_DASHED}" envsubst '${TRAEFIK_IP_DASHED}' \
               < "${GIT_REPO_ROOT}/monitoring/tempo/ingressroute.yaml.tpl" \
               | kubectl --context "${CONTEXT_NAME}" apply -f -
       fi
   fi
   ```

### D.9 Pin chart version — `scripts/common.sh`

```bash
TEMPO_CHART_VERSION="${TEMPO_CHART_VERSION:-1.x.y}"  # tempo-distributed chart, latest 1.x at apply time
```

### D.10 New file — `monitoring/grafana/grafana_datasource_tempo.yaml`

Hub-region only — same `instanceSelector` pattern as Mimir. Carries trace ↔ logs ↔ metrics jump links.

```yaml
apiVersion: grafana.integreatly.org/v1beta1
kind: GrafanaDatasource
metadata:
  name: tempo
  namespace: grafana
spec:
  instanceSelector:
    matchLabels:
      dashboards: grafana
  allowCrossNamespaceImport: true
  datasource:
    name: DS_TEMPO
    type: tempo
    access: proxy
    url: http://tempo-query-frontend.tempo.svc.cluster.local:3100
    jsonData:
      tracesToLogsV2:
        datasourceUid: loki
        spanStartTimeShift: '-1m'
        spanEndTimeShift: '1m'
        tags:
          - key: service.name
            value: service
          - key: cluster
            value: cluster
        filterByTraceID: true
      tracesToMetrics:
        datasourceUid: mimir
        tags:
          - key: cluster
      serviceMap:
        datasourceUid: mimir
      nodeGraph:
        enabled: true
      lokiSearch:
        datasourceUid: loki
```

### D.11 Patch — `monitoring/grafana/grafana_datasource_loki.yaml`

Append `derivedFields` so Loki auto-links `traceID` strings to Tempo:

```yaml
spec:
  datasource:
    jsonData:
      derivedFields:
        - matcherRegex: '"traceID":"(\w+)"'
          name: TraceID
          url: '$${__value.raw}'
          datasourceUid: tempo
```

### D.12 Patch — `monitoring/grafana/grafana_datasource_mimir.yaml` (from Part B)

Add exemplars destination so Mimir histograms link to Tempo traces:

```yaml
spec:
  datasource:
    jsonData:
      exemplarTraceIdDestinations:
        - name: traceID
          datasourceUid: tempo
```

(Tempo's `metricsGenerator` block in D.3 emits `traces_service_graph_*` and `traces_spanmetrics_*` histograms with `traceID` exemplars to Mimir.)

### D.13 Out-of-scope follow-up

Pre-built Traefik/Tempo dashboard JSON (RED panels, service-graph node panel, traceID-pivot widgets) — flag as next task in `monitoring/README.md`.

---

## Verification

### Part A
```bash
# After teardown + setup
kubectl --context kind-k8s-local get servicemonitor -A | grep -E 'kubelet|kube-controller|kube-scheduler|kube-proxy|kube-etcd|node-exporter|kube-state'

# Port-forward Prometheus
kubectl --context kind-k8s-local -n prometheus-operator port-forward svc/prometheus-operated 9090
# Open http://localhost:9090/targets — expect kubelet, kube-controller-manager, kube-scheduler,
# kube-proxy, kube-etcd, node-exporter, kube-state-metrics ALL UP.
```

### Part B
```bash
# Mimir pods up
kubectl --context kind-k8s-local -n mimir get pods

# RustFS bucket accessible
kubectl --context kind-k8s-local -n mimir run mc --rm -it --image=minio/mc:latest --restart=Never \
  --command -- sh -c "mc alias set s http://objectstore-local:9000 \$RUSTFS_ROOT_USER \$RUSTFS_ROOT_PASSWORD && mc ls s/mimir-blocks"

# Prometheus remote_write working
# Prometheus UI → Status → Remote Write → expect 0 failed samples after a minute.

# Mimir round-trip query
kubectl --context kind-k8s-local -n mimir port-forward svc/mimir-nginx 8080:80
curl -s -H "X-Scope-OrgID: local" 'http://localhost:8080/prometheus/api/v1/query?query=up' | jq '.data.result | length'
# expect: > 0

# Grafana → Mimir datasource → run `up{job="kubelet"}` → results visible
```

Multi-region check: deploy `eu` then `us`, confirm `us` Prometheus's remote_write target shows the hub's sslip.io URL and Mimir's `up` query with `X-Scope-OrgID: us` returns `us` cluster series.

### Part C
```bash
# Force Traefik traffic
curl -s "http://traefik.${TRAEFIK_IP_DASHED}.sslip.io/dashboard/" >/dev/null

# Grafana → Loki Explore:
#   {app="traefik", status=~"2.."}    → expect access-log lines
#   {app="traefik", method="GET"}     → method label promoted
#   topk(5, sum by (route) (rate({app="traefik"}[1m])))

# Confirm Traefik pods are NOT also coming through system_logs pipeline:
#   {namespace="traefik", app!="traefik"}    → empty (Alloy drop rule working)
```

### Part D
```bash
kubectl --context kind-k8s-local -n tempo get pods    # all up

# RustFS bucket reachable
kubectl --context kind-k8s-local -n tempo run mc --rm -it --image=minio/mc:latest --restart=Never \
  --command -- sh -c "mc alias set s http://objectstore-local:9000 \$RUSTFS_ROOT_USER \$RUSTFS_ROOT_PASSWORD && mc ls s/tempo"

# Force traced traffic
for i in $(seq 1 50); do curl -s "http://traefik.${TRAEFIK_IP_DASHED}.sslip.io/dashboard/" >/dev/null; done

# Grafana → Tempo → Search → Service Name: traefik-local → expect spans
# Click span → "Logs for this span" → Loki query auto-filtered by traceID
# In Loki line, click TraceID derived field → opens Tempo trace view
# In Mimir, query `traces_spanmetrics_latency_bucket` → exemplar marker on histogram → click → Tempo
```

Multi-region check: `eu` and `us` Traefik show OTLP HTTP push to `tempo-otlp.<hub>.sslip.io`; hub Tempo Search lists `service.name=traefik-eu` and `traefik-us` with `cluster` resource attribute.

---

## Risks / Watchpoints

| Risk | Mitigation |
|---|---|
| `kubeadmConfigPatches` ignored by older kind images | Document required kind ≥ v0.20 / kindest/node ≥ v1.27. |
| etcd 2381 unauthenticated HTTP exposure | Document in `monitoring/README.md`; acceptable for local playground. |
| Mimir chart version drift breaks `structuredConfig` schema | Pin `MIMIR_CHART_VERSION` in `scripts/common.sh`; revalidate on bumps. |
| RustFS bucket auto-creation | Mimir does **not** auto-create buckets. `setup.sh` must run a `mc mb mimir-blocks/mimir-alertmanager/mimir-ruler` step (mirror the Loki bucket-init pattern). |
| Cross-region push hits Traefik HTTP only | Acceptable for playground; for HTTPS, route through the existing wildcard cert pattern from `vault-pki` work. |
| Prometheus + Mimir double-store doubles disk | Tune Prom retention down (e.g. `retention: 6h`) once Mimir flow proven. |
| Hub-region Traefik IP changes between rebuilds | `setup.sh` recomputes via `get_traefik_lb_ip` on every run; non-hub regions get fresh URL. |
| Single-replica ingester loses data on restart | Acceptable for playground; documented. |
| Traefik 3.3 OTLP flag schema differs across chart versions | Pin `TEMPO_CHART_VERSION` and validate `tracing.otlp.{grpc,http}` shape via `helm show values` before bumping. |
| RustFS `tempo` bucket auto-creation | `monitoring/setup.sh` runs `mc mb store/tempo` (mirrors loki-bucket-init pattern). |
| 100% sampling on bursty traffic floods Tempo ingester | Document tunable `tracing.sampleRate` in `monitoring/README.md`; default acceptable for playground. |
| `RouterName` cardinality if many routes added | Acceptable initially; flag in `monitoring/README.md` if route count > ~50. |
| Non-hub Traefik installed before hub Tempo IngressRoute exists | `monitoring/setup.sh` issues `helm upgrade` reapply on non-hub Traefik post-hub-install (D.8 step 2). |
| Traefik access logs leak query-string secrets | `monitoring/README.md` PII note (C.4); Traefik does not strip URL params. |
| Tempo `metricsGenerator` adds tenant `tempo` to Mimir | Already enabled by Mimir `multitenancy_enabled: true` (Part B B.3); harmless. |
| Hub Traefik IP changes between rebuilds → non-hub OTLP HTTP target stale | `monitoring/setup.sh` recomputes via `get_traefik_lb_ip` + helm-upgrade reapply on every run. |
| Alloy `traefik_access` pipeline misclassifies non-JSON Traefik runtime logs | `stage.json` failure passes line through unmodified — runtime logs still reach Loki untagged via `traefik_access` stream; document in `monitoring/README.md`. |

---

## File-level Changeset Summary

### Modify
- `k8s/kind-cluster.yaml.tpl`
- `k8s/kind-cluster.yaml`
- `monitoring/kube-prometheus-stack-values.yaml`  *(adds `kubeEtcd` block)*
- `monitoring/prometheus-instance/deploy_prometheus.yaml` → rename to `.tpl`
- `monitoring/prometheus-instance/kustomization.yaml`  *(drop the file from kustomize; setup.sh now templates it)*
- `monitoring/setup.sh`  *(hub region selection, Mimir install, Tempo install + bucket init, push-URL substitution, non-hub Traefik reapply)*
- `monitoring/grafana/kustomization.yaml`  *(add Mimir + Tempo datasources on hub)*
- `monitoring/grafana/grafana_datasource_loki.yaml`  *(add `derivedFields` → tempo)*
- `monitoring/grafana/grafana_datasource_mimir.yaml`  *(add `exemplarTraceIdDestinations` → tempo)* *(file itself created in Part B)*
- `monitoring/README.md`  *(security note on etcd 2381, Mimir resource ownership row, Tempo resource ownership row, access-log PII note, sampling tune note, RouterName cardinality note)*
- `scripts/common.sh`  *(add `MIMIR_CHART_VERSION`, `TEMPO_CHART_VERSION`)*
- `scripts/setup.sh`  *(Traefik install adds tracing `--set` args — gRPC for hub, none initially for non-hub)*
- `traefik/values.yaml`  *(accessLog JSON block + base tracing block)*
- `monitoring/alloy/alloy-config.river`  *(traefik_access pipeline + Traefik drop in `all_pods` relabel)*

### Create
- `monitoring/mimir/mimir-values.yaml`
- `monitoring/mimir/objectstore-bridge.yaml.tpl`
- `monitoring/mimir/ingressroute.yaml.tpl`
- `monitoring/mimir/kustomization.yaml`
- `monitoring/grafana/grafana_datasource_mimir.yaml`
- `monitoring/tempo/tempo-values.yaml`
- `monitoring/tempo/objectstore-bridge.yaml.tpl`
- `monitoring/tempo/ingressroute.yaml.tpl`
- `monitoring/tempo/kustomization.yaml`
- `monitoring/grafana/grafana_datasource_tempo.yaml`

### Reused utilities (existing)
- `helm_upgrade_install`, `get_cluster_context`, `get_cluster_name` — `scripts/common.sh`
- `get_traefik_lb_ip`, `ip_to_dashed` — `scripts/common.sh`
- `detect_running_regions` — `scripts/funcs_regions.sh`
- `RUSTFS_BASE_NAME`, `RUSTFS_ROOT_USER`, `RUSTFS_ROOT_PASSWORD` — `scripts/common.sh`
- `objectstore-local` Service+Endpoints pattern — `monitoring/setup.sh` (Loki section)

---

## Suggested Commit Sequence

1. **Commit 1** — `feat(kind): expose control-plane metrics on 0.0.0.0`
   Touches: `k8s/kind-cluster.yaml{,.tpl}`, `monitoring/kube-prometheus-stack-values.yaml`, `monitoring/README.md`.
   Validation: full teardown+setup, all Prometheus targets UP.

2. **Commit 2** — `feat(monitoring): add Mimir hub for long-term metrics storage`
   Touches: `monitoring/mimir/*` (new), `monitoring/prometheus-instance/deploy_prometheus.yaml{→.tpl}`, `monitoring/setup.sh`, `scripts/common.sh`.
   Validation: Mimir pods up, Prometheus remote_write succeeding, RustFS `mimir-blocks` populated.

3. **Commit 3** — `feat(monitoring): add Mimir datasource to Grafana hub`
   Touches: `monitoring/grafana/grafana_datasource_mimir.yaml` (new), `monitoring/grafana/kustomization.yaml`.
   Validation: Grafana shows Mimir datasource; PromQL queries return cluster-wide data.

4. **Commit 4** — `feat(monitoring): traefik JSON access logs parsed by alloy into loki`
   Touches: `traefik/values.yaml`, `monitoring/alloy/alloy-config.river`, `monitoring/README.md`.
   Validation: Grafana Loki Explore — `{app="traefik", status=~"2.."}` returns rows; `method`/`route` labels populated; Traefik pods absent from `system_logs` stream.

5. **Commit 5** — `feat(monitoring): tempo + traefik OTLP tracing with cross-signal correlation`
   Touches: `monitoring/tempo/*` (new), `monitoring/grafana/grafana_datasource_tempo.yaml` (new), patches to `_loki.yaml`, `_mimir.yaml`, `kustomization.yaml`, `traefik/values.yaml`, `scripts/setup.sh`, `monitoring/setup.sh`, `scripts/common.sh`.
   Validation: Tempo Search lists Traefik spans; Loki line traceID → Tempo trace; Tempo span → Loki logs; Mimir histogram exemplar → Tempo trace.

---

## Out of Scope

- HTTPS for cross-region remote_write / OTLP (uses Vault PKI / Traefik TLS wildcard later)
- Mimir multi-tenant Grafana org_mapping integration with Dex
- Alertmanager rules and routing
- Mimir ruler federation
- OTLP gRPC cross-region passthrough — uses HTTP/4318 instead; gRPC kept in-cluster only
- Tail-based sampling at otel-collector (chosen design has no collector)
- Application-level instrumentation beyond Traefik (CNPG, pgBouncer, Vault tracing)
- Pre-built Traefik trace dashboard JSON (RED panels, service-graph, traceID widgets) — flag in `monitoring/README.md` as next task
- Replacing the existing Prometheus datasource (kept for fast local queries)
