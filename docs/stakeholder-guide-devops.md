# CNPG Playground — DevOps & Platform Engineer Guide

> **Audience:** DevOps engineers, platform engineers, SREs, and infrastructure specialists who need to understand *how* this environment works at a technical level.

---

## 1. Architecture Deep Dive

### 1.1 Infrastructure Topology

```mermaid
graph TB
    subgraph DockerHost["Docker Host"]
        subgraph ExternalContainers["External Containers (bridge network)"]
            StepCA["step-ca<br/>:8443<br/>Root + Intermediate CA"]
            Vault["Vault<br/>:8200<br/>Secrets, PKI, AppRole"]
            Dex["Dex<br/>:5556<br/>OIDC Provider"]
            RustFS["RustFS<br/>:9000<br/>S3-Compatible Storage"]
        end
    end

    subgraph KindCluster["Kind Cluster: k8s-local"]
        subgraph ControlPlane["Control Plane Node"]
            KubeAPI["kube-apiserver"]
            Etcd["etcd"]
            CoreDNS["CoreDNS"]
        end

        subgraph InfraNodes["Infra Nodes (worker, worker2)"]
            TraefikPod["Traefik v3.6.13"]
            CertMgrPod["cert-manager v1.20.2"]
            TrustMgrPod["trust-manager v0.17.1"]
            ESOPod["ESO v2.4.1"]
            MetalLBPod["MetalLB v0.15.3"]
        end

        subgraph AppNodes["App Nodes (worker3)"]
            PromPod["Prometheus v3.10.0"]
            GrafanaPod["Grafana 12.4.1"]
            LokiPod["Loki 3.7.1"]
            AlloyPod["Alloy v1.16.0"]
            MimirPods["Mimir 2.16.0<br/>(3-zone distributed)"]
            TempoPods["Tempo 2.10.5<br/>(distributed)"]
            OTelPod["OTel Collector 0.151.0"]
        end

        subgraph PGNodes["PostgreSQL Nodes (worker4-6)"]
            PG1Pod["pg-local-1<br/>(Primary)"]
            PG2Pod["pg-local-2<br/>(Replica)"]
            PG3Pod["pg-local-3<br/>(Replica)"]
            PoolerPods["PgBouncer<br/>pooler-local-rw<br/>(2 replicas)"]
        end
    end

    StepCA -->|8443| Vault
    Vault -->|8200| CertMgrPod
    Vault -->|8200| ESOPod
    Dex -->|5556| Vault
    RustFS -->|9000| MimirPods
    RustFS -->|9000| LokiPod
    RustFS -->|9000| TempoPods

    TraefikPod -->|LB 172.18.255.200| GrafanaPod
    TraefikPod -->|LB 172.18.255.210:5432| PG1Pod

    style DockerHost fill:#f5f5f5
    style KindCluster fill:#e8f5e9
    style ControlPlane fill:#fff3e0
    style InfraNodes fill:#e3f2fd
    style AppNodes fill:#fce4ec
    style PGNodes fill:#f3e5f5
```

### 1.2 Network Architecture

```mermaid
graph LR
    subgraph KindNetwork["Kind Network (172.18.0.0/16)"]
        subgraph MetalLBPool["MetalLB IP Pool"]
            TraefikIP["172.18.255.200<br/>HTTP/HTTPS"]
            PGIP["172.18.255.210<br/>PostgreSQL TCP"]
        end
    end

    subgraph ExternalAccess["External Access"]
        Browser["Browser"]
        PSQL["psql Client"]
    end

    Browser -->|HTTP/HTTPS| TraefikIP
    PSQL -->|TCP :5432| PGIP

    TraefikIP -->|HTTP routing| GrafanaSvc["grafana-service:3000"]
    TraefikIP -->|HTTP routing| TraefikDash["Traefik Dashboard"]
    PGIP -->|TCP routing| PoolerSvc["pooler-local-rw:5432"]
    PGIP -->|TCP routing| PGSvc["pg-local-rw:5432"]
```

**Key networking details:**
- MetalLB provides LoadBalancer IPs from the Kind network subnet
- Traefik gets two IPs: `172.18.255.200` (HTTP/HTTPS) and `172.18.255.210` (PostgreSQL TCP)
- External containers (step-ca, Vault, Dex, RustFS) are connected to the Kind network and wired via headless K8s Services/Endpoints
- sslip.io DNS pattern used for TLS certificates (e.g., `grafana.172-18-255-200.sslip.io`)

---

## 2. PKI & Certificate Architecture

### 2.1 3-Tier PKI Hierarchy

```mermaid
graph TD
    subgraph Tier1["Tier 1: Root CA"]
        RootCA["step-ca Root CA<br/>Self-signed<br/>Container: step-ca<br/>Port: 8443"]
    end

    subgraph Tier2["Tier 2: Intermediate CAs"]
        StepIntCA["step-ca Intermediate CA<br/>Signed by Root CA<br/>Container: step-ca"]
        VaultIntCA["Vault Intermediate CA<br/>Signed by step-ca Int CA<br/>Container: Vault"]
    end

    subgraph Tier3["Tier 3: Leaf Certificates"]
        VaultCert["Vault TLS cert<br/>Signed by step-ca Int CA<br/>(direct, not via Vault PKI)"]
        DexCert["Dex TLS cert<br/>Signed by Vault Int CA"]
        TraefikCert["Traefik Dashboard cert<br/>Signed by Vault Int CA"]
        ClusterCerts["In-cluster TLS certs<br/>Issued by cert-manager<br/>via Vault PKI ClusterIssuer"]
        MTLSCerts["mTLS client certs<br/>Issued by cert-manager<br/>via Vault PKI ClusterIssuer"]
    end

    RootCA -->|signs| StepIntCA
    StepIntCA -->|signs| VaultIntCA
    StepIntCA -->|signs directly| VaultCert
    VaultIntCA -->|issues via Vault PKI| DexCert
    VaultIntCA -->|issues via Vault PKI| TraefikCert
    VaultIntCA -->|issues via Vault PKI| ClusterCerts
    VaultIntCA -->|issues via Vault PKI| MTLSCerts

    style RootCA fill:#F44336,color:white
    style StepIntCA fill:#FF9800,color:white
    style VaultIntCA fill:#2196F3,color:white
```

### 2.2 Certificate Distribution

```mermaid
flowchart LR
    subgraph step-ca-container["step-ca Container"]
        RootCert["Root CA cert"]
        IntCert["Intermediate CA cert"]
    end

    subgraph trust-mgr["trust-manager"]
        Bundle["Bundle: step-ca-bundle<br/>(root + intermediate)"]
        VaultBundle["Bundle: vault-pki-bundle<br/>(root + step-ca int + vault int)"]
    end

    subgraph cert-mgr["cert-manager"]
        ClusterIssuer["ClusterIssuer: vault-pki<br/>(AppRole auth → Vault PKI)"]
    end

    subgraph namespaces["All Namespaces"]
        NSCerts["CA bundles as ConfigMaps/Secrets"]
        LeafCerts["Leaf TLS certificates"]
    end

    RootCert --> Bundle
    IntCert --> Bundle
    Bundle -->|distributed to| NSCerts
    VaultBundle -->|distributed to| NSCerts
    ClusterIssuer -->|issues| LeafCerts
```

**Implementation details:**
- `step-ca-bundle` ConfigMap contains root + intermediate CA certs, distributed by trust-manager to all namespaces
- `vault-pki-bundle` Secret contains the full chain (root + step-ca int + vault int), distributed by trust-manager
- cert-manager uses Vault AppRole authentication (role ID + secret ID stored in K8s Secrets) to issue leaf certificates
- Vault's PKI backend is configured with `vault-pki` role for in-cluster cert issuance (168h TTL for mTLS, longer for server certs)

---

## 3. Secrets Management Architecture

### 3.1 ESO + Vault Flow

```mermaid
sequenceDiagram
    participant Vault as HashiCorp Vault
    participant ESO as External Secrets Operator
    participant K8sSecret as Kubernetes Secret
    participant CNPG as CNPG Operator
    participant PG as PostgreSQL

    Note over Vault,PG: Setup Phase
    Vault->>Vault: Enable KV v2 at cnpg/
    Vault->>Vault: Write cnpg/pg-local/superuser
    Vault->>Vault: Write cnpg/pg-local/app
    Vault->>Vault: Write cnpg/pg-local/readonly
    Vault->>Vault: Create AppRole for ESO

    Note over Vault,PG: Sync Phase
    ESO->>Vault: Authenticate via AppRole
    Vault->>ESO: Return token
    ESO->>Vault: Read cnpg/pg-local/superuser
    Vault->>ESO: Return {username, password}
    ESO->>K8sSecret: Create Secret pg-local-superuser
    ESO->>Vault: Read cnpg/pg-local/app
    Vault->>ESO: Return {username, password}
    ESO->>K8sSecret: Create Secret pg-local-app
    ESO->>Vault: Read cnpg/pg-local/readonly
    Vault->>ESO: Return {username, password}
    ESO->>K8sSecret: Create Secret pg-local-readonly

    Note over Vault,PG: Bootstrap Phase
    CNPG->>K8sSecret: Read pg-local-superuser
    CNPG->>K8sSecret: Read pg-local-app
    CNPG->>K8sSecret: Read pg-local-readonly
    CNPG->>PG: Create cluster with Vault-managed credentials

    Note over Vault,PG: Rotation Phase
    Vault->>Vault: kv patch cnpg/pg-local/app password=newpass
    ESO->>Vault: Detect change (poll interval)
    ESO->>K8sSecret: Update Secret pg-local-app
    CNPG->>K8sSecret: Detect Secret change
    CNPG->>PG: Reconcile credentials
```

### 3.2 ExternalSecret Resources

| ExternalSecret | Vault Path | K8s Secret | Fields |
|---------------|-----------|------------|--------|
| pg-local-superuser | `cnpg/pg-local/superuser` | pg-local-superuser | username, password |
| pg-local-app | `cnpg/pg-local/app` | pg-local-app | username, password |
| pg-local-readonly | `cnpg/pg-local/readonly` | pg-local-readonly | username, password |

**ClusterSecretStore:** `vault-approle` — uses Vault AppRole authentication with role ID and secret ID stored in K8s Secrets.

---

## 4. PostgreSQL Architecture

### 4.1 Cluster Topology

```mermaid
graph TD
    subgraph CNPGOperator["CNPG Operator (cnpg-system)"]
        Operator["cloudnative-pg:1.29.0"]
        BarmanPlugin["Barman Cloud Plugin:v0.12.0"]
    end

    subgraph PGCluster["pg-local Cluster (default namespace)"]
        Primary["pg-local-1<br/>Role: Primary<br/>Node: k8s-local-worker4"]
        Replica1["pg-local-2<br/>Role: Replica<br/>Node: k8s-local-worker5"]
        Replica2["pg-local-3<br/>Role: Replica<br/>Node: k8s-local-worker6"]
        PoolerRW["pooler-local-rw<br/>PgBouncer (2 replicas)<br/>Read-Write routing"]
    end

    subgraph Services["K8s Services"]
        RW["pg-local-rw<br/>→ Primary only"]
        RO["pg-local-ro<br/>→ Replicas only"]
        R["pg-local-r<br/>→ Any instance"]
        PoolerSvc["pooler-local-rw<br/>→ PgBouncer"]
    end

    subgraph Backup["Backup"]
        ObjectStore["ObjectStore CR<br/>→ RustFS S3"]
        SchedBackup["ScheduledBackup CR<br/>→ Barman Cloud Plugin"]
    end

    Primary -->|streaming replication| Replica1
    Primary -->|streaming replication| Replica2
    Primary -->|backup via Barman| ObjectStore
    ObjectStore -->|S3 protocol| RustFS["RustFS :9000"]

    PoolerRW -->|connection pooling| Primary
    RW --> Primary
    RO --> Replica1
    RO --> Replica2
    R --> Primary
    R --> Replica1
    R --> Replica2

    style Primary fill:#4CAF50,color:white
    style Replica1 fill:#2196F3,color:white
    style Replica2 fill:#2196F3,color:white
```

### 4.2 ESO Demo Cluster (demo-local-db namespace)

```mermaid
graph TD
    subgraph ESOCluster["pg-local Cluster (demo-local-db namespace)"]
        ESOPrimary["pg-local-1<br/>Primary<br/>Node: k8s-local-worker6"]
        ESOReplica1["pg-local-2<br/>Replica<br/>Node: k8s-local-worker5"]
        ESOReplica2["pg-local-3<br/>Replica<br/>Node: k8s-local-worker4"]
        ESOPooler["pooler-local-rw<br/>PgBouncer (2 replicas)"]
    end

    subgraph MTLS["mTLS Infrastructure"]
        ServerCert["pg-local-server-tls<br/>Server certificate"]
        ReplCert["pg-local-replication-tls<br/>Replication certificate"]
        TLSTermCert["pg-local-tls-term-server<br/>TLS termination cert"]
        PoolerClientCert["pg-local-pooler-client-tls<br/>Pooler client cert"]
        PoolerServerCert["pg-local-pooler-server-tls<br/>Pooler server cert"]
    end

    subgraph TraefikRoutes["Traefik TCP Routes"]
        TLSTerm["IngressRouteTCP: TLS termination<br/>pg-local-demo-local-db-t.IP.sslip.io:5432"]
        TLSPass["IngressRouteTCP: TLS passthrough<br/>pg-local-demo-local-db-p.IP.sslip.io:5432"]
    end

    subgraph VaultSecrets["Vault-Managed Secrets"]
        VaultSU["cnpg/pg-local/superuser"]
        VaultApp["cnpg/pg-local/app"]
        VaultRO["cnpg/pg-local/readonly"]
    end

    ESOPrimary -->|streaming replication| ESOReplica1
    ESOPrimary -->|streaming replication| ESOReplica2
    ESOPooler -->|connection pooling| ESOPrimary

    VaultSecrets -->|ESO sync| ESOCluster
    MTLS -->|cert-manager| ESOCluster
    TLSTerm --> ESOPooler
    TLSPass --> ESOPrimary

    style ESOPrimary fill:#9C27B0,color:white
    style ESOReplica1 fill:#FF9800,color:white
    style ESOReplica2 fill:#FF9800,color:white
```

### 4.3 Node Placement Strategy

```mermaid
graph LR
    subgraph Nodes["Kind Cluster Nodes"]
        CP["k8s-local-control-plane<br/>Control Plane"]
        W1["k8s-local-worker<br/>infra + app"]
        W2["k8s-local-worker2<br/>app"]
        W3["k8s-local-worker3<br/>app"]
        W4["k8s-local-worker4<br/>postgres"]
        W5["k8s-local-worker5<br/>postgres"]
        W6["k8s-local-worker6<br/>postgres"]
    end

    subgraph InfraWorkloads["Infra Workloads"]
        Traefik["Traefik"]
        CertMgr["cert-manager"]
        ESO["ESO"]
        MetalLB["MetalLB"]
    end

    subgraph AppWorkloads["App Workloads"]
        Prom["Prometheus"]
        Grafana["Grafana"]
        Loki["Loki"]
        Mimir["Mimir"]
        Tempo["Tempo"]
        OTel["OTel"]
        Alloy["Alloy"]
    end

    subgraph PGWorkloads["PostgreSQL Workloads"]
        PG1["pg-local-1 (Primary)"]
        PG2["pg-local-2 (Replica)"]
        PG3["pg-local-3 (Replica)"]
        Pooler["PgBouncer"]
    end

    W1 --> InfraWorkloads
    W2 --> AppWorkloads
    W3 --> AppWorkloads
    W4 --> PG1
    W5 --> PG2
    W6 --> PG3
    W1 --> Pooler
    W3 --> Pooler
```

**Taints and tolerations:**
- `node-role.kubernetes.io/postgres` nodes have taints that only allow CNPG pods
- `node-role.kubernetes.io/infra` nodes host infrastructure components
- `node-role.kubernetes.io/app` nodes host observability and application workloads

---

## 5. Observability Stack Architecture

### 5.1 Data Flow

```mermaid
flowchart TD
    subgraph Targets["Scrape Targets"]
        CNPGMetrics["CNPG Pods<br/>(PostgreSQL metrics)"]
        K8sMetrics["K8s Nodes<br/>(node-exporter)"]
        K8sState["K8s Objects<br/>(kube-state-metrics)"]
        TraefikMetrics["Traefik<br/>(access logs + traces)"]
        AppLogs["Application Logs<br/>(all pods)"]
    end

    subgraph Collection["Collection Layer"]
        Prom["Prometheus v3.10.0<br/>(scrape + remoteWrite)"]
        Alloy["Alloy v1.16.0<br/>(log collection)"]
        OTel["OTel Collector 0.151.0<br/>(tail-based sampling)"]
    end

    subgraph LongTerm["Long-term Storage"]
        Mimir["Mimir 2.16.0<br/>(3-zone distributed)<br/>S3 backend: RustFS"]
        Loki["Loki 3.7.1<br/>(single-binary)<br/>S3 backend: RustFS"]
        Tempo["Tempo 2.10.5<br/>(distributed)<br/>S3 backend: RustFS"]
    end

    subgraph Visualization["Visualization"]
        Grafana["Grafana 12.4.1<br/>(5 datasources, 10 dashboards)"]
    end

    CNPGMetrics --> Prom
    K8sMetrics --> Prom
    K8sState --> Prom
    AppLogs --> Alloy
    TraefikMetrics --> OTel

    Prom -->|remoteWrite| Mimir
    Prom -->|direct query| Grafana
    Alloy -->|push| Loki
    OTel -->|push| Tempo

    Mimir -->|S3 blocks| RustFS["RustFS S3"]
    Loki -->|S3 chunks| RustFS
    Tempo -->|S3 blocks| RustFS

    Grafana -->|query| Mimir
    Grafana -->|query| Loki
    Grafana -->|query| Tempo
    Grafana -->|query| Prom
```

### 5.2 Mimir Distributed Architecture

```mermaid
graph TD
    subgraph Mimir["Mimir (mimir namespace)"]
        direction TB
        Distributor["distributor<br/>(1 replica)"]
        IngesterA["ingester-zone-a<br/>(StatefulSet)"]
        IngesterB["ingester-zone-b<br/>(StatefulSet)"]
        IngesterC["ingester-zone-c<br/>(StatefulSet)"]
        Querier["querier<br/>(1 replica)"]
        QueryFrontend["query-frontend<br/>(1 replica)"]
        QueryScheduler["query-scheduler<br/>(1 replica)"]
        StoreGatewayA["store-gateway-zone-a<br/>(StatefulSet)"]
        StoreGatewayB["store-gateway-zone-b<br/>(StatefulSet)"]
        StoreGatewayC["store-gateway-zone-c<br/>(StatefulSet)"]
        Compactor["compactor<br/>(StatefulSet)"]
        Alertmanager["alertmanager<br/>(StatefulSet)"]
        Ruler["ruler<br/>(1 replica)"]
        Nginx["nginx<br/>(1 replica)"]
        OverridesExporter["overrides-exporter<br/>(1 replica)"]
        RolloutOperator["rollout-operator<br/>(1 replica)"]
    end

    Prom["Prometheus"] -->|remoteWrite| Distributor
    Distributor --> IngesterA
    Distributor --> IngesterB
    Distributor --> IngesterC
    Querier --> StoreGatewayA
    Querier --> StoreGatewayB
    Querier --> StoreGatewayC
    QueryFrontend --> Querier
    QueryScheduler --> QueryFrontend
    Grafana["Grafana"] -->|query| Nginx
    Nginx --> QueryFrontend

    IngesterA -->|S3| RustFS["RustFS"]
    StoreGatewayA -->|S3| RustFS
    Compactor -->|S3| RustFS
```

### 5.3 Grafana Datasources

| Datasource | Type | URL | Purpose |
|-----------|------|-----|---------|
| mimir | Prometheus | `http://mimir-nginx.mimir.svc.cluster.local/api/v1/push` | Long-term metrics via Mimir |
| mimir-tempo | Prometheus | `http://mimir-nginx.mimir.svc.cluster.local/api/v1/push` | Tempo metrics via Mimir |
| prometheus | Prometheus | `http://prometheus-operated.prometheus-operator.svc.cluster.local:9090` | Short-term metrics |
| loki | Loki | `http://loki.grafana.svc.cluster.local:3100` | Log aggregation |
| tempo | Tempo | `http://tempo-query-frontend.tempo.svc.cluster.local:3200` | Distributed tracing |

---

## 6. Operational Procedures

### 6.1 Credential Rotation

```bash
# Rotate the 'app' credential
./demo/eso-vault.sh rotate local app

# This:
# 1. Generates a new password in Vault (kv patch cnpg/pg-local/app)
# 2. Forces ESO sync (annotate externalsecret with force-sync timestamp)
# 3. Waits for K8s Secret to update (checks resourceVersion)
# 4. Verifies connectivity with new credentials
```

### 6.2 Verify Connectivity

```bash
# Test psql connectivity for each credential tier
./demo/eso-vault.sh verify local superuser
./demo/eso-vault.sh verify local app
./demo/eso-vault.sh verify local readonly
```

### 6.3 Teardown

```bash
# Remove ESO demo only (keeps infrastructure)
./demo/eso-vault.sh teardown local

# Remove everything (clusters, containers, volumes)
./scripts/teardown.sh
```

### 6.4 Accessing Services

```bash
# Get access URLs
./scripts/info.sh

# Port-forward Grafana (if Traefik not accessible)
kubectl port-forward service/grafana-service 3000:3000 -n grafana

# Port-forward PostgreSQL via PgBouncer
kubectl port-forward service/pooler-local-rw 5432:5432 -n default

# Direct psql via Traefik TCP (ESO demo)
psql "host=172.18.255.210 port=5432 user=app dbname=app sslmode=require"
```

---

## 7. Resource Requirements

### 7.1 Minimum Hardware

| Resource | Minimum | Recommended |
|----------|---------|-------------|
| CPU | 8 cores | 12+ cores |
| RAM | 16 GB | 24+ GB |
| Disk | 40 GB free | 80+ GB free |

### 7.2 Pod Count by Namespace

| Namespace | Pods | Purpose |
|-----------|------|---------|
| cert-manager | 4 | cert-manager, cainjector, webhook, trust-manager |
| cnpg-system | 2 | CNPG operator, Barman Cloud Plugin |
| default | 5 | pg-local (3 instances) + pooler (2 replicas) |
| demo-local-db | 5 | pg-local (3 instances) + pooler (2 replicas) |
| external-secrets | 3 | ESO controller, cert-controller, webhook |
| grafana | 5 | Grafana, operator, Loki, Alloy, canary (×2) |
| metallb-system | 5 | controller + speakers (per node) |
| mimir | 14 | Full distributed stack |
| otel | 1 | OTel Collector |
| prometheus-operator | 9 | Prometheus, operator, kube-state-metrics, node-exporters |
| tempo | 6 | Distributed tracing stack |
| traefik | 1 | Ingress controller |
| **Total** | **~60** | |

### 7.3 Key Configuration Files

| File | Purpose |
|------|---------|
| `k8s/kind-cluster.yaml` | Kind cluster topology (7 nodes, taints, labels) |
| `scripts/common.sh` | Shared variables, versions, helper functions |
| `traefik/values.yaml` | Traefik Helm values |
| `monitoring/mimir/mimir-values.yaml` | Mimir distributed configuration |
| `monitoring/loki/loki-values.yaml` | Loki single-binary configuration |
| `monitoring/tempo/tempo-values.yaml` | Tempo distributed configuration |
| `monitoring/alloy/alloy-config.river` | Alloy log collection pipeline |
| `monitoring/otel-collector/otel-collector-values.yaml` | OTel Collector configuration |
| `demo/yaml/local/pg-local.yaml.tpl` | CNPG cluster definition (basic demo) |
| `demo/yaml/local/pg-local-eso.yaml.tpl` | CNPG cluster definition (ESO demo) |
| `vault/cert-manager/clusterissuer.yaml.tpl` | cert-manager Vault PKI ClusterIssuer |
| `vault/eso/` | ESO ClusterSecretStore templates |