# CNPG Playground — Architecture Overview

> A local learning environment for **CloudNativePG** (CNPG), the PostgreSQL operator for Kubernetes.

---

## 1. What Is This Project?

CNPG Playground creates a **fully functional Kubernetes-based PostgreSQL platform** on your laptop using Docker/Kind. It simulates production-grade infrastructure — including TLS certificate management, secrets management, observability, and distributed database topologies — so teams can learn, experiment, and validate CNPG patterns without needing a cloud environment.

---

## 2. High-Level System Diagram

```mermaid
graph TB
    subgraph Host["Host Machine (Docker)"]
        subgraph External["External Services (Docker Containers)"]
            StepCA["🔐 step-ca<br/>Root CA<br/>:8443"]
            Vault["🗝️ Vault<br/>Secrets & PKI<br/>:8200"]
            Authelia["👤 Authelia<br/>OIDC Provider<br/>:9091"]
            RustFS["📦 RustFS<br/>S3 Object Store<br/>:9000"]
            subgraph SeaweedfsEco["📦 SeaweedFS<br/>S3 Object Store"]
                Seaweed["📦 Data Store<br/>:8333"]
                SeaweedAdmin["🧭 Admin UI<br/>:23646"]
                SeaweedWebDav["🌐 WebDAV"]
                SeawweedWorker["🔧 Maintainance<br/>Worker"]
            end
        end
    end

    subgraph K8s["Kind Cluster (local region)"]
        direction TB
        subgraph Infra["Infrastructure Layer"]
            Calico["🕸️ Calico CNI<br/>(Tigera Operator)"]
            Traefik["🔀 Traefik<br/>Ingress Controller"]
            CertMgr["📜 cert-manager<br/>+ trust-manager"]
            ESO["🔌 External Secrets<br/>Operator"]
            MetalLB["⚖️ MetalLB<br/>Load Balancer"]
            Caretta["🕸️ Caretta<br/>Network Observability"]
            CNPG["🐘 CNPG Operator<br/>v1.29.0"]
            Radar["📡 Radar"]
        end

        subgraph DBLayer["Database Layer"]
            PG1["pg-local-1<br/>(Primary)"]
            PG2["pg-local-2<br/>(Replica)"]
            PG3["pg-local-3<br/>(Replica)"]
            Pooler["PgBouncer<br/>pooler-local-rw"]
            Barman["💾 Barman Cloud<br/>Plugin"]
        end

        subgraph ObsLayer["Observability Layer"]
            Prom["📊 Prometheus<br/>v3.11.3"]
            Mimir["📈 Mimir<br/>Long-term Metrics"]
            Loki["📝 Loki<br/>Log Aggregation"]
            Tempo["🔍 Tempo<br/>Distributed Tracing"]
            Alloy["🔄 Alloy<br/>Log Collector"]
            Grafana["📊 Grafana<br/>Dashboards"]
            OTel["📡 OTel Collector<br/>Tail-based Sampling"]
        end
    end

    StepCA -->|TLS certs| Vault
    Vault -->|PKI| CertMgr
    Vault -->|AppRole| ESO
    Authelia -->|OIDC| Vault
    RustFS -->|S3 backups| Barman
    RustFS -->|S3 storage| Mimir
    RustFS -->|S3 storage| Tempo
    Seaweed -->|S3 storage| Loki
    ESO -->|sync secrets| PG1
    ESO -->|sync secrets| PG2
    ESO -->|sync secrets| PG3
    CertMgr -->|TLS certs| Traefik
    CNPG -->|manages| PG1
    CNPG -->|manages| PG2
    CNPG -->|manages| PG3
    Pooler -->|connections| PG1
    Prom -->|remoteWrite| Mimir
    Alloy -->|logs| Loki
    OTel -->|traces| Tempo
    Grafana -->|queries| Mimir
    Grafana -->|queries| Loki
    Grafana -->|queries| Tempo
    Grafana -->|queries| Prom
    Traefik -->|traces| OTel
```

---

## 3. Setup Scripts — What Each One Does

### 3.1 `scripts/setup.sh local` — Infrastructure Bootstrap

This is the **foundation script** that creates everything the other scripts depend on.

```mermaid
flowchart TD
    A["scripts/setup.sh local"] --> P0["Phase 0: External Services"]
    P0 --> P0A["step-ca (Root CA)"]
    P0 --> P0B["Vault (Secrets + PKI)"]
    P0 --> P0C["Vault PKI Setup"]
    P0 --> P0D["Vault ESO AppRole"]
    P0 --> P0E["Authelia (OIDC)"]

    A --> P1["Phase 1: Cluster Provisioning"]
    P1 --> P1A["Kind Cluster Creation<br/>(7 nodes: 1 control-plane + 6 workers)"]
    P1 --> P1A2["Calico CNI<br/>(Tigera Operator)"]
    P1 --> P1B["RustFS S3 Container"]
    P1 --> P1B2["SeaweedFS S3 Container"]
    P1 --> P1C["MetalLB (Load Balancer)"]
    P1 --> P1D["cert-manager + trust-manager"]
    P1 --> P1E["External Secrets Operator"]
    P1 --> P1F["Traefik Ingress Controller"]
    P1 --> P1G["Wire step-ca & Vault<br/>into K8s via Services/Endpoints"]
    P1 --> P1H["Caretta + Radar<br/>(network observability)"]

    A --> P2["Phase 2: Secret Distribution"]
    P2 --> P2A["RustFS credentials<br/>to all clusters"]
    P2 --> P2A2["SeaweedFS credentials<br/>to all clusters"]

    A --> P3["Post-Loop Configuration"]
    P3 --> P3A["Vault OIDC auth"]
    P3 --> P3B["step-ca OIDC provisioner"]

    style A fill:#4CAF50,color:white
    style P0 fill:#2196F3,color:white
    style P1 fill:#FF9800,color:white
    style P2 fill:#9C27B0,color:white
    style P3 fill:#F44336,color:white
```

**Key outcomes:**
- A 7-node Kind cluster with labeled node pools (control-plane, infra, app, postgres)
- External services (step-ca, Vault, Authelia, RustFS) running as Docker containers, wired into K8s via headless Services/Endpoints
- Calico CNI (via Tigera Operator) providing pod networking, with Caretta + Radar for network observability
- Full 3-tier PKI: step-ca Root → step-ca Intermediate → Vault Intermediate → leaf certs
- cert-manager ClusterIssuer for Vault PKI, trust-manager distributing CA bundles
- ESO ClusterSecretStore with Vault AppRole authentication
- Traefik with MetalLB LoadBalancer, TLS dashboard, and PostgreSQL TCP routing

### 3.2 `demo/setup.sh local` — Database Deployment

```mermaid
flowchart LR
    B["demo/setup.sh local"] --> C1["CNPG Operator<br/>v1.29.0"]
    B --> C2["Barman Cloud Plugin<br/>v0.12.0"]
    B --> C3["ObjectStore CR<br/>(RustFS S3)"]
    B --> C4["PostgreSQL Cluster<br/>pg-local (3 instances)"]
    B --> C5["PgBouncer Pooler<br/>pooler-local-rw (2 replicas)"]
    B --> C6["PodMonitor<br/>(if Prometheus present)"]

    C4 --> C4A["pg-local-1 (Primary)"]
    C4 --> C4B["pg-local-2 (Replica)"]
    C4 --> C4C["pg-local-3 (Replica)"]

    style B fill:#4CAF50,color:white
```

**Key outcomes:**
- CNPG operator managing a 3-instance PostgreSQL 18 cluster (1 primary + 2 replicas)
- PgBouncer connection pooler for read-write traffic
- Scheduled backups to RustFS via Barman Cloud Plugin
- PodMonitor for Prometheus metrics collection

### 3.3 `monitoring/setup.sh local` — Observability Stack

```mermaid
flowchart TD
    M["monitoring/setup.sh local"] --> M1["Prometheus Operator<br/>+ kube-prometheus-stack"]
    M --> M2["Mimir<br/>(distributed, 3 zones)"]
    M --> M3["Loki<br/>(single-binary)"]
    M --> M4["Tempo<br/>(distributed)"]
    M --> M5["Alloy<br/>(log collector)"]
    M --> M6["OTel Collector<br/>(tail-based sampling)"]
    M --> M7["Grafana Operator<br/>+ Grafana + Dashboards"]
    M --> M8["CNPG PodMonitors"]

    M2 --> S3A["RustFS S3<br/>(mimir-blocks,<br/>mimir-alertmanager,<br/>mimir-ruler)"]
    M3 --> S3B["SeaweedFS S3<br/>(loki)"]
    M4 --> S3C["RustFS S3<br/>(tempo)"]

    M1 -->|remoteWrite| M2
    M5 -->|push logs| M3
    M6 -->|push traces| M4
    M7 -->|query| M1
    M7 -->|query| M2
    M7 -->|query| M3
    M7 -->|query| M4

    style M fill:#4CAF50,color:white
```

**Key outcomes:**
- Full observability stack: metrics (Prometheus → Mimir), logs (Alloy → Loki), traces (OTel → Tempo)
- Grafana with 5 datasources (Prometheus [default], Mimir, Mimir-Tempo, Loki, Tempo) and 12 pre-configured dashboards
- All long-term storage backed by RustFS S3
- Hub-and-spoke architecture (hub region runs Mimir + Tempo; spokes push via Traefik IngressRoutes)

### 3.4 `demo/eso-vault.sh setup local` — Secrets Management Demo

```mermaid
flowchart TD
    E["demo/eso-vault.sh setup local"] --> E1["Seed Vault KV paths<br/>cnpg/pg-local/{superuser,app}"]
    E --> E2["Create demo-local-db namespace"]
    E --> E3["Apply ExternalSecrets<br/>(2 credential types)"]
    E --> E4["Issue mTLS certificates<br/>(server, replication, tls-term,<br/>pooler-client, pooler-server)"]
    E --> E5["Create PgBouncer auth secret"]
    E --> E6["Apply TLSOption (mtls-verify)"]
    E --> E7["Apply IngressRouteTCP<br/>(TLS termination + passthrough)"]
    E --> E8["Deploy CNPG Cluster pg-local<br/>(ESO-managed credentials)"]

    E1 -->|Vault KV| E3
    E3 -->|sync to K8s Secrets| E8
    E4 -->|cert-manager| E8

    style E fill:#4CAF50,color:white
```

**Key outcomes:**
- PostgreSQL credentials (superuser, app) managed by Vault and synced to K8s via ESO
- Full mTLS infrastructure: server, replication, and client certificates issued by cert-manager via Vault PKI
- Two PostgreSQL access patterns via Traefik:
  - **TLS termination**: `pg-local-demo-local-db-t.<IP>.sslip.io:5432`
  - **TLS passthrough**: `pg-local-demo-local-db-p.<IP>.sslip.io:5432`
- Credential rotation workflow: update in Vault → force ESO sync → CNPG reconciles

---

## 4. PKI Trust Chain

```mermaid
graph TD
    RootCA["🔐 step-ca Root CA<br/>(self-signed)"]
    IntCA["🔐 step-ca Intermediate CA"]
    VaultIntCA["🔐 Vault Intermediate CA<br/>(signed by step-ca int)"]

    RootCA -->|signs| IntCA
    IntCA -->|signs| VaultIntCA

    IntCA -->|issues| VaultTLS["Vault TLS cert"]
    IntCA -->|issues| AutheliaTLS["Authelia TLS cert"]
    IntCA -->|issues| RustFSTLS["RustFS TLS cert"]
    IntCA -->|issues| SeaweedFSTLS["SeaweedFS TLS cert"]
    VaultIntCA -->|issues| TraefikDashTLS["Traefik Dashboard cert"]
    VaultIntCA -->|issues| RadarDashTLS["Radar Dashboard cert"]
    VaultIntCA -->|issues| ClusterCerts["In-cluster TLS certs<br/>(via cert-manager)"]
    VaultIntCA -->|issues| MTLSCerts["mTLS client certs<br/>(via cert-manager)"]

    IntCA -->|signs directly| VaultExtTLS["Vault external TLS cert"]

    style RootCA fill:#F44336,color:white
    style IntCA fill:#FF9800,color:white
    style VaultIntCA fill:#2196F3,color:white
```

**How it works:**
1. **step-ca** is the trust anchor — its root certificate is distributed to all namespaces via trust-manager
2. **Vault** runs its own PKI intermediate, signed by step-ca's intermediate
3. **cert-manager** uses Vault's PKI backend (via AppRole auth) to issue in-cluster leaf certificates
4. All TLS-serving endpoints include the full chain (leaf + intermediates + root) for verification without out-of-band CA distribution

---

## 5. Data Flow Diagrams

### 5.1 PostgreSQL Connection Flow

```mermaid
sequenceDiagram
    participant App as Application
    participant Pooler as PgBouncer<br/>pooler-local-rw
    participant Primary as pg-local-1<br/>(Primary)
    participant Replica1 as pg-local-2<br/>(Replica)
    participant Replica2 as pg-local-3<br/>(Replica)
    participant S3 as RustFS<br/>(S3 Backup)

    App->>Pooler: Connect (read-write)
    Pooler->>Primary: Forward connection
    Primary->>Replica1: Streaming replication
    Primary->>Replica2: Streaming replication
    Primary->>S3: Scheduled backups<br/>(via Barman Cloud Plugin)

    Note over App,Pooler: For ESO demo:<br/>App → Traefik TCP → PgBouncer → Primary
```

### 5.2 Secrets Management Flow (ESO Demo)

```mermaid
sequenceDiagram
    participant Vault as HashiCorp Vault
    participant ESO as External Secrets<br/>Operator
    participant K8s as Kubernetes Secrets
    participant CNPG as CNPG Operator
    participant PG as PostgreSQL Cluster

    Vault->>ESO: AppRole authentication
    ESO->>Vault: Read cnpg/pg-local/superuser
    ESO->>Vault: Read cnpg/pg-local/app
    ESO->>K8s: Create/update Secrets
    K8s->>CNPG: Reference secrets
    CNPG->>PG: Bootstrap cluster with<br/>Vault-managed credentials

    Note over Vault,PG: Rotation: Vault KV update → ESO sync → CNPG reconciliation
```

### 5.3 Observability Data Flow

```mermaid
flowchart LR
    subgraph Sources["Data Sources"]
        PG["PostgreSQL<br/>(CNPG metrics)"]
        K8sN["K8s Nodes<br/>(node-exporter)"]
        K8sO["K8s Objects<br/>(kube-state-metrics)"]
        TraefikS["Traefik<br/>(access logs + traces)"]
        AppL["Application<br/>Logs"]
    end

    subgraph Collection["Collection"]
        Prom["Prometheus"]
        Alloy["Alloy"]
        OTel["OTel Collector"]
    end

    subgraph Storage["Long-term Storage"]
        Mimir["Mimir"]
        Loki["Loki"]
        Tempo["Tempo"]
        S3["RustFS S3"]
        Seaweed["SeaweedFS S3"]
    end

    subgraph Visualization["Visualization"]
        Grafana["Grafana"]
    end

    PG --> Prom
    K8sN --> Prom
    K8sO --> Prom
    AppL --> Alloy
    TraefikS --> OTel

    Prom -->|remoteWrite| Mimir
    Alloy -->|push| Loki
    OTel -->|push| Tempo

    Loki --> Seaweed
    Mimir --> S3
    Tempo --> S3

    Grafana --> Mimir
    Grafana --> Loki
    Grafana --> Tempo
    Grafana --> Prom
```

---

## 6. Current Cluster State (Live)

### Nodes (7 total)

| Node | Role | Labels |
|------|------|--------|
| k8s-local-control-plane | control-plane | `node-role.kubernetes.io/control-plane` |
| k8s-local-worker | worker | `node-role.kubernetes.io/infra` |
| k8s-local-worker2 | worker | `node-role.kubernetes.io/infra` |
| k8s-local-worker3 | worker | `node-role.kubernetes.io/app` |
| k8s-local-worker4 | worker | `node-role.kubernetes.io/postgres` |
| k8s-local-worker5 | worker | `node-role.kubernetes.io/postgres` |
| k8s-local-worker6 | worker | `node-role.kubernetes.io/postgres` |

### Application & Infrastructure Namespaces (18)

> Excludes Kubernetes system namespaces (`kube-system`, `kube-public`, `kube-node-lease`, `local-path-storage`) and the unused `default` namespace.

| Namespace | Purpose |
|-----------|---------|
| authelia | Authelia OIDC provider service wiring |
| calico-system | Calico CNI (node, typha, kube-controllers, apiserver, whisker) |
| caretta | Caretta network observability |
| cert-manager | cert-manager + trust-manager (TLS/PKI) |
| cnpg-system | CNPG operator + Barman Cloud Plugin |
| demo-local-db | pg-local cluster (ESO/Vault demo) |
| external-secrets | External Secrets Operator |
| grafana | Grafana Operator, Grafana, Loki, Alloy |
| metallb-system | MetalLB load balancer |
| mimir | Mimir (long-term metrics) |
| otel | OTel Collector |
| prometheus-operator | Prometheus Operator + kube-prometheus-stack |
| radar | Radar network observability UI |
| step-ca | step-ca service wiring |
| tempo | Tempo (distributed tracing) |
| tigera-operator | Tigera Operator (manages Calico) |
| traefik | Traefik v3 ingress controller |
| vault | Vault service wiring |

### PostgreSQL Clusters (1)

| Namespace | Cluster | Instances | Primary | Pooler | Credentials |
|-----------|---------|-----------|---------|--------|-------------|
| demo-local-db | pg-local | 3 (1P + 2R) | pg-local-1 | pooler-local-rw (1 replica) | Vault-managed via ESO (superuser, app) |

### Key Services (LoadBalancer)

| Service | External IP | Ports |
|---------|-------------|-------|
| traefik | 172.18.255.200 | 80, 443 |
| traefik-postgres | 172.18.255.210 | 5432 |

---

## 7. Component Inventory

### Helm Releases

| Release | Namespace | Chart | App Version |
|---------|-----------|-------|-------------|
| alloy | grafana | alloy-1.8.0 | v1.16.0 |
| barman-cloud | cnpg-system | plugin-barman-cloud-0.6.0 | v0.12.0 |
| caretta | caretta | caretta-0.0.16 | v0.0.16 |
| cert-manager | cert-manager | cert-manager-v1.20.2 | v1.20.2 |
| cnpg-operator | cnpg-system | cloudnative-pg-0.28.0 | 1.29.0 |
| external-secrets | external-secrets | external-secrets-2.4.1 | v2.4.1 |
| grafana-operator | grafana | grafana-operator-5.22.2 | v5.22.2 |
| kube-prometheus-stack | prometheus-operator | kube-prometheus-stack-86.2.3 | v0.91.0 |
| loki | grafana | loki-13.5.0 | 3.7.1 |
| metallb | metallb-system | metallb-0.16.1 | v0.16.1 |
| mimir | mimir | mimir-distributed-6.0.6 | 3.0.4 |
| otel-collector | otel | opentelemetry-collector-0.158.2 | 0.153.0 |
| radar | radar | radar-1.7.9 | 1.7.9 |
| tempo | tempo | tempo-distributed-2.25.2 | 2.10.7 |
| tigera-operator | tigera-operator | tigera-operator-v3.32.0 | v3.32.0 |
| traefik | traefik | traefik-39.0.8 | v3.6.13 |
| trust-manager | cert-manager | trust-manager-v0.17.1 | v0.17.1 |

### External Docker Containers

| Container | Port | Purpose |
|-----------|------|---------|
| step-ca | 8443 | Root CA + Intermediate CA |
| vault | 8200 | Secrets management, PKI, AppRole auth |
| authelia | 9091 | OIDC identity provider (replaces Dex) |
| objectstore-local (RustFS) | 9000 | S3-compatible object storage |
| seaweed (SeaweedFS) | 8333 | S3-compatible object storage |
| seaweed-admin (SeaweedFS Admin) | 23646 | S3-compatible object storage |
| revocation-exporter | — | step-ca CRL / certificate revocation metrics exporter |

### Grafana Dashboards

| Dashboard | Purpose |
|-----------|---------|
| cloudnativepg-dashboard | CNPG cluster overview |
| cnpg-backup-dashboard | CNPG backup status |
| cnpg-custom-pg | Custom PostgreSQL metrics |
| k8s-events | Kubernetes events |
| k8s-pod-logs | Pod log viewer |
| k8s-resources-cluster | Cluster resource overview |
| k8s-views-global | Global cluster views |
| k8s-views-pods | Pod detail views |
| node-exporter-full | Node metrics |
| pgaudit-dashboard | PGAudit logging |
| pki-dashboard | PKI / certificate health |
| traefik-traces | Traefik request tracing |

---

## 8. Self-Service Tenancy (target state)

> **Status: planned, not yet deployed.** This section describes the target architecture added by
> `demo/self-service-setup.sh` for the **local region**. Master plan:
> [`plan-self-service-setup-local.md`](plan-self-service-setup-local.md). Identity model:
> [`plan-tenant-personas-authelia.md`](plan-tenant-personas-authelia.md). The components below are
> **not** in the "Current Cluster State (Live)" inventory above until implemented.

The self-service slice turns the demo into a Kubernetes-native multi-tenant platform: tenants
self-provision a CNPG database (`verstappen` in `rbr-ver-db`) and run the `demo-app` (in `rbr-ver`),
governed by Capsule, Kyverno, and ArgoCD, with Authelia OIDC across every surface.

Tenant model: constructor `rbr` (= Capsule Tenant) → driver group `ver` → namespaces `rbr-ver-db`
(database) + `rbr-ver` (app). Future driver groups (`rbr-had`, …) join the same Tenant.

```mermaid
flowchart TB
    subgraph IdP["Authelia (OIDC, host)"]
      G["groups: rbr-db-admin, rbr-ver-db-admin,<br/>rbr-ver-dev, rbr-po, *-admin"]
    end

    subgraph Access["Tenant API access"]
      GP["gangplank<br/>(OIDC → kubeconfig)"]
      CP["capsule-proxy<br/>(tenant-scoped API)"]
      GP --> CP --> API["kube-apiserver<br/>(AuthenticationConfiguration:<br/>audiences kubernetes+gangplank)"]
    end

    subgraph Gov["Governance"]
      CAP["Capsule Tenant 'rbr'<br/>owns rbr-ver*, rbr-ver-db*"]
      KY["Kyverno<br/>generate RoleBindings + NetPol,<br/>validate baseline"]
      AR["ArgoCD<br/>app-of-apps"]
    end

    subgraph Tenant["Tenant namespaces"]
      APP["rbr-ver:<br/>demo-app (Litestar)"]
      DB["rbr-ver-db:<br/>verstappen CNPG + pgAdmin"]
    end

    G --> GP & API
    G --> Vault["Vault DB engine<br/>config user rbr_ver_vde_config<br/>(rotate-root)"]
    AR -->|sync| CAP & KY & APP & DB & GO["grafana org"]
    KY -.generate.-> APP & DB
    CAP -.owns.-> APP & DB
    Vault -->|dynamic creds / static-role| DB
    APP -->|app role via ESO| DB
    G --> SW["SeaweedFS<br/>admin-UI + S3 OIDC"]
```

### New components (planned)

| Component | Namespace / Host | Role |
|---|---|---|
| Capsule | `capsule-system` | multi-tenancy (`Tenant rbr`) |
| capsule-proxy | `capsule-system` | tenant-scoped K8s API gateway |
| gangplank (`sighupio/gangplank`) | `capsule-system` | OIDC → kubeconfig dispenser (fronts capsule-proxy) |
| Kyverno | `kyverno` | generate per-driver-group RoleBindings + default NetworkPolicy; validate baseline |
| ArgoCD | `argocd` | GitOps engine (app-of-apps for tenant resources) |
| demo-app | `rbr-ver` | Litestar sample app (ArgoCD-deployed, static Vault-rotated DB creds) |
| SeaweedFS OIDC | host | admin-UI + S3 human OIDC (machine keys stay static) |

### Identity → access (summary)

See the full matrix in [`plan-tenant-personas-authelia.md`](plan-tenant-personas-authelia.md).

| Persona | K8s | DB | Grafana |
|---|---|---|---|
| `admin` | tenant owner everywhere | full | Admin |
| `rbr-db-admin` | Tenant `rbr` owner | `rbr-db-admin` creds | rbr/Admin |
| `rbr-ver-db-admin` | admin in `rbr-ver*` | `rbr-ver-db-admin` creds | rbr/Editor |
| `rbr-ver-dev` | edit in `rbr-ver*` | `app`/`readonly` creds | rbr/Editor |
| `rbr-po` | view across `rbr-*` | — | rbr/Viewer |

### Two independent authority layers

K8s API access (Capsule + apiserver OIDC + capsule-proxy) and DB credential issuance (Vault
policies) are configured independently; **Authelia is the common IdP**, and each layer verifies the
`email`/`groups` claims on its own. Monitoring additions: ServiceMonitors + Grafana dashboards for
Capsule, capsule-proxy, Calico (felix/typha/kube-controllers), Kyverno, and ArgoCD.

Related plans: [`capsule-integration-plan.md`](capsule-integration-plan.md),
[`plan-kyverno-policies.md`](plan-kyverno-policies.md),
[`plan-argocd-gitops.md`](plan-argocd-gitops.md),
[`plan-seaweedfs-oidc.md`](plan-seaweedfs-oidc.md),
[`plan-self-service-dynamic-creds-pgadmin.md`](plan-self-service-dynamic-creds-pgadmin.md).