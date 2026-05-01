# CNPG Self-Service Demo: Review, Research, Plan

Status: planning and research record  
Date: 2026-05-01  
Scope: local runnable demo plus architecture docs

This note turns `docs/samenvatting.md`, `docs/ontwerp.md`, and `docs/implementatie.md` into a repo-local demo direction. It deliberately records uncertainties instead of hiding them.

## Current Decisions

- Build both runnable demo and architecture documentation.
- Keep the existing demo unchanged by default.
- Add a new entry point, likely `demo/self-service-setup.sh`.
- Start with local region only.
- Simulate GitOps with checked-in manifests plus `kubectl apply`; do not install ArgoCD in the first slice.
- Keep the NCSC Helm chart out of scope for now.
- Use Formula 1 constructors as tenants and driver abbreviations as groups.
- First namespace: `rbr-ver-db`.
- App namespace: `rbr-ver`.
- Future examples: `rbr-had-db`, `mer-ant-db`.
- Constructor is tenant: `rbr`.
- Driver abbreviation is group: `ver`.
- Vault policy names:
  - tenant admin: `rbr-db-admin`
  - group admin: `rbr-ver-db-admin`
- Tenant admin and group admin get the same DB capability for `rbr-ver-db`; membership differs. Every tenant admin is also a group admin, but not every group admin is a tenant admin.
- Application credentials are static Vault KV values synced by ESO.
- Admin credentials are dynamic Vault Database Secrets Engine leases with TTL.
- Admin SQL capability is limited DDL, not full superuser.
- pgAdmin is simple and preconfigured first; do not store dynamic DB passwords unless no workable alternative exists.
- Include on-demand `Backup` manifest and keep scheduled backup too.
- NetworkPolicy is out of scope for first runnable slice.
- Monitoring should be a full separate Grafana demo on a separate URL, integrated with Dex.
- Docs can be mixed language, with `*-nl.md` variants.

## Review Findings

### Name Conflict

There is an unresolved naming conflict:

- One direction says database name is first name: `max`.
- Another direction says the database name for `rbr-ver-db` is `verstappen`.

Do not implement until this is resolved. Possible split:

- CNPG Cluster/service name: `verstappen`
- PostgreSQL database name: `max`
- External host: `verstappen-rbr-ver-db.<dashed-loadbalancer-ip>.sslip.io`

This preserves driver identity in Kubernetes while keeping the SQL database as first name. Confirm before implementation.

### Vault Network Path

The external Vault container should not use Kubernetes service DNS like `max-rw.rbr-ver-db.svc.cluster.local`. Use Traefik TCP on the load balancer instead.

Target pattern:

```text
<cluster-or-db-name>-<namespace>.<dashed-loadbalancer-ip>.sslip.io
```

Candidate first host:

```text
verstappen-rbr-ver-db.<dashed-loadbalancer-ip>.sslip.io
```

Risk: Traefik TCP host matching uses SNI. PostgreSQL only sends SNI when TLS is used and the client sets a hostname. VDE must connect with TLS enabled and hostname set.

### pgaudit Plan Correction

Do not manually force `shared_preload_libraries: [pgaudit]` unless needed. CloudNativePG automatically manages `shared_preload_libraries` and `CREATE EXTENSION` when `pgaudit.*` parameters are present.

Need runtime proof with the actual image and operator installed by this repo.

### pgAdmin Password Stance

pgAdmin `servers.json` cannot import/export passwords. It can define host, port, username, database, SSL parameters, and connection parameters such as `passfile`. Manual password entry after `vault read database/creds/...` is the clean first implementation.

### Grafana Isolation Boundary

Grafana OSS can map OAuth groups to org roles and org membership, but OAuth Team Sync is Enterprise or selected Grafana Cloud. For local OSS:

- use one org per tenant if practical
- use folders and provisioned dashboards
- use group-to-org mapping from Dex groups
- simulate tenant-scoped datasources with namespace labels
- document that hard datasource isolation is not fully proven unless datasource/query layer enforces it

## Researched Decisions

### 1. Traefik TCP Routing

Traefik `IngressRouteTCP` supports `HostSNI(...)` matching and TLS passthrough or TLS termination. For PostgreSQL, prefer TLS passthrough first so CNPG owns the database TLS endpoint.

Plan:

- add a Traefik TCP entrypoint for PostgreSQL, for example `postgres` on `:5432` or a non-conflicting demo port
- route `HostSNI("verstappen-rbr-ver-db.<dashed-ip>.sslip.io")`
- service target: `verstappen-rw` in namespace `rbr-ver-db`, port `5432`
- VDE `connection_url`: use that external host, not Kubernetes DNS
- first TLS mode: `sslmode=require`
- second TLS mode after CA/SAN validation is clear: `sslmode=verify-full`

Open research:

- Does CNPG-generated server cert contain the external sslip.io DNS name? Likely no.
- If no, `verify-full` needs user-provided server cert via cert-manager/Vault PKI with external DNS SAN.
- If CNPG operator verifies user-provided server certs against CA only for internal use, clients still need SAN correctness for `verify-full`.

### 2. Vault Database Secrets Engine

Vault PostgreSQL Database Secrets Engine fits the dynamic admin credential requirement. It creates leased users and revokes them when the lease expires.

Plan:

- enable `database` secrets engine if absent
- configure `database/config/rbr-ver-max-or-verstappen`
- create two Vault roles:
  - `rbr-db-admin`
  - `rbr-ver-db-admin`
- both roles create short-lived PostgreSQL users that inherit stable role `rbr_ver_ddl_admin`
- `default_ttl=1h`, `max_ttl=4h`
- no DB create
- no superuser
- no destructive admin power by default

Grant direction:

```sql
CREATE ROLE rbr_ver_ddl_admin NOLOGIN;
GRANT CONNECT ON DATABASE max TO rbr_ver_ddl_admin;
GRANT USAGE, CREATE ON SCHEMA public TO rbr_ver_ddl_admin;
ALTER DEFAULT PRIVILEGES IN SCHEMA public
  GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO rbr_ver_ddl_admin;
```

Concern: "no destructive actions" conflicts with broad DDL. A role that can create tables may later drop tables it owns. PostgreSQL cannot express "create but never drop own objects" cleanly with plain grants. Need decide acceptable limited DDL meaning.

Open research:

- Should limited DDL mean schema migration capability for app-owned schema, or read/write plus no DDL?
- Should dynamic admin users own created objects, or should creation happen through a stable owner role?
- What revocation SQL should reassign or clean owned objects on lease expiry?

### 3. pgaudit Runtime

CloudNativePG docs say managed extensions include `pgaudit`; adding a `pgaudit.*` parameter makes CNPG manage preload libraries and extension creation in connectable databases. CNPG PostgreSQL standard images are documented as including PGAudit.

Plan:

```yaml
postgresql:
  parameters:
    pgaudit.log: "ddl,role,misc_set"
    pgaudit.log_catalog: "off"
    pgaudit.log_relation: "on"
```

Runtime verification:

```bash
kubectl exec -n rbr-ver-db deploy/verstappen-rw -- psql -U postgres -d max -c \
  "SELECT extname FROM pg_extension WHERE extname = 'pgaudit';"

kubectl logs -n rbr-ver-db cluster/verstappen --since=10m | rg "AUDIT|pgaudit"
```

Adjust command after actual pod/service names are known.

Open research:

- Exact log query for CNPG pods in this repo.
- Whether adding `pgaudit.*` causes reload or rolling restart with current operator.
- Whether the current pulled `ghcr.io/cloudnative-pg/postgresql:18-standard-trixie` image includes `pgaudit` in this environment.

### 4. pgAdmin Preconfiguration

pgAdmin can load `/pgadmin4/servers.json` at first start in container mode. Password fields cannot be imported/exported. `ConnectionParameters.passfile` exists, but using it with Vault TTL credentials would require generating and refreshing a `.pgpass` file.

Plan:

- deploy separate pgAdmin for self-service
- preload one server:
  - host: `verstappen-rbr-ver-db.<dashed-ip>.sslip.io`
  - port: `5432`
  - maintenance DB: `max` or confirmed DB name
  - username: placeholder from latest Vault lease, or blank/manual
  - SSL mode: `require` first
- user flow:
  1. `vault read database/creds/rbr-ver-db-admin`
  2. open pgAdmin
  3. paste username/password

Pros:

- no expired secrets stored in pgAdmin
- easier to reason about audit trail
- matches TTL semantics

Cons:

- not as polished as automatic temporary PGAdmin
- user must copy credentials

Open research:

- Can `PasswordExecCommand` call a Vault helper safely inside pgAdmin?
- Is pgAdmin recreated per run enough to keep `servers.json` deterministic?

### 5. Grafana + Dex

Grafana Generic OAuth supports `groups_attribute_path`, `role_attribute_path`, `org_attribute_path`, and `org_mapping`. Team Sync is not OSS. Dex static clients and static users/groups can model tenant/group admin users.

Plan:

- deploy separate Grafana, not the existing monitoring Grafana
- expose as `selfservice-grafana.<dashed-ip>.sslip.io`
- add Dex static client:
  - client id: `selfservice-grafana`
  - redirect URI: `https://selfservice-grafana.<dashed-ip>.sslip.io/login/generic_oauth`
- add sample Dex users:
  - tenant admin: member of `rbr-db-admin` and `rbr-ver-db-admin`
  - group admin: member of `rbr-ver-db-admin`
  - unrelated user: no DB admin group
- Grafana org plan:
  - org: `rbr`
  - folders: `rbr-ver-db`, future `rbr-had-db`
  - dashboards: CNPG health, backup status, app credential rotation status, pgaudit pointers

Open research:

- Exact Dex template changes needed without breaking Vault OIDC.
- Whether current Dex config exposes groups in ID token, UserInfo, or both.
- Whether Grafana Operator is worth reusing or separate plain Deployment is simpler.
- Whether Loki exists in repo runtime; if not, pgaudit panel must be deferred or shell-based.

### 6. Backup Manifest

CloudNativePG currently supports `method: plugin` for CNPG-I plugins. The barman-cloud plugin uses `ObjectStore` CRDs and `pluginConfiguration`.

Plan:

- keep `ScheduledBackup`
- add manual manifest, for example `demo/yaml/self-service/rbr-ver-db/backup-on-demand.yaml`
- document apply/delete lifecycle

Candidate:

```yaml
apiVersion: postgresql.cnpg.io/v1
kind: Backup
metadata:
  name: max-manual
  namespace: rbr-ver-db
spec:
  method: plugin
  pluginConfiguration:
    name: barman-cloud.cloudnative-pg.io
  cluster:
    name: verstappen
```

Open research:

- Confirm installed barman plugin version accepts this manifest.
- Choose backup name strategy: static for demo reruns or timestamped by script.
- Decide if verification is docs-only or script command output.

### 7. ESO Rotation

CloudNativePG managed roles can use `passwordSecret`; the referenced Secret should contain `username` and `password`, and examples label it with `cnpg.io/reload: "true"`.

Plan:

- ESO refresh interval can remain normal.
- Add script option to force refresh/rotation for demo speed.
- Smoke test:
  1. connect as app user with old password
  2. rotate Vault KV app password
  3. force ESO sync
  4. wait for Secret update and CNPG role reconciliation
  5. old password fails
  6. new password succeeds

Open research:

- Exact ESO force-sync annotation for current ESO version.
- Exact CNPG status field for managed role reconciliation.
- Whether role password rotation needs `kubectl cnpg reload` or label is sufficient.

### 8. ESO Auth Method

AppRole remains the first slice because the repo already has working external-Vault ESO AppRole setup.

Kubernetes auth is milestone 2. It better matches production because it binds Vault access to ServiceAccounts and namespaces, but it requires TokenReview, issuer/audience decisions, and Vault-to-Kubernetes-API reachability.

Plan:

- First demo: AppRole, documented as local-only scaffolding.
- Second milestone: Kubernetes auth variant for ESO.
- VDE admin auth can remain userpass/OIDC at first, while ESO app-secret auth later moves to Kubernetes auth.

Pros of keeping VDE admin auth separate:

- admin credential issuance is human-driven
- OIDC/userpass audit identity stays close to the requesting user
- ESO Kubernetes auth remains machine-to-machine only

Cons:

- two auth models in one demo
- docs must be explicit to avoid confusion

## Implementation Plan

### Phase 0: Research Closure

Do before code:

1. Resolve name split: CNPG Cluster name vs PostgreSQL database name vs external host.
2. Confirm Traefik TCP entrypoint choice and port.
3. Confirm whether `sslmode=require` is acceptable for first demo, or if `verify-full` is mandatory.
4. Define limited DDL precisely.
5. Decide whether pgaudit logs require Loki in first demo.

### Phase 1: Static Manifests

Create `demo/yaml/self-service/rbr-ver-db/`:

- namespace manifests for `rbr-ver-db` and `rbr-ver`
- ESO `ExternalSecret` resources for superuser/app/readonly
- CNPG `Cluster`
- CNPG `Pooler`
- barman `ObjectStore`
- `ScheduledBackup`
- on-demand `Backup`
- Traefik `IngressRouteTCP`
- optional smoke-test app workload in `rbr-ver`

### Phase 2: Vault Setup

Add helper script or functions:

- seed KV secrets under `cnpg/rbr/ver/...`
- enable/configure VDE
- create stable PostgreSQL DDL role after cluster ready
- create Vault database config and roles
- create Vault policies `rbr-db-admin`, `rbr-ver-db-admin`

### Phase 3: Demo Script

Create `demo/self-service-setup.sh`:

- `setup local`
- `verify local`
- `rotate local app`
- `backup local`
- `creds local tenant-admin`
- `creds local group-admin`
- `teardown local`

Keep it narrow; do not alter `demo/setup.sh`.

### Phase 4: pgAdmin

Add separate self-service pgAdmin resources:

- namespace, Secret, ConfigMap `servers.json`
- Deployment/Service
- IngressRoute
- docs showing Vault credential copy/paste flow

### Phase 5: Grafana + Dex

Add separate self-service Grafana:

- Dex client and sample users/groups
- Grafana Deployment or Grafana Operator resources
- Generic OAuth config
- org/folder/dashboard provisioning
- namespace-scoped datasource simulation

### Phase 6: Docs

Add or update:

- `docs/self-service-demo.md`
- `docs/self-service-demo-nl.md`
- Mermaid architecture showing Vault, ESO, CNPG, Traefik TCP, VDE, pgAdmin, Dex, Grafana
- runbook sections for setup, rotate, backup, admin creds, and teardown

## Suggested Research Queue

1. Traefik TCP + PostgreSQL TLS/SNI proof in Kind.
2. CNPG external DNS SAN strategy for `verify-full`.
3. Exact limited DDL role and revocation SQL.
4. Current CNPG image pgaudit package proof.
5. CNPG managed role password rotation proof with ESO.
6. Barman plugin CRD version compatibility for manual `Backup`.
7. pgAdmin `PasswordExecCommand` feasibility with Vault.
8. Dex groups claim shape in current template.
9. Grafana OSS org/folder isolation limits.
10. Loki availability for pgaudit dashboards.

## Questions For Next Pass

1. Confirm naming split: Cluster `verstappen`, SQL database `max`, host `verstappen-rbr-ver-db...`?
2. Traefik TCP port: use public `5432`, or avoid collision with a demo port like `15432`?
3. Is `sslmode=require` acceptable for phase 1, with `verify-full` as phase 2?
4. Limited DDL: allow `CREATE` in `public`, or no DDL despite role name?
5. Should created objects be owned by the dynamic lease user, or by stable owner role?
6. For pgAdmin, is manual paste from Vault acceptable for first demo?
7. Should the app workload be a simple `psql` Job, a long-running Deployment, or both?
8. Should self-service Grafana use plain manifests first, or build on current Grafana Operator?
9. Should `docs/self-service-research-nl.md` mirror this updated English note now, or wait until plan stabilizes?

## Source Links

- CloudNativePG PostgreSQL configuration and managed `pgaudit`: https://cloudnative-pg.io/docs/devel/postgresql_conf/
- CloudNativePG backup methods: https://cloudnative-pg.io/docs/1.29/backup
- Barman Cloud CNPG-I plugin concepts: https://cloudnative-pg.io/plugin-barman-cloud/docs/concepts
- CloudNativePG certificates and `cnpg.io/reload`: https://cloudnative-pg.io/documentation/current/certificates/
- CloudNativePG declarative role management: https://cloudnative-pg.io/docs/devel/declarative_role_management/
- Vault PostgreSQL database secrets engine: https://developer.hashicorp.com/vault/docs/secrets/databases/postgresql
- Vault Kubernetes auth: https://developer.hashicorp.com/vault/docs/auth/kubernetes
- External Secrets Operator Vault provider: https://external-secrets.io/v1.3.2/provider/hashicorp-vault/
- Traefik `IngressRouteTCP`: https://doc.traefik.io/traefik/reference/routing-configuration/kubernetes/crd/tcp/ingressroutetcp/
- Grafana Generic OAuth: https://grafana.com/docs/grafana/latest/setup-grafana/configure-access/configure-authentication/generic-oauth/
- pgAdmin server import/export: https://www.pgadmin.org/docs/pgadmin4/latest/import_export_servers.html
- pgAdmin container deployment: https://www.pgadmin.org/docs/pgadmin4/latest/container_deployment.html
