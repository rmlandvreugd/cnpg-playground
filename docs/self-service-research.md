# CNPG Self-Service Demo: Review, Research, Plan

Status: planning and research record  
Date: 2026-05-01  
Scope: local runnable demo plus architecture docs

This note turns `docs/samenvatting.md`, `docs/ontwerp.md`, and `docs/implementatie.md` into a repo-local demo direction. It records decisions, researched constraints, implementation plan, questions, and research queue. It does not assume runtime behavior that still needs proof in this playground.

## Current Decisions

- Build both runnable demo and architecture documentation.
- Keep the existing demo unchanged by default.
- Add a new entry point: `demo/self-service-setup.sh`.
- Start with local region only.
- Simulate GitOps with checked-in manifests plus `kubectl apply`; do not install ArgoCD in the first slice.
- Keep the NCSC Helm chart out of scope for now.
- Use Formula 1 constructors as tenants and driver abbreviations as groups.
- First tenant/group DB namespace: `rbr-ver-db`.
- First app namespace: `rbr-ver`.
- Constructor is tenant: `rbr`.
- Driver abbreviation is group: `ver`.
- CNPG Cluster/service name is driver last name: `verstappen`.
- PostgreSQL database name is driver first name: `max`.
- External PostgreSQL host: `verstappen-rbr-ver-db.<dashed-loadbalancer-ip>.sslip.io`.
- Future examples: `rbr-had-db`, `mer-ant-db`.
- Vault policy names:
  - tenant admin: `rbr-db-admin`
  - group admin: `rbr-ver-db-admin`
- Tenant admin and group admin get the same DB capability for `rbr-ver-db`; membership differs. Every tenant admin is also a group admin, but not every group admin is a tenant admin.
- Application credentials are static Vault KV values synced by ESO.
- Admin credentials are dynamic Vault Database Secrets Engine leases with TTL.
- Admin SQL capability is limited DDL, not full superuser.
- For the first demo, allow `CREATE` in `public`.
- Created objects should be owned by a stable role if feasible, not by each dynamic lease user.
- pgAdmin is simple and preconfigured first; manual paste from Vault TTL credentials is acceptable.
- Later pgAdmin can investigate prefilled credentials.
- Include both scheduled backup and on-demand `Backup` manifest.
- NetworkPolicy is out of scope for first runnable slice.
- Monitoring should be a full separate Grafana demo on a separate URL, integrated with Dex.
- Build self-service Grafana on the existing Grafana Operator pattern.
- Add sample Dex users and groups.
- Use public PostgreSQL port `5432` on the load balancer; verify whether rootless Podman/MetalLB makes that reachable from the host.
- `sslmode=require` is acceptable for phase 1; `verify-full` is a follow-up once cert SAN handling is proven.
- App workload should eventually include both a long-running Deployment and a `psql` Job; start with the simpler proof path if needed.
- Do not mirror this note into `docs/self-service-research-nl.md` until the plan stabilizes.

## Review Findings

### Existing Repo Fit

Useful existing pieces:

- `scripts/setup.sh` already provisions local Kind, MetalLB, Traefik, Vault, Dex, cert-manager, and ESO.
- `scripts/vault-eso-setup.sh` and `scripts/eso-setup.sh` already configure a Vault KV mount, AppRole policy, ESO install, and `ClusterSecretStore`.
- `demo/eso-vault.sh` already proves the pattern for seeding Vault KV, applying ESO-backed CNPG manifests, rotating secrets, and forcing ESO sync.
- `demo/yaml/local/pg-local-eso.yaml.tpl` already has CNPG managed roles with `passwordSecret`.
- `demo/yaml/object-stores/objectstore-local.yaml` and `demo/yaml/local/pg-local.yaml` already show barman plugin and scheduled backup patterns.
- `monitoring/setup.sh` already deploys Grafana Operator resources that can guide a separate self-service Grafana.
- `dex/config/dex-config.yaml.tpl` already has a static client for Vault and one static user; it needs careful extension for Grafana without breaking Vault OIDC.

Current repo gaps:

- No self-service namespace layout.
- No Traefik TCP entrypoint for PostgreSQL.
- No VDE setup against CNPG.
- No tenant/group admin Vault policies for DB credentials.
- No self-service pgAdmin.
- No self-service Grafana with Dex groups.
- No runtime proof for pgaudit with current image/operator.

### Naming Is Resolved

Use:

- CNPG Cluster: `verstappen`
- PostgreSQL database: `max`
- Kubernetes DB namespace: `rbr-ver-db`
- Application namespace: `rbr-ver`
- External DB host: `verstappen-rbr-ver-db.<dashed-loadbalancer-ip>.sslip.io`
- Vault database config: `database/config/rbr-ver-max`

### Vault Network Path

The external Vault container should not use Kubernetes service DNS like `verstappen-rw.rbr-ver-db.svc.cluster.local`. Use Traefik TCP on the load balancer.

Risk: Traefik TCP `HostSNI(...)` matching requires TLS SNI. VDE must connect with TLS enabled and a hostname, not only an IP.

### TLS Verification Path

Phase 1 should use `sslmode=require` to prove VDE and TCP routing first.

For `verify-full`, the PostgreSQL server certificate must contain:

- external host: `verstappen-rbr-ver-db.<dashed-loadbalancer-ip>.sslip.io`
- internal service names:
  - `verstappen-rw`
  - `verstappen-rw.rbr-ver-db`
  - `verstappen-rw.rbr-ver-db.svc`
  - optional `verstappen-rw.rbr-ver-db.svc.cluster.local`

Research says CloudNativePG can use user-provided server certificates from cert-manager via `serverTLSSecret` and `serverCASecret`, and cert-manager can include DNS SANs. CNPG also mentions operator-managed server alternative DNS names, but the exact manifest field still needs confirmation before using that path.

Preferred direction:

- phase 1: operator-managed CNPG TLS + `sslmode=require`
- phase 2: cert-manager/Vault PKI server cert with external SAN + `sslmode=verify-full`

### pgaudit Plan Correction

Do not manually force `shared_preload_libraries: [pgaudit]` unless needed. CloudNativePG can automatically manage `shared_preload_libraries` and `CREATE EXTENSION` when `pgaudit.*` parameters are present.

Need runtime proof with actual image and operator installed by this repo.

### pgAdmin Password Stance

pgAdmin `servers.json` cannot import/export passwords. It can define host, port, username, database, SSL parameters, `passfile`, and `PasswordExecCommand`.

First demo:

- preload connection target
- do not store dynamic password
- user runs `vault read database/creds/...`
- user pastes username/password

Later demo:

- research `PasswordExecCommand` with a Vault helper
- consider per-lease pgAdmin session once broker/portal exists

### Grafana Isolation Boundary

Grafana OSS can map OAuth groups to org roles and org membership. OAuth Team Sync is Enterprise/Grafana Cloud. For this local demo:

- use one org per tenant: `rbr`
- use folders per group/database
- use Generic OAuth `groups_attribute_path`, `org_attribute_path`, and `org_mapping`
- use folder/dashboard provisioning
- simulate tenant-scoped datasources with namespace labels
- document that hard datasource isolation is not fully proven unless the datasource/query layer enforces it

## Researched Decisions

### 1. Traefik TCP Routing

Traefik `IngressRouteTCP` supports `HostSNI(...)` matching and TLS passthrough. For PostgreSQL, prefer TLS passthrough so CNPG owns database TLS.

Plan:

- add `postgres` entrypoint on Traefik `:5432`
- add port `5432` to Traefik Service
- route `HostSNI("verstappen-rbr-ver-db.<dashed-ip>.sslip.io")`
- set `tls.passthrough: true`
- service target: `verstappen-rw` in namespace `rbr-ver-db`, port `5432`
- VDE `connection_url` uses external host, not Kubernetes DNS
- first VDE TLS mode: `sslmode=require`
- later VDE TLS mode: `sslmode=verify-full`

Open questions:

- Does the current Traefik CRD install include TCP CRD support from the applied manifest?
- Does PostgreSQL client/Vault driver send SNI with `sslmode=require` and hostname?
- Does rootless Podman allow host reachability to the MetalLB IP on port `5432`, or does this need `kubectl port-forward` fallback?
- Should Traefik dashboard HTTP/TLS setup stay untouched and only add the `postgres` entrypoint?

### 2. Vault Database Secrets Engine

Vault PostgreSQL Database Secrets Engine fits dynamic admin credentials. It creates leased users and revokes them when the lease expires.

Plan:

- enable `database` secrets engine if absent
- configure `database/config/rbr-ver-max`
- create two Vault roles:
  - `rbr-db-admin`
  - `rbr-ver-db-admin`
- both roles create short-lived PostgreSQL users
- `default_ttl=1h`, `max_ttl=4h`
- no DB create
- no superuser
- allow limited DDL in `public` for first demo

Stable role direction:

```sql
CREATE ROLE rbr_ver_ddl_owner NOLOGIN;
CREATE ROLE rbr_ver_ddl_admin NOLOGIN;
GRANT CONNECT ON DATABASE max TO rbr_ver_ddl_admin;
GRANT USAGE, CREATE ON SCHEMA public TO rbr_ver_ddl_admin;
GRANT rbr_ver_ddl_owner TO rbr_ver_ddl_admin;
```

VDE creation statement direction:

```sql
CREATE ROLE "{{name}}" WITH LOGIN PASSWORD '{{password}}'
  VALID UNTIL '{{expiration}}' IN ROLE rbr_ver_ddl_admin;
```

Object ownership concern:

- If dynamic users create objects normally, they own those objects.
- If they `SET ROLE rbr_ver_ddl_owner` before DDL, objects can be owned by the stable owner role.
- A role that can create and own objects can generally drop its own objects. "No destructive DDL" is not cleanly enforceable with plain PostgreSQL grants.

Plan for first demo:

- accept limited DDL as a demo capability
- audit it with pgaudit
- document destructive DDL prevention as unresolved policy/design work

Open questions:

- Should `SET ROLE rbr_ver_ddl_owner` be required in pgAdmin docs?
- Should the demo provide a migration wrapper function instead of direct DDL?
- Should revocation include `REASSIGN OWNED BY "{{name}}" TO rbr_ver_ddl_owner; DROP OWNED BY "{{name}}";`?
- Should read-only dynamic role be added in first pass or deferred?

### 3. pgaudit Runtime

CloudNativePG docs say managed extensions include `pgaudit`; adding a `pgaudit.*` parameter makes CNPG manage preload libraries and extension creation in connectable databases. CNPG docs warn that missing libraries can prevent PostgreSQL startup, so runtime proof matters.

Plan:

```yaml
postgresql:
  parameters:
    pgaudit.log: "ddl,role,misc_set"
    pgaudit.log_catalog: "off"
    pgaudit.log_relation: "on"
```

Runtime verification candidates:

```bash
kubectl --context "${CONTEXT_NAME}" exec -n rbr-ver-db \
  "$(kubectl --context "${CONTEXT_NAME}" get pod -n rbr-ver-db \
      -l cnpg.io/cluster=verstappen,role=primary -o name)" \
  -- psql -U postgres -d max -c \
  "SELECT extname FROM pg_extension WHERE extname = 'pgaudit';"
```

```bash
kubectl --context "${CONTEXT_NAME}" logs -n rbr-ver-db \
  -l cnpg.io/cluster=verstappen --since=10m | rg "AUDIT|pgaudit"
```

Open questions:

- Does the current pulled `ghcr.io/cloudnative-pg/postgresql:18-standard-trixie` image include pgaudit?
- Does adding `pgaudit.*` trigger reload or rolling restart with the current operator?
- Should pgaudit proof be script-based only, or also surfaced in Grafana via logs?

### 4. pgAdmin Preconfiguration

pgAdmin can import server definitions from JSON. Required fields include name, group, port, username, SSL mode, maintenance DB, and host/hostaddr/service. Password fields cannot be imported/exported. `PasswordExecCommand`, `PasswordExecExpiration`, and `ConnectionParameters.passfile` are available fields.

Plan:

- deploy separate pgAdmin for self-service
- preload one server:
  - host: `verstappen-rbr-ver-db.<dashed-ip>.sslip.io`
  - port: `5432`
  - maintenance DB: `max`
  - username: blank/manual or placeholder
  - SSL mode: `require`
- user flow:
  1. `vault read database/creds/rbr-ver-db-admin`
  2. open pgAdmin
  3. paste username/password

Pros:

- no expired secrets stored in pgAdmin
- simple first demo
- matches TTL semantics

Cons:

- less polished than temporary broker-created pgAdmin
- user must copy credentials

Open questions:

- Can `PasswordExecCommand` safely run `vault read -field=password ...` inside pgAdmin?
- Would `PasswordExecCommand` weaken audit trace by hiding explicit user action?
- Should pgAdmin use Dex login in the first pass or stay local-admin until Grafana/Dex is proven?

### 5. Grafana + Dex

Grafana Generic OAuth supports group lookup and role/org mapping. Team Sync is not OSS, but org mapping can still map group claims to org roles. Dex static clients and static users/groups can model tenant/group admin users.

Plan:

- deploy separate Grafana using the repo's Grafana Operator pattern
- expose as `grafana-rbr-ver.<dashed-ip>.sslip.io`
- add Dex static client:
  - client id: `grafana-rbr-ver`
  - redirect URI: `https://grafana-rbr-ver.<dashed-ip>.sslip.io/login/generic_oauth`
- add sample Dex users:
  - tenant admin: groups `rbr-db-admin`, `rbr-ver-db-admin`
  - group admin: group `rbr-ver-db-admin`
  - unrelated user: no DB admin group
- Grafana org plan:
  - org: `rbr`
  - folder: `rbr-ver-db`
  - future folder: `rbr-had-db`
  - dashboards: CNPG health, backup status, app credential rotation status, pgaudit pointers
- Auth mapping direction:
  - `groups_attribute_path = groups`
  - `org_attribute_path = groups`
  - `org_mapping` maps `rbr-db-admin` and `rbr-ver-db-admin` to org `rbr`
  - `allowed_groups` limits login to expected DB admin groups

Open questions:

- Does current Dex config emit `groups` in ID token, UserInfo, or both?
- Does the repo's Grafana Operator CRD version support the needed OAuth env/config cleanly?
- Should tenant admin get Grafana `Admin` and group admin get `Editor`, or should both be `Editor` in local demo?
- Does the current monitoring stack include Loki? If not, pgaudit dashboard panels should be deferred or mocked with docs/script proof.

### 6. Backup Manifest

CloudNativePG supports `method: plugin` for scheduled and on-demand backups, requiring `.spec.pluginConfiguration`. Barman object-store backup is deprecated as a method starting in CNPG 1.26 in favor of the Barman Cloud Plugin.

Plan:

- keep `ScheduledBackup`
- add manual manifest, for example `demo/yaml/self-service/rbr-ver-db/backup-on-demand.yaml`
- document apply/delete lifecycle
- verification belongs in docs first, with script output later

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

Open questions:

- Does the installed barman plugin version accept this exact manifest?
- Should the demo use a timestamped backup name to avoid rerun conflicts?
- Should `backupOwnerReference` be set on `ScheduledBackup`?
- Should the docs explicitly warn that on-demand backups do not include Kubernetes Secrets?

### 7. ESO Rotation

CloudNativePG managed roles can use `passwordSecret`; the Secret should contain `username` and `password`, and examples label it with `cnpg.io/reload: "true"`.

ESO manual refresh is known:

```bash
kubectl annotate es <name> -n rbr-ver-db force-sync="$(date +%s)" --overwrite
```

Plan:

- ESO refresh interval can remain normal.
- Add `rotate local app` script option that updates Vault KV and annotates the `ExternalSecret`.
- Smoke test:
  1. connect as app user with old password
  2. rotate Vault KV app password
  3. force ESO sync
  4. wait for Secret update and CNPG role reconciliation
  5. old password fails
  6. new password succeeds

Open questions:

- Exact CNPG status field for managed role reconciliation in current CRD.
- Does role password rotation require explicit `kubectl cnpg reload`, or does `cnpg.io/reload` on the Secret suffice?
- Should rotation test run from app namespace `rbr-ver` using a Job?

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

Open questions:

- Should Kubernetes auth milestone happen before or after Grafana/Dex?
- Should AppRole role names become tenant-scoped now, for example `eso-rbr-ver-local`, instead of current region-scoped `eso-local`?

## Implementation Plan

### Phase 0: Research Closure

Do before code:

1. Prove Traefik TCP + PostgreSQL TLS/SNI path in local Kind.
2. Confirm Traefik CRD and Service changes needed for port `5432`.
3. Confirm whether CNPG operator-managed server alternative DNS names can include `verstappen-rbr-ver-db.<dashed-ip>.sslip.io`; if not, use cert-manager/Vault PKI user-provided server cert in phase 2.
4. Define first-pass DDL role behavior: direct `CREATE` in public with audit, plus optional `SET ROLE rbr_ver_ddl_owner`.
5. Confirm current image has pgaudit.
6. Confirm barman plugin CRD accepts the manual `Backup` manifest.
7. Confirm Grafana Operator supports separate self-service Grafana OAuth config without affecting existing monitoring.

### Phase 1: Static Manifests

Create `demo/yaml/self-service/rbr-ver-db/`:

- namespace manifests for `rbr-ver-db` and `rbr-ver`
- ESO `ExternalSecret` resources for superuser/app/readonly
- CNPG `Cluster` named `verstappen`, bootstrap database `max`
- CNPG `Pooler`
- barman `ObjectStore`
- `ScheduledBackup`
- on-demand `Backup`
- Traefik `IngressRouteTCP`
- optional smoke-test app workload in `rbr-ver`

### Phase 2: Vault Setup

Add helper script or functions:

- seed KV secrets under `cnpg/rbr/ver/max/...`
- enable/configure VDE
- create stable PostgreSQL roles after cluster ready
- create Vault database config `database/config/rbr-ver-max`
- create Vault roles/policies `rbr-db-admin`, `rbr-ver-db-admin`
- print copy/paste commands for tenant/group admin credentials

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
- later: evaluate Dex login and `PasswordExecCommand`

### Phase 5: Grafana + Dex

Add separate self-service Grafana:

- Dex client and sample users/groups
- Grafana Operator resources
- Generic OAuth config
- org/folder/dashboard provisioning
- namespace-scoped datasource simulation
- dashboard panels for CNPG health and backup state
- pgaudit panel only if Loki/log datasource exists; otherwise link to script verification

### Phase 6: Docs

Add or update:

- `docs/self-service-demo.md`
- `docs/self-service-demo-nl.md`
- Mermaid architecture showing Vault, ESO, CNPG, Traefik TCP, VDE, pgAdmin, Dex, Grafana
- runbook sections for setup, rotate, backup, admin creds, and teardown

## Suggested Research Queue

1. Traefik TCP + PostgreSQL TLS/SNI proof in Kind.
2. CNPG external DNS SAN strategy for `verify-full`.
3. Current CNPG image pgaudit package proof.
4. CNPG managed role password rotation proof with ESO.
5. Barman plugin CRD version compatibility for manual `Backup`.
6. Exact DDL ownership and revocation SQL for stable owner role.
7. pgAdmin `PasswordExecCommand` feasibility with Vault.
8. Dex groups claim shape in current template.
9. Grafana Operator OAuth config for separate instance.
10. Grafana OSS org/folder isolation limits in this concrete setup.
11. Loki availability for pgaudit dashboards.
12. Rootless Podman behavior for MetalLB `EXTERNAL-IP:5432`.

## Questions For Next Pass

1. For limited DDL, is "can create and can drop own demo objects, but all DDL is audited" acceptable for phase 1?
2. Should VDE create an additional readonly role in phase 1, or only admin roles?
3. Should `rbr-db-admin` and `rbr-ver-db-admin` be Vault policies only, Dex groups only, or both with matching names everywhere?
4. Should the first app workload be a long-running Deployment only after the `psql` Job proves credentials?
5. Should pgAdmin use Dex login in phase 1, or wait until Grafana/Dex is proven?
6. Should the self-service Grafana include a fake/sample pgaudit panel if Loki is absent, or avoid panels that cannot be backed by runtime data?
7. Should `demo/self-service-setup.sh teardown` remove Vault VDE roles and policies, or keep them for inspection?
8. Should `docs/self-service-research-nl.md` stay stale until implementation, or be deleted to avoid confusion?

## Source Links

- CloudNativePG PostgreSQL configuration and managed `pgaudit`: https://cloudnative-pg.io/docs/devel/postgresql_conf/
- CloudNativePG backup methods: https://cloudnative-pg.io/docs/1.29/backup/
- CloudNativePG certificates and `cnpg.io/reload`: https://cloudnative-pg.io/docs/devel/certificates/
- CloudNativePG declarative role management: https://cloudnative-pg.io/docs/devel/declarative_role_management/
- Barman Cloud CNPG-I plugin concepts: https://cloudnative-pg.io/plugin-barman-cloud/docs/concepts
- Vault PostgreSQL database secrets engine: https://developer.hashicorp.com/vault/docs/secrets/databases/postgresql
- Vault Kubernetes auth: https://developer.hashicorp.com/vault/docs/auth/kubernetes
- External Secrets Operator Vault provider: https://external-secrets.io/latest/provider/hashicorp-vault/
- External Secrets Operator manual refresh: https://external-secrets.io/latest/api/externalsecret/
- Traefik `IngressRouteTCP`: https://doc.traefik.io/traefik/reference/routing-configuration/kubernetes/crd/tcp/ingressroutetcp/
- Grafana Generic OAuth: https://grafana.com/docs/grafana/latest/setup-grafana/configure-access/configure-authentication/generic-oauth/
- Grafana Team Sync availability: https://grafana.com/docs/grafana/latest/setup-grafana/configure-access/configure-team-sync/
- pgAdmin server import/export: https://www.pgadmin.org/docs/pgadmin4/latest/import_export_servers.html
- pgAdmin container deployment: https://www.pgadmin.org/docs/pgadmin4/latest/container_deployment.html
