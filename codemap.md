# Repository Atlas: cnpg-playground

## Project Responsibility

A local learning environment for **CloudNativePG** (CNPG) — the PostgreSQL operator for Kubernetes. Uses Docker/Kind to create simulated multi-region Kubernetes clusters with PostgreSQL distributed across them, backed by S3-compatible object storage (RustFS), HashiCorp Vault for secrets management, Dex for OIDC authentication, and a full observability stack (Prometheus, Grafana, Loki, Mimir, Tempo).

The **`local` region** is the primary learning environment — a single-region standalone setup ideal for experimentation. The `eu` and `us` regions provide a multi-region distributed topology with cross-region replication. All three regions (`local`, `eu`, `us`) are first-class; `local` is not in the default `REGIONS` array but is fully supported and is the required region for ESO/self-service demos.

## System Entry Points

| Entry Point | Purpose |
|-------------|---------|
| `scripts/setup.sh` | Main bootstrap: creates Kind clusters, RustFS, Vault, Dex, MetalLB, Traefik, cert-manager, ESO per region |
| `scripts/teardown.sh` | Destroys all clusters and containers |
| `scripts/info.sh` | Displays cluster status and access URLs |
| `demo/setup.sh` | Deploys CNPG operator, Barman Cloud Plugin, PostgreSQL clusters (pg-eu, pg-us, or pg-local) |
| `demo/self-service-setup.sh` | Advanced demo: Vault + ESO + CNPG + pgAdmin + Grafana with Dex OAuth |
| `monitoring/setup.sh` | Deploys full observability stack (Prometheus, Grafana, Loki, Mimir, Tempo, Alloy) |
| `flake.nix` | Nix flake dev shell (kubectl, kind, helm, jq, stern, k9s, etc.) |
| `mise.toml` | Tool version pinning (envsubst, kind) |

## Architecture Overview

```
┌───────────────────────────────────────────────────────────────────────┐
│                        Host Machine (Docker)                          │
│                                                                       │
│  ┌──────────┐   ┌──────────┐   ┌──────────┐   ┌──────────┐          │
│  │ step-ca  │   │  Vault   │   │   Dex    │   │  RustFS  │          │
│  │ (8443)   │   │ (8200)   │   │ (5556)   │   │ (9000)   │          │
│  │ Root CA  │   │ TLS via  │   │ TLS via  │   │          │          │
│  │          │   │ step-ca  │   │ Vault PKI│   │          │          │
│  └────┬─────┘   └────┬─────┘   └────┬─────┘   └────┬─────┘          │
│       │              │              │              │                 │
│  ┌────┴──────────────┴──────────────┴──────────────┴──────────────┐   │
│  │              Kind Cluster (per region: local, eu, us)          │   │
│  │                                                                │   │
│  │  ┌───────────┐  ┌──────────┐  ┌──────────┐  ┌─────────────┐  │   │
│  │  │ Traefik   │  │ cert-mgr │  │   ESO    │  │ trust-mgr   │  │   │
│  │  │ (ingress) │  │  (TLS)   │  │ (secrets)│  │ (CA bundle) │  │   │
│  │  └────┬──────┘  └──────────┘  └──────────┘  └─────────────┘  │   │
│  │       │                                                        │   │
│  │  ┌────┴──────────────────────────────────────────────────────┐ │   │
│  │  │              CloudNativePG Operator                       │ │   │
│  │  │  ┌──────────┐ ┌─────────┐ ┌─────────┐ ┌─────────────────┐ │ │   │
│  │  │  │ pg-local │ │  pg-eu  │ │  pg-us  │ │ Barman Cloud    │ │ │   │
│  │  │  │(primary  │ │(primary │ │  (DR    │ │    Plugin       │ │ │   │
│  │  │  │ learning)│ │ 3 inst) │ │ 3 inst) │ │(backup/restore) │ │ │   │
│  │  │  └──────────┘ └─────────┘ └─────────┘ └─────────────────┘ │ │   │
│  │  └───────────────────────────────────────────────────────────┘ │   │
│  │                                                                │   │
│  │  ┌────────────────────────────────────────────────────────┐    │   │
│  │  │  Monitoring: Prometheus → Mimir, Alloy → Loki,         │    │   │
│  │  │  OTel Collector → Tempo, Grafana (visualize all)       │    │   │
│  │  └────────────────────────────────────────────────────────┘    │   │
│  └────────────────────────────────────────────────────────────────┘   │
└───────────────────────────────────────────────────────────────────────┘

PKI Trust Chain:
  step-ca Root CA → step-ca Intermediate CA → Vault Intermediate CA → leaf certs
                                                  ↳ Vault TLS cert (step-ca direct)
                                                  ↳ Dex TLS cert
                                                  ↳ Traefik dashboard cert
                                                  ↳ cluster-certs (via cert-manager)
                                                  ↳ mTLS client certs (via cert-manager)
                                                  ↳ mTLS server certs (via cert-manager)

mTLS Access Patterns:
  TLS Passthrough: Client → Traefik (SNI routing) → PostgreSQL (client verifies server, server verifies client)
  TLS Termination:  Client → Traefik (terminates TLS, verifies client cert via vault-pki-bundle) → PostgreSQL
```

## Setup Lifecycle

1. **`scripts/setup.sh`** — Phase 0: Bootstrap step-ca (Root CA) + Vault (non-dev, step-ca TLS) + Vault PKI + ESO + Dex; Phase 1: Create Kind clusters, deploy RustFS, MetalLB, cert-manager, trust-manager, ESO, Traefik per region; Phase 2: Distribute RustFS secrets; Post-loop: Vault OIDC + step-ca OIDC provisioner
2. **`demo/setup.sh`** — Deploy CNPG operator, Barman Cloud Plugin, ObjectStore CRs, PostgreSQL clusters with distributed topology
3. **`monitoring/setup.sh`** — Deploy Prometheus Operator, Grafana Operator, Loki, Alloy, Mimir, Tempo, OTel Collector, dashboards

## Directory Map (Aggregated)

| Directory | Responsibility Summary | Detailed Map |
|-----------|----------------------|--------------|
| `scripts/` | Lifecycle manager and bootstrap orchestrator for the multi-region CNPG playground | [View Map](scripts/codemap.md) |
| `demo/` | Demo scenarios for distributed PostgreSQL topology across regions | [View Map](demo/codemap.md) |
| `demo/yaml/` | Central YAML repository for region-keyed CNPG manifests | [View Map](demo/yaml/codemap.md) |
| `demo/yaml/barman-cloud/` | Barman Cloud Plugin mTLS certificates (vault-pki instead of self-signed) | [View Map](demo/yaml/barman-cloud/codemap.md) |
| `demo/yaml/eu/` | Primary pg-eu cluster with Barman Cloud Plugin | [View Map](demo/yaml/eu/codemap.md) |
| `demo/yaml/us/` | DR pg-us cluster bootstrapping from EU primary | [View Map](demo/yaml/us/codemap.md) |
| `demo/yaml/local/` | **Primary learning environment** — single-region standalone demo with ESO, custom metrics, and PgBouncer | [View Map](demo/yaml/local/codemap.md) |
| `demo/yaml/local/mtls/` | mTLS certificates and Traefik IngressRoutes for PostgreSQL (passthrough + termination modes) | [View Map](demo/yaml/local/mtls/codemap.md) |
| `demo/yaml/object-stores/` | ObjectStore CRs for S3-compatible backup storage | [View Map](demo/yaml/object-stores/codemap.md) |
| `demo/yaml/self-service/` | Full self-service stack: Vault+ESO+CNPG+Traefik+pgAdmin+Grafana | [View Map](demo/yaml/self-service/codemap.md) |
| `demo/yaml/self-service/rbr-ver/` | Application namespace for self-service demo | [View Map](demo/yaml/self-service/rbr-ver/codemap.md) |
| `demo/yaml/self-service/rbr-ver-db/` | Database tenant namespace with ESO-managed CNPG cluster | [View Map](demo/yaml/self-service/rbr-ver-db/codemap.md) |
| `demo/yaml/self-service/pgadmin/` | pgAdmin deployment with pre-seeded server connections | [View Map](demo/yaml/self-service/pgadmin/codemap.md) |
| `demo/yaml/self-service/grafana/` | Grafana with Dex OAuth and multi-datasource dashboards | [View Map](demo/yaml/self-service/grafana/codemap.md) |
| `demo/yaml/self-service/traefik/` | TCP IngressRoute for PostgreSQL external access | [View Map](demo/yaml/self-service/traefik/codemap.md) |
| `k8s/` | Kind cluster topology definition (7-node per region) | [View Map](k8s/codemap.md) |
| `traefik/` | Traefik v3 ingress controller Helm values and IngressRoutes | [View Map](traefik/codemap.md) |
| `step-ca/` | SmallStep step-ca Root CA — 3-tier PKI hierarchy root, trust anchor for all playground TLS | [View Map](step-ca/codemap.md) |
| `step-ca/config/` | step-ca configuration template (ca.json.tpl) with CRL, TLS, and provisioner overrides | [View Map](step-ca/config/codemap.md) |
| `step-ca/db/` | BadgerDB v2 storage for step-ca certificate database (runtime, ephemeral) | [View Map](step-ca/db/codemap.md) |
| `step-ca/pki/` | Root and intermediate CA certificates (runtime, ephemeral) | [View Map](step-ca/pki/codemap.md) |
| `step-ca/secrets/` | CA private keys and passwords (runtime, ephemeral) | [View Map](step-ca/secrets/codemap.md) |
| `step-ca/traefik/` | K8s Service/Endpoints wiring step-ca into the cluster | [View Map](step-ca/traefik/codemap.md) |
| `step-ca/trust-manager/` | trust-manager Bundle resource template distributing step-ca root+intermediate to all namespaces | [View Map](step-ca/trust-manager/codemap.md) |
| `vault/` | HashiCorp Vault (non-dev mode) — secrets, 3-tier PKI, and auth, signed by step-ca | [View Map](vault/codemap.md) |
| `vault/config/` | Vault server HCL configuration | [View Map](vault/config/codemap.md) |
| `vault/eso/` | External Secrets Operator ClusterSecretStore templates | [View Map](vault/eso/codemap.md) |
| `vault/cert-manager/` | cert-manager ClusterIssuer templates for Vault PKI | [View Map](vault/cert-manager/codemap.md) |
| `vault/trust-manager/` | trust-manager Bundle combining step-ca roots + Vault PKI intermediate for mTLS verification | [View Map](vault/trust-manager/codemap.md) |
| `vault/traefik/` | K8s Service/Endpoints wiring Vault into the cluster | [View Map](vault/traefik/codemap.md) |
| `dex/` | Dex OIDC identity provider configuration | [View Map](dex/codemap.md) |
| `dex/config/` | Dex server configuration YAML and templates | [View Map](dex/config/codemap.md) |
| `monitoring/` | Full observability stack deployment (Prometheus, Grafana, Loki, Mimir, Tempo) | [View Map](monitoring/codemap.md) |
| `monitoring/alloy/` | Grafana Alloy log collector configuration | [View Map](monitoring/alloy/codemap.md) |
| `monitoring/cnpg/` | PodMonitor definitions for CNPG operator, cluster, and pooler | [View Map](monitoring/cnpg/codemap.md) |
| `monitoring/grafana/` | Grafana CR, datasources, dashboards, and ingress | [View Map](monitoring/grafana/codemap.md) |
| `monitoring/loki/` | Loki Helm values with S3 backend | [View Map](monitoring/loki/codemap.md) |
| `monitoring/mimir/` | Mimir Helm values for multi-tenant metrics | [View Map](monitoring/mimir/codemap.md) |
| `monitoring/otel-collector/` | OpenTelemetry Collector with tail-based sampling | [View Map](monitoring/otel-collector/codemap.md) |
| `monitoring/prometheus-instance/` | Prometheus CR and RBAC configuration | [View Map](monitoring/prometheus-instance/codemap.md) |
| `monitoring/prometheus-operator/` | Prometheus Operator kustomization | [View Map](monitoring/prometheus-operator/codemap.md) |
| `monitoring/tempo/` | Tempo Helm values for distributed tracing | [View Map](monitoring/tempo/codemap.md) |
| `pgadmin/` | pgAdmin4 deployment manifests for PostgreSQL management | [View Map](pgadmin/codemap.md) |

## Current Cluster State (local region)

### Nodes

| Node | Role | Labels |
|------|------|--------|
| k8s-local-control-plane | control-plane | node-role.kubernetes.io/control-plane |
| k8s-local-worker | worker | node.kubernetes.io/role=worker |
| k8s-local-worker2 | worker | node.kubernetes.io/role=worker |
| k8s-local-worker3 | worker | node.kubernetes.io/role=worker |
| k8s-local-worker4 | worker | node.kubernetes.io/role=worker |
| k8s-local-worker5 | worker | node.kubernetes.io/role=worker |
| k8s-local-worker6 | worker | node.kubernetes.io/role=worker |

### Namespaces

| Namespace | Purpose |
|-----------|---------|
| cert-manager | cert-manager + trust-manager (TLS/PKI) |
| cnpg-system | CloudNativePG operator + Barman Cloud Plugin |
| default | pg-local cluster (3 instances + pooler) from `demo/setup.sh` |
| demo-local-db | pg-local ESO cluster (3 instances + pooler) from `demo/eso-vault.sh` |
| external-secrets | External Secrets Operator |
| grafana | Grafana Operator, Grafana, Loki, Alloy |
| metallb-system | MetalLB load balancer |
| mimir | Mimir (long-term metrics storage) |
| otel | OpenTelemetry Collector (tail-based sampling) |
| prometheus-operator | Prometheus Operator + kube-prometheus-stack |
| step-ca | SmallStep step-ca (Root CA) |
| tempo | Tempo (distributed tracing) |
| traefik | Traefik v3 ingress controller |
| vault | HashiCorp Vault |

### CNPG Clusters

| Namespace | Cluster | Instances | Primary | Pooler | Backup | Credentials |
|-----------|---------|-----------|---------|--------|--------|-------------|
| default | pg-local | 3 (1 primary + 2 replicas) | pg-local-1 | pooler-local-rw (2 replicas) | ScheduledBackup → objectstore-local (RustFS) | CNPG-managed |
| demo-local-db | pg-local | 3 (1 primary + 2 replicas) | pg-local-1 | pooler-local-rw (2 replicas) | — | Vault-managed via ESO (superuser, app, readonly) |

### Observability Stack

| Component | Namespace | Version | Notes |
|-----------|-----------|---------|-------|
| Prometheus Operator | prometheus-operator | v0.90.1 | kube-prometheus-stack 83.6.0 |
| Prometheus | prometheus-operator | v3.10.0 | Single instance, remoteWrites to Mimir |
| Mimir | mimir | 2.16.0 | Distributed mode (3 zones), S3 backend via RustFS |
| Loki | grafana | 3.7.1 | Single-binary mode, S3 backend via RustFS |
| Tempo | tempo | 2.10.5 | Distributed mode, S3 backend via RustFS |
| Alloy | grafana | v1.16.0 | Log collection → Loki |
| OTel Collector | otel | 0.151.0 | Tail-based sampling gateway → Tempo |
| Grafana | grafana | 12.4.1 | Operator-managed, 5 datasources, 10 dashboards |
| Grafana Operator | grafana | v5.22.2 | Manages Grafana CR + dashboards + datasources |

### Grafana Datasources

| Name | Type | Purpose |
|------|------|---------|
| mimir | Prometheus | Long-term metrics via Mimir nginx |
| mimir-tempo | Prometheus | Tempo metrics via Mimir |
| prometheus | Prometheus | Short-term metrics via Prometheus |
| loki | Loki | Log aggregation |
| tempo | Tempo | Distributed tracing |

### Grafana Dashboards

| Dashboard | Purpose |
|-----------|---------|
| cloudnativepg-dashboard | CNPG cluster overview |
| cnpg-custom-pg | Custom PostgreSQL metrics |
| k8s-events | Kubernetes events |
| k8s-pod-logs | Pod log viewer |
| k8s-resources-cluster | Cluster resource overview |
| k8s-views-global | Global cluster views |
| k8s-views-pods | Pod detail views |
| node-exporter-full | Node metrics |
| pgaudit-dashboard | PGAudit logging |
| traefik-traces | Traefik request tracing |

### PKI & Secrets

| Resource | Namespace | Purpose |
|----------|-----------|---------|
| ClusterIssuer vault-pki | cert-manager | Issues in-cluster TLS certs via Vault PKI |
| Bundle step-ca-bundle | trust-manager | Distributes step-ca root+intermediate CA to all namespaces |
| Bundle vault-pki-bundle | trust-manager | Distributes step-ca root+intermediate + Vault PKI intermediate CA to all namespaces (used for mTLS client verification) |
| ClusterSecretStore vault-approle | external-secrets | Vault AppRole auth for ESO secret sync |
| ExternalSecret pg-local-superuser | demo-local-db | Syncs superuser creds from Vault |
| ExternalSecret pg-local-app | demo-local-db | Syncs app user creds from Vault |
| ExternalSecret pg-local-readonly | demo-local-db | Syncs readonly user creds from Vault |

### Ingress (Traefik)

| IngressRoute | Namespace | Routes To |
|--------------|-----------|-----------|
| grafana | grafana | Grafana UI (http://grafana.172-18-255-200.sslip.io) |
| traefik-dashboard | traefik | Traefik dashboard |

### Helm Releases

| Release | Namespace | Chart | App Version |
|---------|-----------|-------|-------------|
| alloy | grafana | alloy-1.8.0 | v1.16.0 |
| barman-cloud | cnpg-system | plugin-barman-cloud-0.6.0 | v0.12.0 |
| cert-manager | cert-manager | cert-manager-v1.20.2 | v1.20.2 |
| cnpg-operator | cnpg-system | cloudnative-pg-0.28.0 | 1.29.0 |
| external-secrets | external-secrets | external-secrets-2.4.1 | v2.4.1 |
| grafana-operator | grafana | grafana-operator-5.22.2 | v5.22.2 |
| kube-prometheus-stack | prometheus-operator | kube-prometheus-stack-83.6.0 | v0.90.1 |
| loki | grafana | loki-13.5.0 | 3.7.1 |
| metallb | metallb-system | metallb-0.15.3 | v0.15.3 |
| mimir | mimir | mimir-distributed-5.7.0 | 2.16.0 |
| otel-collector | otel | opentelemetry-collector-0.153.0 | 0.151.0 |
| tempo | tempo | tempo-distributed-2.19.0 | 2.10.5 |
| traefik | traefik | traefik-39.0.8 | v3.6.13 |
| trust-manager | cert-manager | trust-manager-v0.17.1 | v0.17.1 |

### External Services (Docker containers on host)

| Service | Port | Purpose |
|---------|------|---------|
| step-ca | 8443 | Root CA + intermediate CA, TLS provider |
| Vault | 8200 | Secrets management, PKI, AppRole auth |
| Dex | 5556 | OIDC identity provider |
| RustFS | 9000 | S3-compatible object storage (backups, Mimir, Loki, Tempo) |

## Key Configuration Patterns

- **3-Tier PKI Hierarchy**: step-ca Root CA → step-ca Intermediate CA → Vault Intermediate CA → leaf certs. step-ca is the trust anchor; Vault's intermediate is signed by step-ca's intermediate via openssl on the host (step CLI needs TTY). trust-manager distributes the step-ca root+intermediate bundle to all namespaces.
- **Split mTLS**: Vault issues in-cluster mTLS client certs (role `mtls-client`, 168h TTL) while step-ca issues external-facing certs directly (e.g., Vault's own TLS cert). Two PostgreSQL access patterns: TLS passthrough (client holds cert, Traefik forwards encrypted stream) and TLS termination (Traefik terminates TLS, verifies client cert against `vault-pki-bundle`, proxies to PostgreSQL).
- **Three First-Class Regions**: `local` (primary learning environment, single-region standalone), `eu` (primary in multi-region setup), `us` (DR replica bootstrapping from EU). `local` is not in the default `REGIONS=("eu" "us")` but is fully supported — pass `local` as an argument to `scripts/setup.sh`
- **Distributed Topology**: In multi-region mode, pg-eu is primary, pg-us bootstraps from pg-eu via recovery, continuous backup via Barman Cloud to RustFS
- **Self-Service Demo**: Only runs in the `local` region. Vault ESO injects credentials, Vault Database engine provides dynamic creds, Dex provides OAuth, Traefik TCP IngressRoute exposes PostgreSQL
- **Template-Driven Configuration**: Most YAML files use `.tpl` variants with `envsubst` for region-specific variable injection
- **Hub-and-Spoke Monitoring**: Hub region runs Mimir + Tempo; spoke regions push metrics/traces via IngressRoute
- **Node Isolation**: Kind clusters use labeled node pools (infra, app, postgres) with taints for dedicated PostgreSQL nodes
- **Full-Chain TLS**: All TLS-serving containers (Dex, Vault) include the complete certificate chain (leaf + intermediates + root) so clients can verify without out-of-band CA distribution