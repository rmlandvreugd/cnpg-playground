# Self-Service Database Demo

Demonstrates Vault-backed dynamic credentials, ESO-managed static secrets, CNPG cluster provisioning, Traefik TCP passthrough, pgAdmin, and Grafana with Authelia OIDC — scoped to a single tenant (`rbr`) and group (`rbr/ver`).

Vault and Authelia run as **host Docker containers** and are reached in-cluster through the **`traefik-edge`** proxy (`vault.172-18-0-250.sslip.io` / `authelia.172-18-0-250.sslip.io`) — there is no in-cluster `vault` Service. The Postgres data plane, by contrast, goes through the in-cluster Traefik LoadBalancer.

## Architecture

```mermaid
graph TB
    subgraph host["Host containers (kind bridge 172.18.0.0/16)"]
        Vault["Vault\ndev-tls :8200\nKV + DB Engine + PKI"]
        Authelia["Authelia\nOIDC IDP + forward-auth"]
        Edge["traefik-edge\n172.18.0.250:443\nTLS-terminates vault.* / authelia.*"]
        Seaweed["SeaweedFS\nseaweedfs :8333\ns3://verstappen-backups"]
    end

    subgraph k8s["Kind cluster (local)"]
        subgraph traefik-ns["traefik"]
            LB["Traefik LoadBalancer\nports 80/443/5432"]
        end

        subgraph eso-ns["external-secrets"]
            ESO["ESO"]
            CSS["ClusterSecretStore\nvault-approle-rbr(+ -db)\n(AppRole eso-rbr-local)"]
        end

        subgraph rbr_ver_db["rbr-ver-db"]
            ES["ExternalSecrets\nverstappen-{superuser,app,readonly}"]
            CNPG["Cluster: verstappen\nPostgreSQL + pgaudit\ndatabase: max"]
            ObjStore["seaweedfs\nService+Endpoints → SeaweedFS"]
            Backup["ScheduledBackup\n+ ObjectStore CR"]
        end

        subgraph pgadmin_ns["pgadmin"]
            PgAdmin["pgadmin-rbr-ver\npreloaded server config"]
        end

        subgraph grafana_ns["grafana"]
            GrafanaRBR["grafana-rbr-ver\nGeneric OAuth via Authelia\norg: rbr"]
            Loki["Loki\nS3 backend → SeaweedFS"]
            Alloy["Alloy\nCNPG pod log scraper"]
        end
    end

    CSS ==>|"AppRole auth via sslip.io"| Edge
    Edge -->|"vault.172-18-0-250.sslip.io"| Vault
    Edge -->|"authelia.172-18-0-250.sslip.io"| Authelia
    CSS --> ES
    ES -->|"K8s Secrets\n+ cnpg.io/reload"| CNPG
    Vault -->|"DB Engine\ndynamic creds (TTL 1h)"| CNPG
    LB -->|"IngressRouteTCP\nSNI passthrough :5432"| CNPG
    LB -->|"IngressRoute HTTP"| PgAdmin
    LB -->|"IngressRoute HTTPS"| GrafanaRBR
    GrafanaRBR ==>|"OIDC via sslip.io"| Edge
    Authelia -->|"OIDC token\n(groups claim)"| GrafanaRBR
    CNPG -->|"pgaudit log lines"| Alloy
    Alloy -->|"structured logs"| Loki
    CNPG --> Backup
    Backup --> ObjStore
    ObjStore --> Seaweed
    Loki --> Seaweed
```

### Component Roles

| Component | Role |
|---|---|
| Vault KV (`cnpg/rbr/ver/`) | Static credentials for superuser, app, readonly |
| Vault DB Engine | Dynamic credentials: `rbr-db-admin` (1h), `rbr-ver-db-admin` (1h), `rbr-ver-db-readonly` (1h) |
| ESO ClusterSecretStore | Syncs KV secrets to K8s Secrets; AppRole scoped to `cnpg/data/rbr/ver/*`; reaches Vault via edge `vault.172-18-0-250.sslip.io` |
| CNPG Cluster `verstappen` | 3-replica PostgreSQL 18, database `max`, pgaudit enabled, barman backups |
| `rbr_ver_ddl_owner` | Stable DDL owner role; all objects must be owned by this role |
| `rbr_ver_ddl_admin` | Has `rbr_ver_ddl_owner`; VDE admin/group-admin dynamic users inherit via `IN ROLE` |
| `rbr_ver_vde_admin` | Static VDE admin user for Vault DB Engine connection (non-rotating) |
| Traefik TCP | SNI passthrough on port 5432; sslmode=require enforced end-to-end |
| pgAdmin `pgadmin-rbr-ver` | Preloaded server config; credentials pasted manually from `creds` subcommand |
| Authelia | OIDC IDP + forward-auth; host container fronted by `traefik-edge` (`authelia.172-18-0-250.sslip.io`); `groups` claim from `authelia/config/users_database.yml` |
| `grafana-rbr-ver` | Grafana Operator CR; Generic OAuth; org `rbr` pre-created; `grafana-rbr-ver` Authelia OIDC client |
| Loki | Single-binary log store; S3 backend on SeaweedFS; deployed by `monitoring/setup.sh` |
| Alloy | Tails CNPG pod logs via K8s API; extracts pgaudit labels; pushes to Loki |

---

## Prerequisites

Base setup must be complete before running the self-service demo. `scripts/setup.sh` builds the
cluster **and the platform governance layer** (Capsule, capsule-proxy, Kyverno, ArgoCD, gangplank)
but creates **no tenant** — there is no `Tenant rbr`, no `rbr-ver*` namespaces, and no ArgoCD
app-of-apps until the self-service script runs. Canonical order:

```bash
./scripts/setup.sh local          # Kind cluster + platform (Capsule/Kyverno/ArgoCD/gangplank) — no tenant
./monitoring/setup.sh local       # kube-prometheus-stack, Grafana Operator, Loki, Alloy
./demo/self-service-setup.sh setup local   # tenant onboarding (see Runbook below)
```

Monitoring is a **hard requirement**: `self-service-setup.sh setup` preflights for the `grafana`
namespace + Grafana operator CRD and aborts with a clear message if monitoring is not installed.

One-shot equivalent: `./scripts/setup.sh local --with-tenant` chains all three steps.

Verify Traefik has a LoadBalancer IP:

```bash
kubectl get svc traefik -n traefik --context kind-k8s-local \
    -o jsonpath='{.status.loadBalancer.ingress[0].ip}'
```

---

## Runbook: Setup

```bash
./demo/self-service-setup.sh setup local
```

What it does (in order):

1. **Preflight** — hard-requires the platform (`tenants.capsule.clastix.io` CRD + `argocd` namespace) and monitoring (`grafana` namespace + Grafana operator CRD); aborts with a pointer to the right script if either is missing.
2. **Vault policies** — `eso-rbr-ver`, `rbr-db-admin`, `rbr-ver-db-admin`, `rbr-ver-db-readonly`
3. **ESO AppRole** `eso-rbr-local` — K8s Secret `vault-approle-rbr-creds` in `external-secrets`; `ClusterSecretStore vault-approle-rbr` + `vault-approle-rbr-db` applied
4. **Vault KV seed** — `cnpg/rbr/ver/{superuser,app,readonly}` with random passwords
5. **Tenant `rbr` pre-seed** — applies `manifests/capsule-tenant-rbr.yaml`, waits `status.state=Active` (ArgoCD's `tenant-rbr` app adopts it on later sync)
6. **Tenant namespaces** — `rbr-ver-db`, `rbr-ver` created **as the Capsule tenant owner** (`--as=capsule-bot --as-group=oidc:rbr-db-admin …`) so Capsule injects the `ownerReference`; labelled `capsule.clastix.io/tenant=rbr`
7. **Objectstore wiring** — `seaweedfs` Service+Endpoints in `rbr-ver-db` pointing to the SeaweedFS container; objectstore Secret; ObjectStore CR (`s3://verstappen-backups`) + custom monitoring ConfigMap
8. **CNPG Cluster + Pooler + ScheduledBackup** — `verstappen` cluster; `pooler-verstappen-rw` (pinned to app nodes); waits up to 30m for Ready
9. **Traefik TCP IngressRoute** — SNI passthrough on `verstappen-rbr-ver-db.<IP>.sslip.io:5432`
10. **Stable PostgreSQL roles** — `rbr_ver_ddl_owner`, `rbr_ver_ddl_admin`, `rbr_ver_ddl_reader` with grants
11. **VDE admin role** — `rbr_ver_vde_admin` with CREATEROLE; password in Vault KV `cnpg/rbr/ver/vde-admin`
12. **Vault DB Engine** — config `rbr-ver-max` (sslip.io endpoint, TLS); rotate-root; static role `app` (24h rotation); dynamic roles `rbr-db-admin`, `rbr-ver-db-admin`, `rbr-ver-db-readonly`
13. **demo-app image build + `kind load`** — built from `app/`, tagged with the chart `appVersion`, loaded into the Kind cluster
14. **ArgoCD app-of-apps** — applies `manifests/argocd/root-app.yaml` (`rbr-root`), waits for sync, patches `demo-app` with `global.traefikIpDashed`. Runs **last** (after the DB + `verstappen-app` secret exist) so `demo-app` comes up healthy on its app node instead of crash-looping
15. **pgAdmin** — `pgadmin-rbr-ver` Deployment in `pgadmin` namespace; servers.json ConfigMap preloaded; HTTP IngressRoute
16. **Grafana + Authelia** — issues TLS cert; deploys `grafana-rbr-ver` CR with Generic OAuth (Authelia); applies Prometheus + Loki datasources + pgaudit dashboard; HTTPS IngressRoute; pre-creates `rbr` org via API

Setup output includes the full access summary:

```
✅ Setup complete
   Cluster:     verstappen  Namespace: rbr-ver-db
   External DB: verstappen-rbr-ver-db.<IP>.sslip.io:5432
   sslmode:     require

   pgAdmin:     http://pgadmin-rbr-ver.<IP>.sslip.io
   Email:       admin@example.com
   Password:    <generated>

   Grafana:     https://grafana-rbr-ver.<IP>.sslip.io
```

---

## Runbook: Verify

```bash
./demo/self-service-setup.sh verify local
```

Connects as superuser via internal cluster DNS and runs `SELECT current_user, version();`.

---

## Using the Demo: pgAdmin

> **Note:** pgAdmin in server mode does not support pre-stored passwords via `PasswordExecCommand`. Credentials must be pasted manually at connect time.

### Workflow

1. Get dynamic credentials:

   ```bash
   ./demo/self-service-setup.sh creds local group-admin
   # or
   ./demo/self-service-setup.sh creds local tenant-admin
   ```

   Output includes `username` and `password` from Vault DB Engine (TTL 1h).

2. Open pgAdmin at `http://pgadmin-rbr-ver.<IP>.sslip.io`

3. Login with credentials printed by `setup` (email + generated password).

4. The server `verstappen (rbr-ver)` is pre-configured. Click **Connect**, paste the Vault username and password.

5. **Before any DDL**, run in the query tool:

   ```sql
   SET ROLE rbr_ver_ddl_owner;
   ```

   This ensures all created objects are owned by the stable role, not the dynamic VDE user. If DDL runs without this, objects become owned by the ephemeral user — dropping the user will fail until objects are reassigned.

6. Credentials expire after 1h. Repeat from step 1 to reconnect.

---

## Using the Demo: Grafana

### Personas

| Email | Authelia groups | Grafana org | Role |
|---|---|---|---|
| `rbr-admin@example.com` | `rbr-db-admin`, `rbr-ver-db-admin` | `rbr` | Admin |
| `rbr-ver-admin@example.com` | `rbr-ver-db-admin` | `rbr` | Editor |
| `unrelated@example.com` | (none) | (none) | — |

All use the default password (`password`); groups are defined in `authelia/config/users_database.yml`.

### Login Flow

1. Open `https://grafana-rbr-ver.<IP>.sslip.io`
2. Click **Sign in with Authelia** — Grafana redirects to `authelia.172-18-0-250.sslip.io` (via `traefik-edge`)
3. Log in with one of the email/password pairs above
4. Grafana places you in org `rbr` with the mapped role

### Available Dashboards

- **CloudNativePG** — cluster health, replication lag, connection counts
- **pgaudit Audit Logs** — audit event rate + log stream from Loki (active once Alloy is running and pgaudit events are emitted)

### Org Isolation Note

The `rbr` org provides logical isolation within the Grafana instance. **Folder-level isolation** (restricting dashboard access by role within an org) requires **Grafana Enterprise**. This demo uses OSS — all users in org `rbr` see all dashboards in that org.

---

## Runbook: Rotate Credential

Rotates an ESO-managed static credential (app or readonly):

```bash
./demo/self-service-setup.sh rotate local app
./demo/self-service-setup.sh rotate local readonly
```

1. Patches Vault KV with a new random password
2. Annotates the ExternalSecret to force immediate sync
3. Waits for the K8s Secret's `resourceVersion` to change
4. Verifies the new credential via psql from a pod in `rbr-ver` namespace

The `cnpg.io/reload: "true"` label on the Secret template triggers CNPG to reload credentials without a restart.

---

## Runbook: On-Demand Backup

```bash
./demo/self-service-setup.sh backup local
```

Creates a `Backup` CR in `rbr-ver-db` namespace targeting the `verstappen` cluster via the barman-cloud plugin. Backups land in SeaweedFS under `s3://verstappen-backups/`.

Track progress:

```bash
kubectl get backup -n rbr-ver-db --context kind-k8s-local
```

> Backup covers PostgreSQL data only. K8s Secrets, TLS certificates, and ESO ExternalSecret resources are not included. Document recovery procedures separately.

---

## Runbook: Get Dynamic Credentials

```bash
# Tenant admin (rbr-db-admin role, access to rbr-ver-db-admin too)
./demo/self-service-setup.sh creds local tenant-admin

# Group admin (rbr-ver-db-admin role)
./demo/self-service-setup.sh creds local group-admin

# Readonly
./demo/self-service-setup.sh creds local readonly
```

Output is the raw `vault read database/creds/<role>` output including `username`, `password`, `lease_id`, and `lease_duration`.

All dynamic credentials expire after 1h (max 4h). Connection string:

```
host=verstappen-rbr-ver-db.<IP>.sslip.io
port=5432
dbname=max
sslmode=require
user=<username from vault>
password=<password from vault>
```

---

## Runbook: Teardown

```bash
./demo/self-service-setup.sh teardown local
```

Removes (in order):

- ArgoCD app-of-apps `rbr-root` Application (cascade-deletes child apps `demo-app`, `grafana-rbr-ver`, `kyverno-policies`, `tenant-rbr`) + AppProject `rbr` — done **first** so ArgoCD stops reconciling while teardown runs
- `verstappen` Cluster, `pooler-verstappen-rw` Pooler, ObjectStore, and ExternalSecrets in `rbr-ver-db` (finalizers awaited)
- Namespaces `rbr-ver-db` and `rbr-ver` (deletes all remaining resources including backups, PVCs)
- `ClusterSecretStore vault-approle-rbr` + `vault-approle-rbr-db`
- Secret `vault-approle-rbr-creds` in `external-secrets`
- `IngressRouteTCP postgres-rbr-ver` in `traefik`
- pgAdmin Deployment, Service, ConfigMap, Secret, IngressRoute in `pgadmin`
- Grafana CR, datasources, dashboard, TLS cert, OAuth Secret, IngressRoute in `grafana`
- Capsule `Tenant rbr` — done **last**, after all tenant-owned namespaces/resources are gone (idempotent; may already be cascade-removed via the `tenant-rbr` app)

**Not removed** (platform stays intact — only `scripts/teardown.sh` nukes the whole cluster):

- The platform layer (Capsule, capsule-proxy, Kyverno, ArgoCD, gangplank) installed by `scripts/setup.sh`
- Vault VDE config (`database/config/rbr-ver-max`), roles, and policies — retained for post-demo inspection
- Vault KV paths (`cnpg/rbr/ver/`)
- Authelia config — not reconfigured by teardown

Clean up Vault manually after the demo:

```bash
# Remove VDE config (revokes all outstanding leases)
vault delete database/config/rbr-ver-max

# Remove KV paths
vault kv delete cnpg/rbr/ver/superuser
vault kv delete cnpg/rbr/ver/app
vault kv delete cnpg/rbr/ver/readonly
vault kv delete cnpg/rbr/ver/vde-admin
```

---

## Caveats

- **pgAdmin credentials are manual paste.** The `PasswordExecCommand` hook is disabled in server mode; there is no automatic credential injection. Extending this with an init container that populates `.pgpass` from Vault at pod startup is a valid next step.
- **Grafana org-level isolation only.** Folder permissions that restrict dashboards within an org require Grafana Enterprise. This demo uses OSS.
- **Dynamic credentials expire.** VDE leases are 1h (max 4h). Reconnect in pgAdmin after expiry by getting fresh creds with `creds local group-admin`.
- **Loki datasource unhealthy until monitoring stack runs.** The `GrafanaDatasource` for Loki is applied by `self-service-setup.sh`. It shows as unhealthy until `monitoring/setup.sh` installs Loki in the `grafana` namespace.
- **Authelia is reached via `traefik-edge`.** Both Grafana OIDC and human forward-auth hit `authelia.172-18-0-250.sslip.io`, TLS-terminated at the edge with a step-ca/Vault-PKI cert. Browsers warn on the login page unless the step-ca root is trusted. There is no in-cluster `authelia` or `vault` Service — the edge proxy fronts both host containers (see §2.1 of `architecture-overview.md`).
