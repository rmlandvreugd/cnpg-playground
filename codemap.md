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
│  ┌──────────┐   ┌──────────┐   ┌──────────┐                           │
│  │  Vault   │   │   Dex    │   │  RustFS  │  (S3-compatible storage)  │
│  │ (8200)   │   │ (5556)   │   │ (9000)   │                           │
│  └────┬─────┘   └────┬─────┘   └────┬─────┘                           │
│       │              │              │                                 │
│  ┌────┴──────────────┴──────────────┴─────────────────────────────┐   │
│  │              Kind Cluster (per region: local, eu, us)          │   │
│  │                                                                │   │
│  │  ┌───────────┐  ┌──────────┐  ┌──────────┐  ┌─────────────┐    │   │
│  │  │ Traefik   │  │ cert-mgr │  │   ESO    │  │ MetalLB     │    │   │
│  │  │ (ingress) │  │  (TLS)   │  │ (secrets)│  │ (LB)        │    │   │
│  │  └────┬──────┘  └──────────┘  └──────────┘  └─────────────┘    │   │
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
```

## Setup Lifecycle

1. **`scripts/setup.sh`** — Phase 0: Bootstrap Vault + Dex (Docker containers); Phase 1: Create Kind clusters, deploy RustFS, MetalLB, Traefik, cert-manager, ESO per region; Phase 2: Distribute RustFS secrets
2. **`demo/setup.sh`** — Deploy CNPG operator, Barman Cloud Plugin, ObjectStore CRs, PostgreSQL clusters with distributed topology
3. **`monitoring/setup.sh`** — Deploy Prometheus Operator, Grafana Operator, Loki, Alloy, Mimir, Tempo, OTel Collector, dashboards

## Directory Map (Aggregated)

| Directory | Responsibility Summary | Detailed Map |
|-----------|----------------------|--------------|
| `scripts/` | Lifecycle manager and bootstrap orchestrator for the multi-region CNPG playground | [View Map](scripts/codemap.md) |
| `demo/` | Demo scenarios for distributed PostgreSQL topology across regions | [View Map](demo/codemap.md) |
| `demo/yaml/` | Central YAML repository for region-keyed CNPG manifests | [View Map](demo/yaml/codemap.md) |
| `demo/yaml/eu/` | Primary pg-eu cluster with Barman Cloud Plugin | [View Map](demo/yaml/eu/codemap.md) |
| `demo/yaml/us/` | DR pg-us cluster bootstrapping from EU primary | [View Map](demo/yaml/us/codemap.md) |
| `demo/yaml/local/` | **Primary learning environment** — single-region standalone demo with ESO, custom metrics, and PgBouncer | [View Map](demo/yaml/local/codemap.md) |
| `demo/yaml/object-stores/` | ObjectStore CRs for S3-compatible backup storage | [View Map](demo/yaml/object-stores/codemap.md) |
| `demo/yaml/self-service/` | Full self-service stack: Vault+ESO+CNPG+Traefik+pgAdmin+Grafana | [View Map](demo/yaml/self-service/codemap.md) |
| `demo/yaml/self-service/rbr-ver/` | Application namespace for self-service demo | [View Map](demo/yaml/self-service/rbr-ver/codemap.md) |
| `demo/yaml/self-service/rbr-ver-db/` | Database tenant namespace with ESO-managed CNPG cluster | [View Map](demo/yaml/self-service/rbr-ver-db/codemap.md) |
| `demo/yaml/self-service/pgadmin/` | pgAdmin deployment with pre-seeded server connections | [View Map](demo/yaml/self-service/pgadmin/codemap.md) |
| `demo/yaml/self-service/grafana/` | Grafana with Dex OAuth and multi-datasource dashboards | [View Map](demo/yaml/self-service/grafana/codemap.md) |
| `demo/yaml/self-service/traefik/` | TCP IngressRoute for PostgreSQL external access | [View Map](demo/yaml/self-service/traefik/codemap.md) |
| `k8s/` | Kind cluster topology definition (7-node per region) | [View Map](k8s/codemap.md) |
| `traefik/` | Traefik v3 ingress controller Helm values and IngressRoutes | [View Map](traefik/codemap.md) |
| `vault/` | HashiCorp Vault configuration for secrets, PKI, and auth | [View Map](vault/codemap.md) |
| `vault/config/` | Vault server HCL configuration | [View Map](vault/config/codemap.md) |
| `vault/eso/` | External Secrets Operator ClusterSecretStore templates | [View Map](vault/eso/codemap.md) |
| `vault/cert-manager/` | cert-manager ClusterIssuer templates for Vault PKI | [View Map](vault/cert-manager/codemap.md) |
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

## Key Configuration Patterns

- **Three First-Class Regions**: `local` (primary learning environment, single-region standalone), `eu` (primary in multi-region setup), `us` (DR replica bootstrapping from EU). `local` is not in the default `REGIONS=("eu" "us")` but is fully supported — pass `local` as an argument to `scripts/setup.sh`
- **Distributed Topology**: In multi-region mode, pg-eu is primary, pg-us bootstraps from pg-eu via recovery, continuous backup via Barman Cloud to RustFS
- **Self-Service Demo**: Only runs in the `local` region. Vault ESO injects credentials, Vault Database engine provides dynamic creds, Dex provides OAuth, Traefik TCP IngressRoute exposes PostgreSQL
- **Template-Driven Configuration**: Most YAML files use `.tpl` variants with `envsubst` for region-specific variable injection
- **Hub-and-Spoke Monitoring**: Hub region runs Mimir + Tempo; spoke regions push metrics/traces via IngressRoute
- **Node Isolation**: Kind clusters use labeled node pools (infra, app, postgres) with taints for dedicated PostgreSQL nodes