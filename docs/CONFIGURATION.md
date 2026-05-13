<!-- generated-by: gsd-doc-writer -->
# Configuration Reference

This document covers every configurable knob in the cnpg-playground. All configuration is done through shell environment variables (overriding defaults in `scripts/common.sh`) and Helm values files. There are no `.env` files — defaults are coded directly in `scripts/common.sh` and can be overridden by exporting variables before running any setup script.

---

## Table of Contents

1. [Base Environment](#base-environment)
2. [Kind Cluster (Kubernetes)](#kind-cluster-kubernetes)
3. [Component Versions](#component-versions)
4. [Monitoring Stack](#monitoring-stack)
5. [Vault & PKI](#vault--pki)
6. [Dex OIDC](#dex-oidc)
7. [External Secrets Operator (ESO)](#external-secrets-operator-eso)
8. [CNPG Clusters](#cnpg-clusters)
9. [Ingress (Traefik / sslip.io)](#ingress-traefik--sslipio)

---

## Base Environment

All defaults live in `scripts/common.sh`. Export any variable before running `scripts/setup.sh` to override it.

### Region Selection

`scripts/setup.sh` accepts region names as positional arguments. With no arguments, it defaults to `eu` and `us`.

```bash
# Default — two regions
./scripts/setup.sh

# Single region (local-only, no cross-cluster replication)
./scripts/setup.sh local

# Custom regions
./scripts/setup.sh eu us ap
```

The first region in the list is the **hub** — it hosts Mimir, Tempo, Loki, and the OTel Collector. All other regions are spokes that ship metrics/traces to the hub.

| Variable | Default | Description |
|---|---|---|
| `K8S_BASE_NAME` | `k8s-` | Prefix for kind cluster names (e.g., `k8s-eu`) |
| `K8S_CONTEXT_PREFIX` | `kind-` | Prefix for kubeconfig context names (e.g., `kind-k8s-eu`) |

### RustFS Object Storage

One RustFS container per region acts as an S3-compatible object store for CNPG WAL archiving and monitoring backends.

| Variable | Default | Description |
|---|---|---|
| `RUSTFS_IMAGE` | `rustfs/rustfs:latest` | Container image for RustFS |
| `RUSTFS_BASE_NAME` | `objectstore` | Container name prefix (e.g., `objectstore-eu`) |
| `RUSTFS_BASE_PORT` | `9001` | Host port for the first region's RustFS console; incremented by 1 per region |
| `RUSTFS_ROOT_USER` | `cnpg` | S3 access key ID (written as a Kubernetes Secret to all clusters) |
| `RUSTFS_ROOT_PASSWORD` | `Cl0udNativePGRocks` | S3 secret access key |

---

## Kind Cluster (Kubernetes)

The Kind cluster topology is defined in `k8s/kind-cluster.yaml.tpl` and rendered by `scripts/setup.sh` before use. One cluster is created per region.

### Node Layout

Each cluster has **7 nodes**:

| Role | Count | Node label | Taint |
|---|---|---|---|
| control-plane | 1 | — | — |
| infra worker | 2 | `infra.node.kubernetes.io` | — |
| app worker | 1 | `app.node.kubernetes.io` | — |
| postgres worker | 3 | `postgres.node.kubernetes.io` | `node-role.kubernetes.io/postgres:NoSchedule` |

All monitoring components (`nodeSelector: node-role.kubernetes.io/infra: ""`) run on the infra workers. CNPG pods are scheduled exclusively on postgres workers via affinity and taint.

### OIDC / kube-apiserver

The control-plane is configured at cluster creation to trust Dex as an OIDC issuer. Template variables used:

| Variable | Resolved by | Description |
|---|---|---|
| `DEX_HOST` | `scripts/dex-setup.sh` | Dex HTTPS hostname (`dex.<HOST_IP_DASHED>.sslip.io`) |
| `DEX_PORT` | `common.sh` default: `5556` | Dex HTTPS port |
| `DEX_TLS_DIR` | `scripts/dex-setup.sh` | Host path to Dex CA cert (mounted into control-plane) |

Fixed OIDC settings (not configurable without re-creating clusters):

- `oidc-client-id: kubernetes`
- `oidc-username-claim: email` (prefix `oidc:`)
- `oidc-groups-claim: groups` (prefix `oidc:`)

### MetalLB IP Allocation

MetalLB assigns LoadBalancer IPs from the kind Docker network. The IP range is computed automatically per region to avoid conflicts:

- `/24` network: fourth octet range `200–224` for region 0, `225–249` for region 1, etc.
- `/16` network: third octet varies per region (255, 254, …); fourth octet range `200–250`.

The first IP in each range is used as the Traefik LoadBalancer IP and determines all sslip.io hostnames for that region.

---

## Component Versions

All chart and image versions are pinned in `scripts/common.sh` and can be overridden by environment variable.

| Variable | Default | Component |
|---|---|---|
| `METALLB_CHART_VERSION` | `0.15.3` | MetalLB Helm chart |
| `CERT_MANAGER_CHART_VERSION` | `v1.20.2` | cert-manager Helm chart |
| `ESO_CHART_VERSION` | `2.4.1` | External Secrets Operator Helm chart |
| `TRAEFIK_CHART_VERSION` | `39.0.8` | Traefik Helm chart |
| `TRAEFIK_IMAGE` | `traefik:v3.3` | Traefik container image |
| `CNPG_CHART_VERSION` | `0.28.0` | CloudNativePG operator Helm chart |
| `BARMAN_CLOUD_PLUGIN_CHART_VERSION` | `0.6.0` | Barman Cloud plugin Helm chart |
| `GRAFANA_OPERATOR_CHART_VERSION` | `5.22.2` | Grafana Operator Helm chart |
| `KUBE_PROMETHEUS_STACK_CHART_VERSION` | `83.6.0` | kube-prometheus-stack Helm chart |
| `LOKI_CHART_VERSION` | `13.5.0` | Loki Helm chart |
| `ALLOY_CHART_VERSION` | `1.8.0` | Grafana Alloy Helm chart |
| `MIMIR_CHART_VERSION` | `5.7.0` | Mimir distributed Helm chart |
| `TEMPO_CHART_VERSION` | `2.19.0` | Tempo distributed Helm chart |
| `OTEL_COLLECTOR_CHART_VERSION` | `0.153.0` | OpenTelemetry Collector Helm chart |
| `OTEL_COLLECTOR_IMAGE_TAG` | `0.151.0` | `otel/opentelemetry-collector-contrib` image tag |
| `DEX_IMAGE` | `ghcr.io/dexidp/dex:v2.45.1` | Dex container image |
| `VAULT_IMAGE` | `hashicorp/vault:2.0` | HashiCorp Vault container image |

---

## Monitoring Stack

### kube-prometheus-stack

**Values file:** `monitoring/kube-prometheus-stack-values.yaml`

Prometheus, Grafana, and Alertmanager are disabled — their functions are replaced by Mimir, Grafana Operator, and Mimir Alertmanager. The operator itself (for ServiceMonitor/PodMonitor CRD management), kube-state-metrics, node-exporter, and all kube component scrapers remain enabled.

Notable settings:

| Setting | Value | Notes |
|---|---|---|
| `prometheus.enabled` | `false` | Replaced by Mimir |
| `grafana.enabled` | `false` | Replaced by Grafana Operator |
| `alertmanager.enabled` | `false` | Replaced by Mimir Alertmanager |
| `kubeEtcd.service.port` | `2381` | Matches the etcd `listen-metrics-urls` in the kind cluster config |
| `prometheus-node-exporter.tolerations` | `operator: Exists` | Ensures node-exporter covers all nodes including control-plane |

### Mimir (hub only)

**Values file:** `monitoring/mimir/mimir-values.yaml`

Deployed only to the hub (first) region. All regions remote-write metrics to Mimir.

**Storage backend** (RustFS / S3):

| Setting | Value |
|---|---|
| `common.storage.backend` | `s3` |
| `common.storage.s3.endpoint` | `objectstore-local.mimir.svc.cluster.local:9000` |
| `common.storage.s3.region` | `us-east-1` |
| `blocks_storage.s3.bucket_name` | `mimir-blocks` |
| `alertmanager_storage.s3.bucket_name` | `mimir-alertmanager` |
| `ruler_storage.s3.bucket_name` | `mimir-ruler` |

S3 credentials (`access_key_id`, `secret_access_key`) are injected at install time via `--set` using the `RUSTFS_ROOT_USER` / `RUSTFS_ROOT_PASSWORD` values.

**Multi-tenancy:**

| Setting | Value |
|---|---|
| `multitenancy_enabled` | `true` |
| `tenant_federation.enabled` | `true` |
| `runtime_config.file` | `/var/mimir/runtime.yaml` |
| `runtime_config.reload_period` | `10s` |

**Tenant configuration** (`monitoring/mimir/runtime-config.yaml` / `mimir-values.yaml runtimeConfig`):

One entry per region is required. Adding a region requires updating `mimir-values.yaml` under `runtimeConfig.overrides`.

| Tenant | `max_global_series_per_user` | `max_query_lookback` | `ingestion_rate` | `query_federation.allowed_tenants` |
|---|---|---|---|---|
| `local` | 500000 | 30d | 100000 | `[local, eu, us, tempo]` |
| `eu` | 500000 | 30d | 100000 | `[local, eu, us, tempo]` |
| `us` | 500000 | 30d | 100000 | `[local, eu, us, tempo]` |
| `tempo` | 200000 | 7d | 50000 | `[tempo]` |

To add a new region tenant: add an entry to `runtimeConfig.overrides` in `mimir-values.yaml`, and add the new tenant to all existing tenants' `query_federation.allowed_tenants` lists.

**Global limits:**

| Setting | Value |
|---|---|
| `limits.ingestion_rate` | 100000 |
| `limits.ingestion_burst_size` | 200000 |

**Ruler / Alertmanager:**

| Setting | Value |
|---|---|
| `ruler.alertmanager_url` | `http://mimir-alertmanager.mimir.svc.cluster.local:8080/alertmanager` |
| `ruler.poll_interval` | `1m` |
| `ruler.evaluation_interval` | `1m` |

**Replica counts** (all pinned to 1 for playground footprint):

All components (distributor, ingester, querier, query_frontend, query_scheduler, store_gateway, compactor, ruler, alertmanager, overrides_exporter, nginx) run as single replicas.

**Persistent volume sizes:**

| Component | PV size |
|---|---|
| ingester | 5Gi |
| store_gateway | 5Gi |
| compactor | 5Gi |
| alertmanager | 1Gi |

**Alertmanager config** (`monitoring/mimir/alertmanager-config.yaml.tpl`):

The Alertmanager fallback config is rendered at install time. To enable Slack notifications, set:

| Variable | Default | Description |
|---|---|---|
| `SLACK_WEBHOOK_URL` | `https://hooks.slack.com/services/INVALID/INVALID/INVALID` | Slack incoming webhook URL for critical/warning alerts |

Without a real webhook URL, alerts route to the `null-default` receiver (silently dropped).

### Tempo (hub only)

**Values file:** `monitoring/tempo/tempo-values.yaml`

**Storage backend:**

| Setting | Value |
|---|---|
| `storage.trace.backend` | `s3` |
| `storage.trace.s3.bucket` | `tempo` |
| `storage.trace.s3.endpoint` | `objectstore-local.tempo.svc.cluster.local:9000` |

S3 credentials injected at install via `--set`.

**Metrics generator** (span metrics → Mimir):

| Setting | Value |
|---|---|
| remote_write URL | `http://mimir-nginx.mimir.svc.cluster.local/api/v1/push` |
| `X-Scope-OrgID` header | `tempo` |
| processors | `service-graphs`, `span-metrics`, `local-blocks` |

**OTLP receivers:** gRPC (`:4317`) and HTTP (`:4318`) both enabled.

**Ingester replication factor:** 1 (single-node playground; avoids "at least 2 live replicas required" error).

**Persistence:** 5Gi for ingester.

### Loki

**Values file:** `monitoring/loki/loki-values.yaml`

Runs in `SingleBinary` deployment mode with 1 replica.

| Setting | Value |
|---|---|
| S3 endpoint | `http://objectstore-local.grafana.svc.cluster.local:9000` |
| S3 bucket (chunks, ruler, admin) | `loki` |
| `auth_enabled` | `false` |
| `replication_factor` | `1` |
| `retention_period` | `3d` |
| `ingestion_rate_mb` | `32` |
| `ingestion_burst_size_mb` | `64` |
| Schema version | `v13` (tsdb, from `2024-01-01`) |
| Persistence size | `20Gi` |

### Grafana Alloy

**Values file:** `monitoring/alloy/alloy-values.yaml`
**Config template:** `monitoring/alloy/alloy-config.river.tpl`

Alloy runs as a single-replica Deployment on infra nodes. Its River config is rendered at install time by `monitoring/setup.sh` using `envsubst`.

Template variables substituted at install time:

| Variable | Source | Description |
|---|---|---|
| `MIMIR_PUSH_URL` | computed by `monitoring/setup.sh` | Mimir remote_write endpoint for this region |
| `MIMIR_RULER_URL` | computed by `monitoring/setup.sh` | Mimir Ruler endpoint for PrometheusRule sync |
| `REGION` | region loop variable | Tenant ID sent as `X-Scope-OrgID` header |
| `SCRAPE_NAMESPACES_RIVER` | `get_scrape_namespaces()` | River array of namespaces with `monitoring/scrape=enabled` label |

For hub regions, URLs are in-cluster (`mimir-nginx.mimir.svc.cluster.local`). For spoke regions, URLs are external via sslip.io IngressRoutes on the hub.

**Metric allowlist** (write_relabel_config keep regex):

```
(up|scrape_.*|kube_.*|node_.*|kubelet_.*|container_.*|machine_.*|apiserver_.*|cnpg_.*|pg_.*|traces_.*|process_.*|go_.*)
```

**Log pipelines:**

- CNPG pod logs → pgaudit field extraction → Loki
- All other pod logs → Loki (CNPG and Traefik excluded from this pipeline)
- Traefik access logs (JSON) → field promotion (method, status, route) → Loki
- Kubernetes events → Loki

### OTel Collector (hub only)

**Values file:** `monitoring/otel-collector/otel-collector-values.yaml`

Single-replica deployment (tail sampling requires all spans for a trace on the same instance). Deployed to the `otel` namespace on the hub cluster.

| Setting | Value |
|---|---|
| Image | `otel/opentelemetry-collector-contrib` |
| Image tag | `OTEL_COLLECTOR_IMAGE_TAG` (default: `0.151.0`) |
| gRPC receiver | `0.0.0.0:4317` |
| HTTP receiver | `0.0.0.0:4318` |
| OTLP exporter | `tempo-distributor.tempo.svc.cluster.local:4317` |

**Tail sampling policy:**

| Policy | Type | Threshold |
|---|---|---|
| `errors-policy` | status_code | `ERROR` status codes |
| `slow-traces-policy` | latency | `>= 500ms` |
| `probabilistic-sample-policy` | probabilistic | `10%` of healthy fast traces |

Other tail sampling settings:

| Setting | Value |
|---|---|
| `decision_wait` | `10s` |
| `num_traces` | `1000` |
| `expected_new_traces_per_sec` | `10` |
| `batch.send_batch_size` | `1000` |
| `batch.timeout` | `5s` |

**Resources:**

| Limit | Value |
|---|---|
| Memory limit | `512Mi` |
| CPU limit | `500m` |
| Memory request | `256Mi` |
| CPU request | `100m` |

### Grafana

Deployed via Grafana Operator. Default credentials:

| Setting | Value |
|---|---|
| Admin username | `admin` |
| Admin password | `admin` |

Change the password in `monitoring/grafana/grafana_instance.yaml` under `spec.config.security.admin_password` before applying, or after first login via the Grafana UI.

---

## Vault & PKI

Vault runs as a single container in **dev mode** with persistent file storage and auto-generated TLS.

### Container configuration

**Config file:** `vault/config/vault-config.hcl`

| Setting | Value |
|---|---|
| Storage backend | `file` at `/vault/data` |
| HTTP listener address | `0.0.0.0:8202` |
| TLS on HTTP listener | disabled (`tls_disable = 1`) |
| `cluster_addr` | `https://127.0.0.1:8201` |
| `disable_mlock` | `true` |
| Log level | `info` |
| Log file | `/vault/logs/vault.log` |

### Ports and env variables

| Variable | Default | Description |
|---|---|---|
| `VAULT_IMAGE` | `hashicorp/vault:2.0` | Vault container image |
| `VAULT_CONTAINER_NAME` | `vault` | Container name |
| `VAULT_PORT` | `8200` | HTTPS (dev-tls) port — host-mapped; used by Vault CLI |
| `VAULT_HTTP_PORT` | `8202` | HTTP (no TLS) port — used by cert-manager and ESO inside the kind network |
| `VAULT_ADMIN_USER` | `vault-admin` | Userpass admin username |
| `VAULT_ADMIN_PASSWORD` | `admin-password-123` | Userpass admin password |

The auto-generated root token and unseal key are stored at `vault/.root_token` and `vault/.unseal_key` (root-owned, mode 600).

### Vault CLI access

```bash
export VAULT_ADDR="https://127.0.0.1:8200"
export VAULT_TOKEN="$(sudo cat vault/.root_token)"
export VAULT_CACERT="vault/certs/vault-ca.pem"
vault status
```

### Vault PKI

Set up by `scripts/vault-pki-setup.sh`. Creates:
- Root CA (`pki` mount)
- Intermediate CA (`pki_int` mount)
- PKI roles: `dex-server` (for Dex TLS cert), `k8s-server` (for cluster certificates)

AppRole credentials for cert-manager are written to `vault/.approle_role_id` and `vault/.approle_secret_id` (root-owned, mode 600) and then created as Kubernetes Secrets in the `cert-manager` namespace of each cluster.

### ClusterIssuer (cert-manager)

**Template:** `vault/cert-manager/clusterissuer.yaml.tpl`

| Template variable | Source | Description |
|---|---|---|
| `VAULT_HTTP_PORT` | `common.sh` | Port 8202 (HTTP, no-TLS, accessible from inside kind network) |
| `VAULT_APPROLE_ROLE_ID` | `vault/.approle_role_id` | AppRole role ID for cert-manager |

### ESO Vault backend

Set up by `scripts/vault-eso-setup.sh`. Creates:

- KV v2 mount at path `cnpg/`
- Policy `eso-cnpg`: read-only access to `cnpg/data/*` and `cnpg/metadata/*`

**ClusterSecretStore template:** `vault/eso/clustersecretstore.yaml.tpl`

| Template variable | Value | Description |
|---|---|---|
| `VAULT_HTTP_PORT` | `8202` | Vault HTTP port |
| `ESO_NAMESPACE` | `external-secrets` (default) | Namespace where ESO credentials Secret lives |

The ClusterSecretStore uses AppRole auth. Credentials are in the `vault-approle-creds` Secret in the `external-secrets` namespace. One AppRole per region is created by `scripts/eso-setup.sh`.

---

## Dex OIDC

Dex runs as a single container providing OIDC for Vault and Grafana (`grafana-rbr-ver` instance).

### Container env variables

All resolved from `scripts/common.sh` defaults:

| Variable | Default | Description |
|---|---|---|
| `DEX_IMAGE` | `ghcr.io/dexidp/dex:v2.45.1` | Dex container image |
| `DEX_CONTAINER_NAME` | `dex` | Container name |
| `DEX_PORT` | `5556` | HTTPS port |
| `DEX_OIDC_CLIENT_ID` | `vault-client` | OAuth2 client ID for Vault |
| `DEX_OIDC_CLIENT_SECRET` | `vault-oidc-secret` | OAuth2 client secret for Vault |
| `DEX_GRAFANA_RBR_VER_CLIENT_SECRET` | `grafana-rbr-ver-demo-secret` | OAuth2 client secret for Grafana rbr-ver |

### Static users (config template: `dex/config/dex-config.yaml.tpl`)

Password hashes are bcrypt. The default for all users (except where overridden) is the value of `DEX_STATIC_PASSWORD_HASH`.

| Variable | Default | User |
|---|---|---|
| `DEX_STATIC_PASSWORD_HASH` | `$2a$10$2b2cu...` (bcrypt of `password`) | `user@example.com` |
| `DEX_RBR_ADMIN_PASSWORD_HASH` | same as above | `rbr-admin@example.com` (groups: `rbr-db-admin`, `rbr-ver-db-admin`) |
| `DEX_RBR_VER_ADMIN_PASSWORD_HASH` | same as above | `rbr-ver-admin@example.com` (groups: `rbr-ver-db-admin`) |
| `DEX_UNRELATED_PASSWORD_HASH` | same as above | `unrelated@example.com` (no groups) |

Override any hash by exporting the variable before setup, e.g.:

```bash
export DEX_STATIC_PASSWORD_HASH="$(htpasswd -bnBC 10 "" mynewpassword | tr -d ':\n')"
```

The Dex issuer URL is dynamically resolved to `https://dex.<HOST_IP_DASHED>.sslip.io:5556/dex` where `HOST_IP_DASHED` is derived from the host's primary IP.

---

## External Secrets Operator (ESO)

**Chart version:** `ESO_CHART_VERSION` (default `2.4.1`)
**Namespace:** `ESO_NAMESPACE` (default `external-secrets`)

| Variable | Default | Description |
|---|---|---|
| `ESO_VERSION` | `v2.4.1` | ESO version label (informational; chart version controlled by `ESO_CHART_VERSION`) |
| `ESO_NAMESPACE` | `external-secrets` | Kubernetes namespace |
| `CNPG_DEMO_NAMESPACE` | `demo-local-db` | Namespace for the ESO-backed CNPG cluster demo |

One `ClusterSecretStore` named `vault-approle` is created per cluster, pointing to the Vault HTTP endpoint inside the kind network. AppRole credentials are provisioned per-region by `scripts/eso-setup.sh`.

Vault secrets for CNPG are stored under the `cnpg/` KV v2 mount. The ESO demo uses ExternalSecrets in `demo/yaml/local/` to populate:
- `pg-local-superuser` — superuser credentials
- `pg-local-app` — application user credentials
- `pg-local-readonly` — read-only role credentials

---

## CNPG Clusters

### Cluster topology

Three demo CNPG clusters are provided, one per region:

| File | Cluster name | Region | Replicas | Storage (data + WAL) |
|---|---|---|---|---|
| `demo/yaml/local/pg-local.yaml` | `pg-local` | hub (local) | 3 | 1Gi + 1Gi |
| `demo/yaml/eu/pg-eu.yaml` | `pg-eu` | eu | 3 | 1Gi + 1Gi |
| `demo/yaml/us/pg-us.yaml` | `pg-us` | us | 3 | 1Gi + 1Gi |

All clusters use `ghcr.io/cloudnative-pg/postgresql:18-standard-trixie`.

### PostgreSQL parameters (same for all clusters)

| Parameter | Value |
|---|---|
| `max_connections` | `100` |
| `log_checkpoints` | `on` |
| `log_lock_waits` | `on` |
| `pg_stat_statements.max` | `10000` |
| `pg_stat_statements.track` | `all` |
| `hot_standby_feedback` | `on` |
| `shared_memory_type` | `sysv` |
| `dynamic_shared_memory_type` | `sysv` |

### Backup schedule

All clusters run a `ScheduledBackup` at `0 0 0 * * *` (midnight UTC daily) using the `barman-cloud.cloudnative-pg.io` plugin. The `objectstore-*` ObjectStore CR in the same namespace points to the region's RustFS instance at `http://objectstore-local:9000` with WAL compression: `gzip`.

### PgBouncer pooler

A `Pooler` (`type: rw`, `poolMode: session`) is deployed alongside `pg-local`:

| Setting | Value |
|---|---|
| `instances` | `2` |
| `max_client_conn` | `1000` |
| `default_pool_size` | `10` |

### Custom metrics

`demo/yaml/local/cnpg-custom-metrics-configmap.yaml` defines additional Prometheus queries scraped by the CNPG exporter. The ConfigMap must carry the label `cnpg.io/reload: ""` and be in the same namespace as the Cluster CR. Queries defined:

| Metric | Description |
|---|---|
| `cnpg_cnpg-custom-metrics_pg_replication_lag_lag_seconds` | Replication lag in seconds (0 on primary) |
| `cnpg_cnpg-custom-metrics_pg_stat_connections_total` | Connections by state |
| `cnpg_cnpg-custom-metrics_pg_database_size_bytes` | Database size in bytes (primary only) |
| `cnpg_cnpg-custom-metrics_pg_long_running_queries_count` | Queries running > 30s (primary only) |

### Monitoring

CNPG clusters set `enablePodMonitor: false` to avoid per-cluster PodMonitor creation. Instead, three wildcard PodMonitors in `monitoring/cnpg/` cover all CNPG pods cluster-wide:

- `cnpg-operator-podmonitor.yaml` — CNPG operator
- `cnpg-cluster-wildcard-podmonitor.yaml` — all Cluster instance pods
- `cnpg-pooler-wildcard-podmonitor.yaml` — all Pooler pods

---

## Ingress (Traefik / sslip.io)

### Traefik configuration

**Values file:** `traefik/values.yaml`

| Setting | Value |
|---|---|
| `service.type` | `LoadBalancer` |
| `providers.kubernetesCRD.allowCrossNamespace` | `true` |
| `logs.access.enabled` | `true` (JSON format) |
| `logs.access.fields.headers.defaultmode` | `drop` (PII — only `User-Agent` and `X-Forwarded-For` kept) |
| `tracing.sampleRate` | `1.0` (100% — reduce for production) |
| Additional entrypoint | `postgres` on port `5432` (TCP) |

**Resources:**

| | Value |
|---|---|
| CPU request | `100m` |
| Memory request | `64Mi` |
| Memory limit | `128Mi` |

### Tracing endpoint

Set at Helm install time by `scripts/setup.sh` and `monitoring/setup.sh`:

- **Hub region:** gRPC to `otel-collector-opentelemetry-collector.otel.svc.cluster.local:4317` (in-cluster)
- **Spoke regions:** HTTP to `http://otel-push.<HUB_TRAEFIK_IP_DASHED>.sslip.io/v1/traces` (via hub IngressRoute)

The `tracing.serviceName` is set to `traefik-<region>` and `tracing.resourceAttributes.cluster` is set to `<region>`.

### sslip.io hostname pattern

All services are exposed using sslip.io wildcard DNS. The pattern is:

```
<service>.<TRAEFIK_IP_DASHED>.sslip.io
```

Where `TRAEFIK_IP_DASHED` is the MetalLB-assigned LoadBalancer IP with dots replaced by dashes (e.g., `172-18-255-200`).

Examples for the hub region:

| Service | Hostname |
|---|---|
| Grafana | `grafana.<HUB_IP_DASHED>.sslip.io` |
| Mimir push | `mimir-push.<HUB_IP_DASHED>.sslip.io` |
| Mimir query | `mimir-query.<HUB_IP_DASHED>.sslip.io` |
| Mimir ruler | `mimir-ruler.<HUB_IP_DASHED>.sslip.io` |
| Mimir alertmanager | `mimir-am.<HUB_IP_DASHED>.sslip.io` |
| OTel push | `otel-push.<HUB_IP_DASHED>.sslip.io` |
| Traefik dashboard | `traefik.<TRAEFIK_IP_DASHED>.sslip.io` (HTTPS) |
| Dex | `dex.<HOST_IP_DASHED>.sslip.io:5556` (host network) |

<!-- VERIFY: exact sslip.io hostnames depend on MetalLB IP assignment at runtime and cannot be determined statically -->

TLS for the Traefik dashboard is issued from the Vault intermediate CA via cert-manager (`ClusterIssuer: vault-pki`).

---

## Namespace scrape labeling

Alloy and `mimir.rules.kubernetes` only scrape namespaces labeled with:

```
monitoring/scrape=enabled
```

The `label_namespace_for_scrape` function in `scripts/funcs_namespace_scrape_label.sh` applies this label. `scripts/setup.sh` and `monitoring/setup.sh` call it for every component namespace at install time. To add a custom namespace to the scrape scope:

```bash
kubectl label namespace <my-namespace> monitoring/scrape=enabled
```
