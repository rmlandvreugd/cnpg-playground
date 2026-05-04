# CNPG Self-Service Demo: Review, Research, Plan

Status: research in progress — Q32 resolved by live cluster test; open: Q28, Q37, Q38, Q40, Q41, Q42
Date: 2026-05-01 (research closed 2026-05-01; validated against codebase 2026-05-03; second codebase pass 2026-05-04)
Scope: local runnable demo plus architecture docs

This note turns `docs/samenvatting.md`, `docs/ontwerp.md`, and `docs/implementatie.md` into a repo-local demo direction. It records decisions, researched constraints, implementation plan, questions, and research queue. It does not assume runtime behavior that still needs proof in this playground.

## Current Decisions

Decisions from initial planning:

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
- Include both scheduled backup and on-demand `Backup` manifest.
- NetworkPolicy is out of scope for first runnable slice.
- Monitoring should be a full separate Grafana demo on a separate URL, integrated with Dex.
- Build self-service Grafana on the existing Grafana Operator pattern.
- Add sample Dex users and groups.
- Use public PostgreSQL port `5432` on the load balancer.
- `sslmode=require` is acceptable for phase 1; `verify-full` is a follow-up once cert SAN handling is proven.
- App workload should eventually include both a long-running Deployment and a `psql` Job; start with the simpler proof path if needed.
- Do not mirror this note into `docs/self-service-research-nl.md` until the plan stabilizes.

Decisions added after research closure (2026-05-01) and codebase validation (2026-05-03):

- Traefik v3.3.0 already includes `IngressRouteTCP` CRD (`ingressroutetcps.traefik.io`, version `v1alpha1`). No separate CRD install needed.
- PostgreSQL `libpq` (PG14+) sends TLS SNI when connecting with a hostname and `sslmode=require`. Traefik `HostSNI(...)` passthrough routing is confirmed viable.
- Port 5432 is reachable from the host via the MetalLB IP on rootless Podman + Kind on Linux, identically to ports 80 and 443. No special Podman or Kind configuration is required.
- Adding the `postgres` entrypoint to Traefik requires: `--entrypoints.postgres.address=:5432` in `traefik/values.yaml` under `additionalArguments`, and a `postgres` port entry in the `ports:` section of `values.yaml` (Helm chart manages the Deployment and Service). `traefik/deployment.yaml` and `traefik/services.yaml` do not exist in this repo — Traefik is Helm-managed. No NET_BIND_SERVICE change is needed (5432 is unprivileged).
- `pgaudit` version 18.0-2.pgdg13+1 is confirmed installed in `ghcr.io/cloudnative-pg/postgresql:18-standard-trixie`. The `.so` is at `/usr/lib/postgresql/18/lib/pgaudit.so`; extension files are at `/usr/share/postgresql/18/extension/pgaudit*`.
- CNPG automatically adds `pgaudit` to `shared_preload_libraries` and runs `CREATE EXTENSION pgaudit` in all connectable databases when any `pgaudit.*` parameter is set. No manual `shared_preload_libraries` entry is needed.
- `cnpg.io/reload: "true"` label on a Kubernetes Secret causes CNPG to automatically reconcile managed role passwords when the Secret changes. No `kubectl cnpg reload` is required for ESO-triggered rotation.
- `spec.certificates.serverAltDNSNames` in a CNPG Cluster accepts any DNS names, including external sslip.io hostnames. It adds those names as SANs to the operator-managed server certificate.
- `serverAltDNSNames` is incompatible with `serverTLSSecret`. It works only when operator-managed TLS is used (i.e., `serverTLSSecret` is not set).
- Operator-managed TLS automatically includes `verstappen-rw`, `verstappen-rw.rbr-ver-db`, `verstappen-rw.rbr-ver-db.svc`, and `verstappen-rw.rbr-ver-db.svc.cluster.local` as SANs without additional configuration.
- Barman Cloud plugin name confirmed: `barman-cloud.cloudnative-pg.io`. On-demand `Backup` resources do not require parameters in `spec.pluginConfiguration` because they inherit the `barmanObjectName` and `serverName` from the Cluster's `spec.plugins` section.
- `ObjectStore` (`barmancloud.cnpg.io/v1`) must be in the same namespace as the Cluster that references it.
- On-demand `Backup` names must be unique. Applying the same name twice is idempotent (does not trigger a second backup). Use timestamps or suffixes.
- `ScheduledBackup.spec.backupOwnerReference: self` is the correct value for this demo (the existing `pg-local.yaml` already uses this).
- Vault Database Secrets Engine `creation_statements` (admin roles):
  ```sql
  CREATE ROLE "{{name}}" WITH LOGIN PASSWORD '{{password}}' VALID UNTIL '{{expiration}}' IN ROLE rbr_ver_ddl_admin;
  GRANT "{{name}}" TO rbr_ver_vde_admin;
  ```
  Note: second statement required — `REASSIGN OWNED BY "{{name}}"` in revocation requires the executing role to be a **member** of `"{{name}}"`, not just ADMIN OPTION holder (confirmed PG18 live cluster test 2026-05-04).
- Vault Database Secrets Engine `revocation_statements`:
  ```sql
  REASSIGN OWNED BY "{{name}}" TO rbr_ver_ddl_owner;
  DROP OWNED BY "{{name}}";
  DROP ROLE IF EXISTS "{{name}}";
  ```
- When a dynamic user runs `SET ROLE rbr_ver_ddl_owner` before DDL, created objects are owned by the stable role and survive revocation. PostgreSQL assigns ownership by the current role at creation time, not the session user.
- Vault (external Podman container) connects to CNPG for VDE via the sslip.io hostname: `postgresql://{{username}}:{{password}}@verstappen-rbr-ver-db.<dashed-ip>.sslip.io:5432/max?sslmode=require`. Traffic routes host → MetalLB → Traefik TCP passthrough → CNPG.
- pgAdmin `PasswordExecCommand` is disabled in container/server mode (greyed out in UI, ignored in `servers.json`). It requires pgAdmin desktop mode, which is not used here. The "later demo" approach is `.pgpass` populated by an init container that fetches Vault credentials at pod startup.
- Dex `staticPasswords` natively supports a `groups` field. No connector change is needed. Clients must request the `groups` scope to receive the `groups` claim in the ID token.
- Dex groups token shape: `"groups": ["rbr-db-admin", "rbr-ver-db-admin"]` (simple string array).
- The second self-service Grafana CR is deployed in the existing `grafana` namespace with a distinct name (e.g., `grafana-rbr-ver`). The Grafana Operator is cluster-scoped and supports multiple instances in the same namespace.
- Grafana OSS folder-level access control via OAuth group claims is not available. It requires Grafana Enterprise. Folders in the OSS demo are for visual grouping only; access isolation is at the org level.
- Grafana Operator `spec.config` uses dotted section names as YAML keys: `auth.generic_oauth:` maps to `[auth.generic_oauth]` in `grafana.ini`. All `grafana.ini` fields for Generic OAuth are available via this path.
- Grafana client secret injection: use `${VAR}` substitution in `spec.config`, backed by a Kubernetes Secret referenced via `valueFrom.secretKeyRef` in the Grafana Deployment env spec.
- Grafana `org_mapping` format (Grafana v11.5+): `ExternalGroupName:GrafanaOrgName:Role`. Orgs must be pre-created. No auto-creation.
- `allowed_groups` in Grafana Generic OAuth restricts login to specified groups. Users not in any listed group cannot log in.

## Review Findings

### Existing Repo Fit

Useful existing pieces:

- `scripts/setup.sh` already provisions local Kind, MetalLB, Traefik, Vault, Dex, cert-manager, and ESO.
- `scripts/vault-eso-setup.sh` and `scripts/eso-setup.sh` already configure a Vault KV mount, AppRole policy, ESO install, and `ClusterSecretStore`.
- `demo/eso-vault.sh` already proves the pattern for seeding Vault KV, applying ESO-backed CNPG manifests, rotating secrets, and forcing ESO sync.
- `demo/yaml/local/pg-local-eso.yaml.tpl` already has CNPG managed roles with `passwordSecret`.
- `demo/yaml/object-stores/objectstore-local.yaml` and `demo/yaml/local/pg-local.yaml` already show barman plugin and scheduled backup patterns. `pg-local.yaml` confirms `backupOwnerReference: self` and `pluginConfiguration.name: barman-cloud.cloudnative-pg.io`.
- `monitoring/setup.sh` already deploys Grafana Operator resources that can guide a separate self-service Grafana.
- `dex/config/dex-config.yaml.tpl` already has a static client for Vault and one static user. It needs careful extension for Grafana without breaking Vault OIDC.

Current repo gaps:

- No self-service namespace layout.
- No Traefik TCP entrypoint for PostgreSQL.
- No VDE setup against CNPG.
- No tenant/group admin Vault policies for DB credentials.
- No self-service pgAdmin.
- No self-service Grafana with Dex groups.

### Naming Is Resolved

Use:

- CNPG Cluster: `verstappen`
- PostgreSQL database: `max`
- Kubernetes DB namespace: `rbr-ver-db`
- Application namespace: `rbr-ver`
- External DB host: `verstappen-rbr-ver-db.<dashed-loadbalancer-ip>.sslip.io`
- Vault database config: `database/config/rbr-ver-max`

### Vault Network Path

The external Vault container connects to CNPG via the Traefik TCP passthrough on the MetalLB IP. The `connection_url` for the VDE config uses the sslip.io hostname, not Kubernetes internal DNS. This is confirmed reachable because Vault runs on the Podman `kind` network which has direct routing to the MetalLB-assigned IP.

### TLS Verification Path

Phase 1 uses `sslmode=require`. libpq sends SNI automatically when a hostname is used (PG14+, default).

For `verify-full` (phase 2), use `spec.certificates.serverAltDNSNames` in the CNPG Cluster to add the external hostname. The operator-managed certificate will include the sslip.io SAN. Do not set `serverTLSSecret` — it is incompatible with `serverAltDNSNames`.

Certificate SANs included automatically by CNPG with operator-managed TLS:
- `verstappen-rw`
- `verstappen-rw.rbr-ver-db`
- `verstappen-rw.rbr-ver-db.svc`
- `verstappen-rw.rbr-ver-db.svc.cluster.local`

Add via `serverAltDNSNames`:
- `verstappen-rbr-ver-db.<dashed-ip>.sslip.io`

### pgaudit Plan Confirmed

pgaudit 18.0 is installed in the image. CNPG manages `shared_preload_libraries` and `CREATE EXTENSION` automatically when `pgaudit.*` parameters are present. No manual library list entry is needed.

### pgAdmin Password Stance

`PasswordExecCommand` is disabled in container/server mode and requires desktop mode. It is not viable for a containerized pgAdmin deployment.

First demo approach (phase 1):
- Preload connection target in `servers.json`
- User runs `vault read database/creds/rbr-ver-db-admin`
- User pastes username and password into pgAdmin

Later demo approach (phase 4+):
- Init container at pod startup fetches credentials from Vault and writes a `.pgpass` file to a shared volume
- Main pgAdmin container reads `.pgpass`
- Limitation: credentials are static per pod lifecycle; pod restart is needed for a new lease
- Alternative refresh: CronJob runs `kubectl exec` to update `.pgpass` before TTL expiry

### Grafana Isolation Boundary

Grafana OSS folder-level access control via OAuth groups is not available (Enterprise only). The demo uses org-level isolation only:
- One org per tenant: `rbr` (pre-created)
- `org_mapping` maps Dex groups to the `rbr` org with appropriate roles
- Folders exist for visual grouping only; any org member can see all folders
- Document that hard folder isolation requires Grafana Enterprise

## Researched Decisions

### 1. Traefik TCP Routing

Plan:

- Add `postgres` entrypoint on Traefik `:5432`
- Add to `traefik/values.yaml` under `additionalArguments`: `--entrypoints.postgres.address=:5432`
- Add `postgres` port to `traefik/values.yaml` `ports:` section (Helm chart generates the Deployment containerPort and Service port from this)
- Route `HostSNI("verstappen-rbr-ver-db.<dashed-ip>.sslip.io")`
- Set `tls.passthrough: true`
- Service target: `verstappen-rw` in namespace `rbr-ver-db`, port `5432`

IngressRouteTCP manifest:

```yaml
apiVersion: traefik.io/v1alpha1
kind: IngressRouteTCP
metadata:
  name: postgres-rbr-ver
  namespace: traefik
spec:
  entryPoints:
    - postgres
  routes:
    - match: HostSNI(`verstappen-rbr-ver-db.${TRAEFIK_IP_DASHED}.sslip.io`)
      services:
        - name: verstappen-rw
          namespace: rbr-ver-db
          port: 5432
  tls:
    passthrough: true
```

Note: Traefik uses `allowCrossNamespace=true` (already set in this repo), so a `traefik`-namespace route can target a service in `rbr-ver-db`.

VDE `connection_url`:
```
postgresql://{{username}}:{{password}}@verstappen-rbr-ver-db.<dashed-ip>.sslip.io:5432/max?sslmode=require
```

Findings:

- IngressRouteTCP CRD (`ingressroutetcps.traefik.io`, `v1alpha1`) is included in the Traefik v3.3.0 CRD manifest fetched during setup. No additional CRD install is needed.
- TLS passthrough with `HostSNI(...)` matching requires TLS to be enabled on the backend. CNPG handles PostgreSQL TLS by default (operator-managed). PostgreSQL clients will initiate TLS, providing SNI to Traefik.
- `libpq` (PostgreSQL 14+) sends TLS SNI by default when connecting with a hostname and `sslmode=require`. The `sslsni` connection parameter controls it (default: enabled). psql, pgAdmin, and Vault's database engine (which uses libpq) all send SNI.
- `HostSNI("*")` matches all TCP connections (including non-TLS). Use it as a catch-all, not for specific routing.
- Port 5432 is above 1024 (unprivileged). No `NET_BIND_SERVICE` change is needed for the Traefik container to bind it. `NET_BIND_SERVICE` is already present in `traefik/values.yaml:9` (`securityContext.capabilities.add: [NET_BIND_SERVICE]`); this remains correct and harmless.
- Port 5432 is reachable from the host via the MetalLB IP on rootless Podman + Kind on Linux. The Podman user namespace does not block network namespace routing. All MetalLB ports route identically; 80/443 already working proves the network path.

Open questions:

- [RESOLVED] Does the current Traefik CRD install include TCP CRD support? **Yes — IngressRouteTCP CRD v1alpha1 included in v3.3.0 manifest.**
- [RESOLVED] Does PostgreSQL client/Vault driver send SNI with `sslmode=require` and hostname? **Yes — libpq sends SNI by default (PG14+).**
- [RESOLVED] Does rootless Podman allow host reachability to the MetalLB IP on port `5432`? **Yes — identical to ports 80/443.**
- [RESOLVED] Should Traefik dashboard HTTP/TLS setup stay untouched and only add the `postgres` entrypoint? **Yes — add postgres entrypoint only.**
- [RESOLVED] The IngressRouteTCP uses the `rbr-ver-db` namespace while living in `traefik`. `allowCrossNamespace: true` is confirmed in `traefik/values.yaml:18–19` under `providers.kubernetesCRD`. No runtime check needed.

### 2. Vault Database Secrets Engine

Plan:

- Enable `database` secrets engine if absent: `vault secrets enable database`
- Configure `database/config/rbr-ver-max`:

```bash
vault write database/config/rbr-ver-max \
  plugin_name="postgresql-database-plugin" \
  connection_url="postgresql://{{username}}:{{password}}@verstappen-rbr-ver-db.${TRAEFIK_IP_DASHED}.sslip.io:5432/max?sslmode=require" \
  allowed_roles="rbr-db-admin,rbr-ver-db-admin" \
  username="<vault-admin-postgres-user>" \
  password="<vault-admin-postgres-password>"
```

- Create stable PostgreSQL roles before configuring VDE (run against the cluster via `kubectl exec`):

```sql
CREATE ROLE rbr_ver_ddl_owner NOLOGIN;
CREATE ROLE rbr_ver_ddl_admin NOLOGIN;
CREATE ROLE rbr_ver_ddl_reader NOLOGIN;
GRANT CONNECT ON DATABASE max TO rbr_ver_ddl_admin;
GRANT USAGE, CREATE ON SCHEMA public TO rbr_ver_ddl_admin;
GRANT USAGE, CREATE ON SCHEMA public TO rbr_ver_ddl_owner;
GRANT rbr_ver_ddl_owner TO rbr_ver_ddl_admin;
GRANT CONNECT ON DATABASE max TO rbr_ver_ddl_reader;
GRANT USAGE ON SCHEMA public TO rbr_ver_ddl_reader;
GRANT SELECT ON ALL TABLES IN SCHEMA public TO rbr_ver_ddl_reader;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT ON TABLES TO rbr_ver_ddl_reader;
```

Note: `rbr_ver_ddl_owner` needs `CREATE ON SCHEMA public` because dynamic users do `SET ROLE rbr_ver_ddl_owner` before DDL — the privilege check runs against the current role, not the session user (confirmed by live cluster test 2026-05-04).

- Create Vault role `rbr-db-admin`:

```bash
vault write database/roles/rbr-db-admin \
  db_name="rbr-ver-max" \
  creation_statements="CREATE ROLE \"{{name}}\" WITH LOGIN PASSWORD '{{password}}' VALID UNTIL '{{expiration}}' IN ROLE rbr_ver_ddl_admin; GRANT \"{{name}}\" TO rbr_ver_vde_admin;" \
  revocation_statements="REASSIGN OWNED BY \"{{name}}\" TO rbr_ver_ddl_owner; DROP OWNED BY \"{{name}}\"; DROP ROLE IF EXISTS \"{{name}}\";" \
  default_ttl="1h" \
  max_ttl="4h"
```

- Create Vault role `rbr-ver-db-admin` with the same statements (membership distinction is in the Vault policy, not the DB role creation SQL):

```bash
vault write database/roles/rbr-ver-db-admin \
  db_name="rbr-ver-max" \
  creation_statements="CREATE ROLE \"{{name}}\" WITH LOGIN PASSWORD '{{password}}' VALID UNTIL '{{expiration}}' IN ROLE rbr_ver_ddl_admin; GRANT \"{{name}}\" TO rbr_ver_vde_admin;" \
  revocation_statements="REASSIGN OWNED BY \"{{name}}\" TO rbr_ver_ddl_owner; DROP OWNED BY \"{{name}}\"; DROP ROLE IF EXISTS \"{{name}}\";" \
  default_ttl="1h" \
  max_ttl="4h"
```

- Create Vault role `rbr-ver-db-readonly`:

```bash
vault write database/roles/rbr-ver-db-readonly \
  db_name="rbr-ver-max" \
  creation_statements="CREATE ROLE \"{{name}}\" WITH LOGIN PASSWORD '{{password}}' VALID UNTIL '{{expiration}}' IN ROLE rbr_ver_ddl_reader; GRANT \"{{name}}\" TO rbr_ver_vde_admin;" \
  revocation_statements="DROP ROLE IF EXISTS \"{{name}}\";" \
  default_ttl="1h" \
  max_ttl="4h"
```

- Vault automatically executes `revocation_statements` when a lease expires. No manual action needed.

Stable role ownership direction:

If a dynamic user runs `SET ROLE rbr_ver_ddl_owner` before DDL, objects are owned by the stable role and survive revocation. This is correct PostgreSQL behavior: ownership is set at creation time by the current role, not the session user. Add `SET ROLE rbr_ver_ddl_owner;` to the pgAdmin workflow docs.

Findings:

- `{{name}}`, `{{password}}`, `{{expiration}}` are the correct Vault template placeholders.
- `IN ROLE rbr_ver_ddl_admin` in `creation_statements` is valid syntax and grants role membership atomically at creation.
- Default revocation behavior (empty `revocation_statements`) leaves the dynamic user in PostgreSQL permanently. Always set explicit `revocation_statements`.
- `REASSIGN OWNED BY "{{name}}" TO rbr_ver_ddl_owner; DROP OWNED BY "{{name}}"; DROP ROLE IF EXISTS "{{name}}";` is the correct three-step revocation for the stable-role ownership pattern.
- `SET ROLE rbr_ver_ddl_owner` before DDL means `DROP OWNED BY "{{name}}"` in revocation has no effect on those objects. They persist under `rbr_ver_ddl_owner`.
- Vault automatically triggers revocation when the lease TTL expires. The user does not need to manually revoke.
- Vault connection to CNPG goes via Traefik TCP passthrough (sslip.io hostname). Vault is on the Podman `kind` network and can reach the MetalLB IP directly.

Live cluster test findings (PG18, 2026-05-04):

- **`GRANT ... WITH ADMIN OPTION` required.** PG16+ changed `CREATEROLE` semantics: granting roles to others requires `ADMIN OPTION` on each role, not just `CREATEROLE`. All three GRANTs to `rbr_ver_vde_admin` must use `WITH ADMIN OPTION`.
- **`GRANT "{{name}}" TO rbr_ver_vde_admin` required in `creation_statements`.** `REASSIGN OWNED BY "{{name}}"` requires the executor to be a **member** of `"{{name}}"` (not just ADMIN OPTION holder). PG16+ CREATEROLE auto-grants ADMIN OPTION on created roles but NOT membership. Without this grant, revocation fails with `permission denied to reassign objects`.
- **`rbr_ver_ddl_owner` needs `CREATE ON SCHEMA public`.** Dynamic users do `SET ROLE rbr_ver_ddl_owner` before DDL; privilege check runs against `rbr_ver_ddl_owner`, not the session role. Without this grant, `CREATE TABLE` fails with `permission denied for schema public` (PG15+ no longer grants CREATE on public to PUBLIC by default).
- **Full verified creation cycle (PG18 live cluster):** CREATEROLE + ADMIN OPTION on stable roles + membership in dynamic role + `CREATE ON SCHEMA public` on owner role = full cycle works without SUPERUSER.

Open questions:

- [RESOLVED] Creation statement syntax: confirmed valid.
- [RESOLVED] `SET ROLE` before DDL preserves objects through revocation: confirmed.
- [RESOLVED] Automatic revocation: Vault executes `revocation_statements` at lease expiry automatically.
- [UNRESOLVED] Should `SET ROLE rbr_ver_ddl_owner` be required in pgAdmin docs as a mandatory first step, or documented as optional best practice?
- [UNRESOLVED] Should a read-only dynamic role (`rbr-ver-db-readonly`) be added to VDE in phase 1, or deferred?
- [UNRESOLVED] Should the demo provide a wrapper function (e.g., a shell alias) that issues `SET ROLE` automatically, or rely on user docs?

### 3. pgaudit Runtime

Plan:

```yaml
postgresql:
  parameters:
    pgaudit.log: "ddl,role,misc_set"
    pgaudit.log_catalog: "off"
    pgaudit.log_relation: "on"
```

No `shared_preload_libraries` entry is needed. CNPG adds it automatically when any `pgaudit.*` parameter is present.

Runtime verification:

```bash
kubectl --context "${CONTEXT_NAME}" exec -n rbr-ver-db \
  "$(kubectl --context "${CONTEXT_NAME}" get pod -n rbr-ver-db \
      -l cnpg.io/cluster=verstappen,role=primary -o name)" \
  -- psql -U postgres -d max -c \
  "SELECT extname FROM pg_extension WHERE extname = 'pgaudit';"
```

```bash
kubectl --context "${CONTEXT_NAME}" logs -n rbr-ver-db \
  -l cnpg.io/cluster=verstappen --since=10m | grep -E "AUDIT|pgaudit"
```

Findings:

- pgaudit package `postgresql-18-pgaudit 18.0-2.pgdg13+1` is confirmed installed in `ghcr.io/cloudnative-pg/postgresql:18-standard-trixie`.
  - Shared library: `/usr/lib/postgresql/18/lib/pgaudit.so`
  - Extension control: `/usr/share/postgresql/18/extension/pgaudit.control`
  - Extension SQL: `/usr/share/postgresql/18/extension/pgaudit--18.0.sql`
- CNPG adds `pgaudit` to `shared_preload_libraries` and runs `CREATE EXTENSION pgaudit` automatically across all connectable databases when any `pgaudit.*` parameter is set. This triggers a pod rolling restart (for `shared_preload_libraries` change). Subsequent parameter-only changes reload without restart.
- Removing all `pgaudit.*` parameters reverses the setup but also requires a restart to unload the library.

Open questions:

- [RESOLVED] Does the current image include pgaudit? **Yes — pgaudit 18.0-2.pgdg13+1 confirmed.**
- [RESOLVED] Does adding `pgaudit.*` trigger reload or restart? **First add: rolling restart (shared_preload_libraries change). Subsequent parameter changes: reload only.**
- [UNRESOLVED] Should pgaudit proof be script-based only, or also surfaced in Grafana via logs? Deferred pending Loki investigation (see Research Closure item 11).

### 4. pgAdmin Preconfiguration

Phase 1 plan (manual paste):

- Deploy separate pgAdmin for self-service
- `servers.json` preloads one server:
  - `Host`: `verstappen-rbr-ver-db.<dashed-ip>.sslip.io`
  - `Port`: `5432`
  - `MaintenanceDB`: `max`
  - `SSLMode`: `require`
  - `Username`: leave blank or use a placeholder; user overwrites at connect time
- User flow:
  1. `vault read database/creds/rbr-ver-db-admin`
  2. Open pgAdmin
  3. Paste username and password

Later demo plan (`.pgpass` init container):

- Add an init container to the pgAdmin Pod that:
  1. Runs `vault read -field=password database/creds/rbr-ver-db-admin` and `vault read -field=username database/creds/rbr-ver-db-admin`
  2. Writes to `/pgpass/.pgpass`:
     `verstappen-rbr-ver-db.<dashed-ip>.sslip.io:5432:max:<username>:<password>`
  3. Sets `chmod 0600 /pgpass/.pgpass`
- Mount the shared volume into the main pgAdmin container at `/pgadmin4/pgpass`
- Reference it from `servers.json` via `ConnectionParameters.passfile`
- Limitation: credentials are static per pod lifecycle. Refreshing requires a pod restart or an external CronJob that updates the file before TTL expiry.

`servers.json` schema (phase 1):

```json
{
  "Servers": {
    "1": {
      "Name": "verstappen (rbr-ver-db)",
      "Group": "rbr-ver",
      "Host": "verstappen-rbr-ver-db.<dashed-ip>.sslip.io",
      "Port": 5432,
      "MaintenanceDB": "max",
      "SSLMode": "require",
      "Username": ""
    }
  }
}
```

Findings:

- `PasswordExecCommand` is completely disabled in pgAdmin container/server mode. It is greyed out in the UI and ignored when reading `servers.json`. It requires pgAdmin desktop mode (native application). This path is a dead end for any containerized pgAdmin.
- The standard `dpage/pgadmin4` image does not include the Vault CLI. Even with a custom image, desktop mode would be required.
- `passfile` in `ConnectionParameters` is a viable alternative: it references a `.pgpass` file that pgAdmin passes to libpq. It works in container mode.
- `PasswordExecCommand` and `PasswordExecExpiration` fields exist in `servers.json` schema but are inert in server/container mode.

Open questions:

- [RESOLVED] Can `PasswordExecCommand` safely run `vault read` inside pgAdmin? **No — disabled in container mode. Dead end.**
- [RESOLVED] Should pgAdmin use Dex login in the first pass? **No — stay local-admin. Dex integration deferred until Grafana/Dex is proven.**
- [UNRESOLVED] For the `.pgpass` init container approach: should the Vault token be mounted as a Kubernetes Secret into the init container, or should the init container use the AppRole credentials already available in the cluster?
- [UNRESOLVED] Should the init container use the `rbr-db-admin` or `rbr-ver-db-admin` Vault role? Decision depends on which persona the pgAdmin instance represents.

### 5. Grafana + Dex

Plan:

- Deploy second Grafana CR named `grafana-rbr-ver` in the existing `grafana` namespace.
- Expose as `grafana-rbr-ver.<dashed-ip>.sslip.io`.
- Add Dex static client for Grafana:
  ```yaml
  - id: grafana-rbr-ver
    name: Grafana RBR VER
    secret: ${DEX_GRAFANA_RBR_VER_CLIENT_SECRET}
    redirectURIs:
      - https://grafana-rbr-ver.${TRAEFIK_IP_DASHED}.sslip.io/login/generic_oauth
  ```
- Add sample Dex static users with `groups` field:
  ```yaml
  staticPasswords:
  - email: "rbr-admin@example.com"
    hash: "${DEX_RBR_ADMIN_PASSWORD_HASH}"
    username: "rbr-admin"
    userID: "rbr-admin-001"
    groups:
      - "rbr-db-admin"
      - "rbr-ver-db-admin"
  - email: "rbr-ver-admin@example.com"
    hash: "${DEX_RBR_VER_ADMIN_PASSWORD_HASH}"
    username: "rbr-ver-admin"
    userID: "rbr-ver-admin-001"
    groups:
      - "rbr-ver-db-admin"
  - email: "unrelated@example.com"
    hash: "${DEX_UNRELATED_PASSWORD_HASH}"
    username: "unrelated"
    userID: "unrelated-001"
    groups: []
  ```
- Dex clients must request the `groups` scope to receive the `groups` claim in the ID token. Add `groups` to the Dex client scopes for the Grafana client.
- Pre-create Grafana org `rbr` in the `grafana-rbr-ver` instance (via Grafana API or provisioning).
- Grafana org plan:
  - Org: `rbr` (pre-created; no auto-creation in OSS)
  - Folders exist for visual grouping only — no OAuth group-based access control in OSS
  - Dashboards: CNPG health, backup status, app credential rotation status
  - pgaudit panel deferred pending Loki investigation

Grafana CR `spec.config` for Generic OAuth:

```yaml
spec:
  config:
    "auth.generic_oauth":
      enabled: "true"
      name: "Dex"
      allow_sign_up: "true"
      client_id: "grafana-rbr-ver"
      client_secret: "${GRAFANA_RBR_VER_CLIENT_SECRET}"
      scopes: "openid email profile groups"
      auth_url: "https://${DEX_HOST}:${DEX_PORT}/dex/auth"
      token_url: "https://${DEX_HOST}:${DEX_PORT}/dex/token"
      api_url: "https://${DEX_HOST}:${DEX_PORT}/dex/userinfo"
      groups_attribute_path: "groups"
      org_attribute_path: "groups"
      org_mapping: "rbr-db-admin:rbr:Admin rbr-ver-db-admin:rbr:Editor"
      allowed_groups: "rbr-db-admin,rbr-ver-db-admin"
      role_attribute_strict: "true"
```

Inject `client_secret` via Kubernetes Secret + env var:

```yaml
deployment:
  spec:
    template:
      spec:
        containers:
          - name: grafana
            env:
              - name: GRAFANA_RBR_VER_CLIENT_SECRET
                valueFrom:
                  secretKeyRef:
                    name: grafana-rbr-ver-oauth
                    key: client-secret
```

Dex config overlay approach: extend `dex-config.yaml.tpl` by adding the Grafana static client and new users in an overlay file. Do not modify the base template.

Findings:

- Dex `staticPasswords` natively supports a `groups` field. No connector change needed. The existing `enablePasswordDB: true` handles it.
- Dex emits the `groups` claim only when the client requests the `groups` scope. Add `groups` to the Dex client `scopes` list (or ensure Grafana requests it).
- Dex token `groups` claim shape: `"groups": ["rbr-db-admin", "rbr-ver-db-admin"]` — plain string array.
- Multiple `Grafana` CRs in the same namespace are supported by the Grafana Operator.
- Each Grafana CR has an independent `spec.config` with its own OAuth client, scopes, and org mapping. Instances do not share config.
- `spec.config` uses dotted YAML keys for grafana.ini sections: `"auth.generic_oauth":` (quoted to preserve the dot).
- `client_secret` must be injected via env var substitution (`${VAR}`) — the Grafana Operator does not support direct Secret references in `spec.config`.
- Grafana OSS `org_mapping` maps groups to existing orgs. Orgs must be pre-created. No auto-creation.
- Grafana OSS folder-level access via OAuth groups: **not available**. Enterprise RBAC required. Folders in OSS are visual grouping only.
- Team Sync (group → team → folder permission): Enterprise/Cloud only. Not available in OSS.

Open questions:

- [RESOLVED] Does current Dex config emit `groups` in ID token? **Yes, when the `groups` scope is requested by the client.**
- [RESOLVED] Does the Grafana Operator CRD support separate instance OAuth config? **Yes — each Grafana CR has independent `spec.config`.**
- [RESOLVED] Does Dex static password support groups natively? **Yes — `groups` field on `staticPasswords` entries.**
- [RESOLVED] Is folder isolation by OAuth groups possible in OSS? **No — Enterprise only. OSS demo uses org-level isolation only.**
- [UNRESOLVED] Should tenant admin (`rbr-db-admin`) get Grafana `Admin` and group admin (`rbr-ver-db-admin`) get `Editor`, or should both be `Editor`? The `org_mapping` above assumes Admin/Editor split. Needs explicit sign-off.
- [UNRESOLVED] Does the current monitoring Grafana Operator version (installed via `latest` from GitHub releases) support the `"auth.generic_oauth"` dotted key in `spec.config`? Verify against the installed CRD version after `monitoring/setup.sh` runs.
- [UNRESOLVED] Should the Dex config overlay use `envsubst` substitution for the new users' password hashes, or should a separate script generate the bcrypt hashes and inject them?
- [UNRESOLVED] Does current monitoring stack include Loki? If absent, defer pgaudit dashboard panels.

### 6. Backup Manifest

Plan:

- Keep `ScheduledBackup` with `backupOwnerReference: self` and `immediate: true` (matches existing `pg-local.yaml` pattern).
- Add on-demand `Backup` manifest at `demo/yaml/self-service/rbr-ver-db/backup-on-demand.yaml`:

```yaml
apiVersion: postgresql.cnpg.io/v1
kind: Backup
metadata:
  name: max-manual-$(date +%Y%m%d-%H%M%S)
  namespace: rbr-ver-db
spec:
  method: plugin
  pluginConfiguration:
    name: barman-cloud.cloudnative-pg.io
  cluster:
    name: verstappen
```

Use a timestamped name at apply time to avoid idempotency conflicts:

```bash
kubectl apply -f - <<EOF
apiVersion: postgresql.cnpg.io/v1
kind: Backup
metadata:
  name: max-manual-$(date +%Y%m%d-%H%M%S)
  namespace: rbr-ver-db
spec:
  method: plugin
  pluginConfiguration:
    name: barman-cloud.cloudnative-pg.io
  cluster:
    name: verstappen
EOF
```

The `verstappen` Cluster manifest must include the barman plugin reference:

```yaml
spec:
  plugins:
  - name: barman-cloud.cloudnative-pg.io
    isWALArchiver: true
    parameters:
      barmanObjectName: objectstore-rbr-ver
      serverName: verstappen
```

The `ObjectStore` must be in namespace `rbr-ver-db` (same as the Cluster).

Findings:

- `barman-cloud.cloudnative-pg.io` is the confirmed plugin name.
- On-demand `Backup` does not require parameters in `spec.pluginConfiguration`. It inherits `barmanObjectName` and `serverName` from the Cluster's `spec.plugins` section.
- ObjectStore must be in the same namespace as the Cluster. Cross-namespace ObjectStore references are not supported.
- Applying the same `Backup` name twice is idempotent (does not trigger a second backup). Use timestamps.
- `backupOwnerReference: self` on `ScheduledBackup` is correct — already used in `pg-local.yaml`.
- The installed barman plugin tracks `latest` from GitHub releases. Latest confirmed version: 0.12.0 (as of 2026-05-01). Requires cert-manager (already installed in this repo).

Open questions:

- [RESOLVED] Does the barman plugin CRD accept the manual `Backup` manifest? **Yes — confirmed schema.**
- [RESOLVED] Should backup names be timestamped? **Yes — applying the same name twice is idempotent.**
- [RESOLVED] Should `backupOwnerReference` be set? **Yes, `self` — matches existing repo pattern.**
- [UNRESOLVED] Should the docs explicitly warn that on-demand backups do not include Kubernetes Secrets (credentials, certificates)? **Likely yes — add to runbook.**\
  yes in runbook/demo readme

### 7. ESO Rotation

Plan:

- ESO refresh interval can remain the default for the first demo.
- All managed-role Secrets must carry the label `cnpg.io/reload: "true"` so CNPG automatically reconciles passwords when ESO updates the Secret.
- Add `rotate local app` script option that updates Vault KV and annotates the `ExternalSecret`:

```bash
kubectl annotate es verstappen-app -n rbr-ver-db \
  force-sync="$(date +%s)" --overwrite
```

Note: ExternalSecret name for the self-service cluster will be `verstappen-app` (not `pg-local-app`), matching the cluster/role naming convention.

Smoke test sequence:
1. Connect as app user with old password.
2. Update Vault KV app password.
3. Force ESO sync via annotation.
4. Wait for Secret update and CNPG role reconciliation.
5. Verify old password fails.
6. Verify new password succeeds.

Findings:

- `cnpg.io/reload: "true"` label on a Kubernetes Secret causes CNPG to automatically run `ALTER ROLE ... WITH PASSWORD` when the Secret changes. No `kubectl cnpg reload <cluster>` command is needed.
- Without the label, password changes are not detected by CNPG. All managed-role Secrets created for this demo must include the label.
- ESO-generated Secrets can carry this label via the `ExternalSecret` template metadata.
- CNPG suppresses logging during password operations to prevent plaintext password leakage.

Open questions:

- [RESOLVED] Does role password rotation require explicit `kubectl cnpg reload`, or does `cnpg.io/reload` on the Secret suffice? **`cnpg.io/reload: "true"` label suffices — no manual reload needed.**
- [RESOLVED] Exact CNPG reload mechanism: **watches Secret for changes, runs ALTER ROLE automatically.**
- [UNRESOLVED] Should the rotation test run from app namespace `rbr-ver` using a Job (to simulate app connectivity), or from a local psql client?\
  a job

### 8. ESO Auth Method

Plan:

- First demo: AppRole (existing pattern), documented as local-only scaffolding.
- AppRole role names: consider `eso-rbr-ver-local` (tenant-scoped) instead of current region-scoped `eso-local`. Allows future expansion to multiple tenants without naming conflicts.
- Second milestone: Kubernetes auth variant for ESO. Requires TokenReview, issuer/audience decisions, and Vault-to-Kubernetes-API reachability. Deferred.
- VDE admin auth: userpass or OIDC (human-driven), separate from ESO machine-to-machine auth.

Findings:

- No new research findings specific to ESO auth. Existing plan stands.

Open questions:

- [UNRESOLVED] Should AppRole role names become tenant-scoped now (`eso-rbr-ver-local`) or remain region-scoped (`eso-local`)? Tenant-scoped is cleaner for multi-tenant expansion but requires changing existing setup.\
  tenant scoped `eso-rbr-local` (tenant + region)
- [UNRESOLVED] Should Kubernetes auth milestone happen before or after Grafana/Dex?\
  before

## Research Closure

Status of the 12 research queue items:

1. **Traefik TCP + PostgreSQL TLS/SNI proof in Kind** — CLOSED. IngressRouteTCP CRD confirmed in v3.3.0. libpq sends SNI by default (PG14+). TLS passthrough viable. See section 1.
2. **CNPG external DNS SAN strategy for `verify-full`** — CLOSED. `serverAltDNSNames` accepts sslip.io hostnames with operator-managed TLS. Incompatible with `serverTLSSecret`. Phase 2 path confirmed. See TLS Verification Path.
3. **Current CNPG image pgaudit package proof** — CLOSED. pgaudit 18.0-2.pgdg13+1 confirmed installed by pulling `ghcr.io/cloudnative-pg/postgresql:18-standard-trixie`. See section 3.
4. **CNPG managed role password rotation proof with ESO** — CLOSED. `cnpg.io/reload: "true"` label triggers auto-reconciliation. No manual reload needed. See section 7.
5. **Barman plugin CRD version compatibility for manual `Backup`** — CLOSED. Schema confirmed. No `pluginConfiguration.parameters` needed for on-demand backup. ObjectStore must be co-located. See section 6.
6. **Exact DDL ownership and revocation SQL for stable owner role** — CLOSED. Creation and revocation statements confirmed. SET ROLE behavior confirmed. See section 2.
7. **pgAdmin `PasswordExecCommand` feasibility with Vault** — CLOSED (dead end). Disabled in container/server mode. Later approach: `.pgpass` + init container. See section 4.
8. **Dex groups claim shape in current template** — CLOSED. `staticPasswords` supports `groups` field natively. `groups` scope required. Token shape: plain string array. See section 5.
9. **Grafana Operator OAuth config for separate instance** — CLOSED. Second Grafana CR in `grafana` namespace. `spec.config` dotted keys. Client secret via env var. See section 5.
10. **Grafana OSS org/folder isolation limits** — CLOSED. Org-level isolation confirmed for OSS. Folder-level access control requires Enterprise. Folders are visual grouping only. See section 5.
11. **Loki availability for pgaudit dashboards** — DEFERRED. No Loki visible in `monitoring/`. pgaudit dashboard panels deferred. Script verification is the fallback.
12. **Rootless Podman behavior for MetalLB `EXTERNAL-IP:5432`** — CLOSED. Port 5432 reachable identically to 80/443. No special config needed. See section 1.

## Implementation Plan

### Phase 0: Pre-Implementation Checks

Before writing code, confirm the following from a running cluster:

1. ~~Confirm `allowCrossNamespace=true`~~ — **confirmed**: `traefik/values.yaml:18–19` sets `allowCrossNamespace: true` under `providers.kubernetesCRD`. No runtime check needed.
2. Confirm the installed Grafana Operator CRD version supports `"auth.generic_oauth"` dotted key in `spec.config`.
3. Confirm barman plugin 0.12.0 is the installed version (`kubectl get deployment -n cnpg-system | grep barman`).
4. Decide: tenant admin `rbr-db-admin` gets Grafana `Admin`, group admin `rbr-ver-db-admin` gets `Editor`? Or both `Editor`?
5. Decide: should `SET ROLE rbr_ver_ddl_owner` be mandatory in pgAdmin docs, or optional?

### Phase 1: Static Manifests

Create `demo/yaml/self-service/rbr-ver-db/`:

- Namespace manifests for `rbr-ver-db` and `rbr-ver`
- `ObjectStore` (`barmancloud.cnpg.io/v1`) in `rbr-ver-db`
- ESO `ExternalSecret` resources for superuser, app, and readonly (with `cnpg.io/reload: "true"` label in Secret template)
- CNPG `Cluster` named `verstappen`, bootstrap database `max`, pgaudit parameters, `serverAltDNSNames`, barman plugin reference
- CNPG `Pooler`
- `ScheduledBackup` with `backupOwnerReference: self`
- Traefik `IngressRouteTCP` for PostgreSQL TCP passthrough

Also update `traefik/values.yaml` to add the `postgres` entrypoint on port 5432 (via `additionalArguments` and `ports:` Helm values). `traefik/deployment.yaml` and `traefik/services.yaml` do not exist — Traefik is Helm-managed.

### Phase 2: Vault Setup

Add helper script or functions:

- Seed KV secrets under `cnpg/rbr/ver/max/...`
- Enable VDE (`vault secrets enable database`)
- Create stable PostgreSQL roles via `kubectl exec` after cluster is ready
- Configure `database/config/rbr-ver-max` with sslip.io connection URL
- Create Vault roles `rbr-db-admin` and `rbr-ver-db-admin` with creation/revocation statements
- Create Vault policies for tenant and group admin
- Print copy/paste commands for credential issuance

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

- Namespace `pgadmin-rbr-ver` (or share `pgadmin` namespace if already present)
- Secret for pgAdmin admin credentials
- ConfigMap for `servers.json` (preloaded server, no stored password)
- Deployment and Service
- `IngressRoute` for Traefik
- Docs showing Vault credential copy/paste flow and `SET ROLE` guidance

Later: init container with `.pgpass` populated from Vault at pod startup.

### Phase 5: Grafana + Dex

- Extend `dex-config.yaml.tpl` overlay: add Grafana static client and sample tenant/group admin users with `groups` field
- Deploy `grafana-rbr-ver` CR in `grafana` namespace with Generic OAuth config
- Pre-create `rbr` org in the Grafana instance via provisioning or Grafana API
- Add IngressRoute for `grafana-rbr-ver.<dashed-ip>.sslip.io`
- Provision dashboards: CNPG health, backup status, app credential rotation
- pgaudit dashboard panel: deferred (no Loki confirmed)

### Phase 6: Docs

Add or update:

- `docs/self-service-demo.md`
- Mermaid architecture showing Vault, ESO, CNPG, Traefik TCP, VDE, pgAdmin, Dex, Grafana
- Runbook sections for setup, rotate, backup, admin creds, and teardown
- Note explicitly: folder-level isolation requires Grafana Enterprise; OSS demo provides org-level only
- Note explicitly: pgAdmin password is manual paste; `.pgpass` init container approach is optional extension

## Open Questions — Post-Research

### Resolved — Initial Set (decisions recorded 2026-05-04)

1. [RESOLVED] Should `SET ROLE rbr_ver_ddl_owner` be mandatory or optional best practice? **Mandatory.** Must be step 1 in pgAdmin runbook and any SQL snippet provided to users. pgAdmin has no pre-connection SQL hook; enforcement is documentation only.

2. [RESOLVED] Should a read-only VDE role (`rbr-ver-db-readonly`) be added in phase 1? **Yes — add in phase 1.** Requires new stable PostgreSQL role `rbr_ver_ddl_reader` with SELECT privileges. See open questions 18–20 for role details.

3. [RESOLVED] Grafana role split: tenant admin (`rbr-db-admin`) gets `Admin`, group admin (`rbr-ver-db-admin`) gets `Editor`. **Confirmed.** `org_mapping: "rbr-db-admin:rbr:Admin rbr-ver-db-admin:rbr:Editor"`.

4. [RESOLVED] Grafana Operator CRD support for `"auth.generic_oauth"` dotted key in `spec.config`. **CONFIRMED — Grafana Operator chart v5.22.2 (installed version from `common.sh:106`). Operator v5.x maps dotted YAML keys in `spec.config` directly to grafana.ini sections. `"auth.generic_oauth":` → `[auth.generic_oauth]`. No runtime check needed; this is a documented v5 feature.**

5. [RESOLVED] Dex config overlay mechanism. **Option (a): add self-service entries directly to `dex-config.yaml.tpl` with new `envsubst` vars.** Additive changes do not break existing Vault client or `dexuser` entry. New vars: `DEX_RBR_ADMIN_PASSWORD_HASH`, `DEX_RBR_VER_ADMIN_PASSWORD_HASH`, `DEX_UNRELATED_PASSWORD_HASH`, `DEX_GRAFANA_RBR_VER_CLIENT_SECRET`. See open question 21 for hash generation.

6. [RESOLVED] pgAdmin `.pgpass` init container Vault role. **Group scope (`rbr-ver-db-admin`).** The pgAdmin instance represents the group-admin persona.

7. [RESOLVED] Rotation test. **psql Job in `rbr-ver` namespace.** See open questions 22–23 for job details.

8. [RESOLVED] AppRole naming. **Tenant-scoped: `eso-rbr-ver-local`.** Requires new `ClusterSecretStore` alongside existing `vault-approle`. See open question 24.

9. [RESOLVED] Teardown behavior for VDE. **Keep Vault VDE roles and policies after teardown** — available for post-demo inspection.

10. [RESOLVED] `docs/self-service-research-nl.md`. **Keep; update just before implementation.**

11. [RESOLVED] Loki in monitoring stack. **Not present. Integrate into `monitoring/setup.sh`.** Scope and approach: see open questions 25–29.

### Resolved — Validation Gaps (identified 2026-05-03, resolved 2026-05-04)

12. [RESOLVED] Barman Cloud chart version 0.6.0 vs plugin binary 0.12.0. **Divergence is known and intentional; both version references are correct.** No action needed.

13. [RESOLVED] Vault 2.0 VDE API. **Unchanged from 1.x.** `vault write database/config/...` and `vault write database/roles/...` commands are unaffected by the 2.0 release.

14. [RESOLVED] VDE admin user for `database/config/rbr-ver-max`. **Option (b): dedicated non-rotating PostgreSQL role** `rbr_ver_vde_admin`. Created via `kubectl exec` psql (not via CNPG managed roles — no Secret, no ESO sync). Password generated once at setup time, stored only in Vault KV at `cnpg/data/rbr/ver/vde-admin`. See open questions 30–33 for privileges and storage details.

15. [RESOLVED] Dex overlay mechanism (same as Q5). **Option (a): add directly to `dex-config.yaml.tpl`.**

16. [RESOLVED] RustFS reachability from `rbr-ver-db`. **Already works in `demo/setup.sh`; pattern carries over to `rbr-ver-db` namespace without change.**

17. [RESOLVED] ESO AppRole scope for self-service cluster. **Create new AppRole `eso-rbr-ver-local` with new `ClusterSecretStore` `vault-approle-rbr-ver`.** Pattern mirrors `eso-${REGION}` / `vault-approle` from `scripts/eso-setup.sh`. See open question 24 for policy scope.

### Unresolved — Emerged from Answers (2026-05-04)

**Read-only VDE role (from Q2)**

18. [RESOLVED] Stable role name for `rbr-ver-db-readonly` backing. **`rbr_ver_ddl_reader`** — confirmed consistent with `rbr_ver_ddl_owner` / `rbr_ver_ddl_admin` naming.

19. [RESOLVED] Privileges for `rbr_ver_ddl_reader`. Use `ALTER DEFAULT PRIVILEGES` — already the pattern in `demo/yaml/local/pg-local-eso.yaml.tpl` for the existing `readonly` managed role. Full SQL:
    ```sql
    GRANT CONNECT ON DATABASE max TO rbr_ver_ddl_reader;
    GRANT USAGE ON SCHEMA public TO rbr_ver_ddl_reader;
    GRANT SELECT ON ALL TABLES IN SCHEMA public TO rbr_ver_ddl_reader;
    ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT ON TABLES TO rbr_ver_ddl_reader;
    ```
    The existing pattern confirms this is the correct approach for the demo. Run as a one-time setup step via `kubectl exec` before VDE config.

20. [RESOLVED] Creation/revocation SQL for `rbr-ver-db-readonly` Vault role. **Confirmed:**
    ```sql
    CREATE ROLE "{{name}}" WITH LOGIN PASSWORD '{{password}}' VALID UNTIL '{{expiration}}' IN ROLE rbr_ver_ddl_reader;
    ```
    Revocation: `DROP ROLE IF EXISTS "{{name}}"` — read-only users create no objects; `REASSIGN OWNED` not needed.

**Dex new users and hashes (from Q5/Q15)**

21. [RESOLVED] How are bcrypt hashes for new Dex users generated and managed? **Option (a): add defaults to `common.sh`.** Each new var (`DEX_RBR_ADMIN_PASSWORD_HASH`, `DEX_RBR_VER_ADMIN_PASSWORD_HASH`, `DEX_UNRELATED_PASSWORD_HASH`) defaults to `${DEX_STATIC_PASSWORD_HASH}` so all share the same default password as `dexuser`. Override via env for distinct passwords. Existing `dexuser` default unchanged.

**psql rotation-test Job (from Q7)**

22. [RESOLVED] Container image for rotation-test psql Job. **`postgres:18-alpine`.**

23. [RESOLVED] Rotation-test Job connection target. **Internal only: `verstappen-rw.rbr-ver-db`.** Vault running outside the cluster already proves the external routing path; the Job only needs to verify CNPG accepted the rotated credential.

**ESO AppRole and ClusterSecretStore (from Q8/Q17)**

24. [RESOLVED] New ClusterSecretStore and Vault policy for `eso-rbr-local`:
    - ClusterSecretStore name: `vault-approle-rbr`
    - K8s Secret name: `vault-approle-rbr-creds` in ESO namespace
    - Vault policy: new narrow `eso-rbr-ver` — reads `cnpg/data/rbr/ver/*` and `cnpg/metadata/rbr/ver/*` only. Existing `eso-cnpg` (`cnpg/data/*`) is too broad.
    - Setup code: inline in `demo/self-service-setup.sh setup`.
    - Note: codebase analysis confirms `vault-approle` ClusterSecretStore uses `path: "cnpg"` + Vault internal DNS `http://vault.vault.svc.cluster.local:${VAULT_HTTP_PORT}`. New store follows identical structure.

**Loki integration (from Q11)**

25. [RESOLVED] Is Loki a separate phase or folded into `monitoring/setup.sh`? **Fold into `monitoring/setup.sh`.**

26. [RESOLVED] Loki deployment approach. **`grafana/loki` (single-binary mode) + `grafana/alloy`.** Reference: https://github.com/grafana/alloy-scenarios/tree/main/k8s/logs/README.md

27. [RESOLVED] Loki storage backend. **RustFS** — use existing `objectstore-local` RustFS instance, separate bucket (e.g., `loki/`).

28. [UNRESOLVED] Does CNPG output logs in JSON format? CNPG wraps PostgreSQL logs in JSON (instance manager). pgaudit entries appear as fields in that JSON record. **Exact field names unknown.** Need live cluster log sample: `kubectl logs -n <db-ns> <cnpg-pod> | head -5`. Alloy config (River language) will need a JSON decode + field extraction stage. Confirm: is `record.message` + `record.log_type` the correct path, or does pgaudit appear as a nested `audit` object?\
```bash
rmlan@LAPTOP-NJ4D8KHP:~/projects/cnpg-playground$ kubectl logs -n default pods/pg-local-1 | tail -5
Defaulted container "postgres" out of: postgres, bootstrap-controller (init), plugin-barman-cloud (init)
{"level":"info","ts":"2026-05-04T12:37:29.798611652Z","logger":"pgaudit","msg":"record","logging_pod":"pg-local-1","record":{"log_time":"2026-05-04 12:37:29.798 UTC","user_name":"postgres","database_name":"app","process_id":"98887","connection_from":"[local]","session_id":"69f89309.18247","session_line_num":"1","command_tag":"BIND","session_start_time":"2026-05-04 12:37:29 UTC","virtual_transaction_id":"49/22","transaction_id":"0","error_severity":"LOG","sql_state_code":"00000","application_name":"cnpg_metrics_exporter","backend_type":"client backend","query_id":"3053595831065363910","audit":{"audit_type":"SESSION","statement_id":"1","substatement_id":"1","class":"READ","command":"SELECT","statement":"SELECT NOT pg_catalog.pg_is_in_recovery()\n  OR pg_catalog.current_setting('archive_mode') = 'always'","parameter":"<none>"}}}
{"level":"info","ts":"2026-05-04T12:38:29.75136131Z","logger":"pgaudit","msg":"record","logging_pod":"pg-local-1","record":{"log_time":"2026-05-04 12:38:29.751 UTC","user_name":"postgres","database_name":"app","process_id":"98919","connection_from":"[local]","session_id":"69f89345.18267","session_line_num":"1","command_tag":"BIND","session_start_time":"2026-05-04 12:38:29 UTC","virtual_transaction_id":"71/21","transaction_id":"0","error_severity":"LOG","sql_state_code":"00000","application_name":"cnpg_metrics_exporter","backend_type":"client backend","query_id":"3133205611730249372","audit":{"audit_type":"SESSION","statement_id":"1","substatement_id":"1","class":"READ","command":"SELECT","statement":"SELECT EXTRACT(EPOCH FROM pg_postmaster_start_time) AS start_time\nFROM pg_catalog.pg_postmaster_start_time()","parameter":"<none>"}}}
{"level":"info","ts":"2026-05-04T12:38:29.808001407Z","logger":"pgaudit","msg":"record","logging_pod":"pg-local-1","record":{"log_time":"2026-05-04 12:38:29.807 UTC","user_name":"postgres","database_name":"app","process_id":"98930","connection_from":"[local]","session_id":"69f89345.18272","session_line_num":"1","command_tag":"BIND","session_start_time":"2026-05-04 12:38:29 UTC","virtual_transaction_id":"82/20","transaction_id":"0","error_severity":"LOG","sql_state_code":"00000","application_name":"cnpg_metrics_exporter","backend_type":"client backend","query_id":"3053595831065363910","audit":{"audit_type":"SESSION","statement_id":"1","substatement_id":"1","class":"READ","command":"SELECT","statement":"SELECT NOT pg_catalog.pg_is_in_recovery()\n  OR pg_catalog.current_setting('archive_mode') = 'always'","parameter":"<none>"}}}
{"level":"info","ts":"2026-05-04T12:39:29.749529217Z","logger":"pgaudit","msg":"record","logging_pod":"pg-local-1","record":{"log_time":"2026-05-04 12:39:29.749 UTC","user_name":"postgres","database_name":"app","process_id":"98960","connection_from":"[local]","session_id":"69f89381.18290","session_line_num":"1","command_tag":"BIND","session_start_time":"2026-05-04 12:39:29 UTC","virtual_transaction_id":"3/26","transaction_id":"0","error_severity":"LOG","sql_state_code":"00000","application_name":"cnpg_metrics_exporter","backend_type":"client backend","query_id":"3053595831065363910","audit":{"audit_type":"SESSION","statement_id":"1","substatement_id":"1","class":"READ","command":"SELECT","statement":"SELECT NOT pg_catalog.pg_is_in_recovery()\n  OR pg_catalog.current_setting('archive_mode') = 'always'","parameter":"<none>"}}}
{"level":"info","ts":"2026-05-04T12:39:29.774869985Z","logger":"pgaudit","msg":"record","logging_pod":"pg-local-1","record":{"log_time":"2026-05-04 12:39:29.774 UTC","user_name":"postgres","database_name":"app","process_id":"98965","connection_from":"[local]","session_id":"69f89381.18295","session_line_num":"1","command_tag":"BIND","session_start_time":"2026-05-04 12:39:29 UTC","virtual_transaction_id":"8/24","transaction_id":"0","error_severity":"LOG","sql_state_code":"00000","application_name":"cnpg_metrics_exporter","backend_type":"client backend","query_id":"3133205611730249372","audit":{"audit_type":"SESSION","statement_id":"1","substatement_id":"1","class":"READ","command":"SELECT","statement":"SELECT EXTRACT(EPOCH FROM pg_postmaster_start_time) AS start_time\nFROM pg_catalog.pg_postmaster_start_time()","parameter":"<none>"}}}

rmlan@LAPTOP-NJ4D8KHP:~/projects/cnpg-playground$ kubectl logs -n default pods/pg-local-1 | head -5
Defaulted container "postgres" out of: postgres, bootstrap-controller (init), plugin-barman-cloud (init)
{"level":"info","ts":"2026-05-02T22:21:54.298559589Z","msg":"OS distribution is supported","logger":"instance-manager","logging_pod":"pg-local-1","entry":{"version":"13 (trixie)","deprecatedFrom":"2028-08-09T00:00:00Z","supportedUntil":"2030-06-30T00:00:00Z"}}
{"level":"info","ts":"2026-05-02T22:21:54.298683486Z","msg":"Starting CloudNativePG Instance Manager","logger":"instance-manager","logging_pod":"pg-local-1","version":"1.29.0","build":{"Version":"1.29.0","Commit":"23eae00cd","Date":"2026-04-01"},"skipNameValidation":false}
{"level":"info","ts":"2026-05-02T22:21:54.636938458Z","msg":"starting tablespace manager","logger":"instance-manager","logging_pod":"pg-local-1"}
{"level":"info","ts":"2026-05-02T22:21:54.637009057Z","msg":"starting external server manager","logger":"instance-manager","logging_pod":"pg-local-1"}
{"level":"info","ts":"2026-05-02T22:21:54.637035256Z","msg":"starting controller-runtime manager","logger":"instance-manager","logging_pod":"pg-local-1"}
```

29. [RESOLVED] Should `grafana-rbr-ver` also get a Loki datasource? **Yes — both `grafana` (main) and `grafana-rbr-ver` need Loki datasource.** pgaudit panels go to both instances.

**VDE admin role (from Q14)**

30. [RESOLVED] Name for dedicated VDE admin PostgreSQL role. **`rbr_ver_vde_admin`** — confirmed.

31. [RESOLVED] PostgreSQL privileges for `rbr_ver_vde_admin`. **Confirmed by live cluster test (PG18, 2026-05-04). `WITH ADMIN OPTION` required on all three GRANTs:**
    ```sql
    CREATE ROLE rbr_ver_vde_admin WITH LOGIN CREATEROLE;
    GRANT CONNECT ON DATABASE max TO rbr_ver_vde_admin;
    GRANT rbr_ver_ddl_owner TO rbr_ver_vde_admin WITH ADMIN OPTION;
    GRANT rbr_ver_ddl_admin TO rbr_ver_vde_admin WITH ADMIN OPTION;
    GRANT rbr_ver_ddl_reader TO rbr_ver_vde_admin WITH ADMIN OPTION;
    ```
    Without `WITH ADMIN OPTION`: `IN ROLE <role>` in `CREATE ROLE` fails with `permission denied to grant role`.

32. [RESOLVED] PG18 REASSIGN OWNED privilege test. **Confirmed: works without SUPERUSER** with the correct pattern:
    1. GRANT stable roles to vde_admin `WITH ADMIN OPTION`
    2. `creation_statements` includes `GRANT "{{name}}" TO rbr_ver_vde_admin` — gives vde_admin **membership** in the dynamic role (ADMIN OPTION alone is not sufficient for REASSIGN OWNED)
    3. `rbr_ver_ddl_owner` has `CREATE ON SCHEMA public` (dynamic users need this when they `SET ROLE`)
    Live cluster verified: `tableowner = rbr_ver_ddl_owner` after full create/reassign/drop cycle. No SUPERUSER needed.

33. [RESOLVED] VDE admin password storage. **Step 3 (Vault KV) is needed.** Flow confirmed:
    1. `VDE_ADMIN_PASS=$(openssl rand -hex 32)`
    2. `kubectl exec` → `CREATE ROLE rbr_ver_vde_admin WITH LOGIN CREATEROLE PASSWORD '${VDE_ADMIN_PASS}'; ...`
    3. `vault kv put cnpg/rbr/ver/vde-admin username=rbr_ver_vde_admin password=${VDE_ADMIN_PASS}`
    4. `vault kv get -field=password cnpg/rbr/ver/vde-admin` (for VDE config step)

**pgAdmin namespace (new finding)**

34. [RESOLVED] pgAdmin deployment for self-service. **Option (b): second Deployment `pgadmin-rbr-ver` in existing `pgadmin` namespace.**
    Codebase findings: `pgadmin/deployment.yaml` is fully hardcoded (`name: pgadmin`, ConfigMap `pgadmin-servers`, Secret `pgadmin-credentials`, Service `pgadmin`). New deployment requires all-new names. Existing `servers.json.tpl` uses internal K8s DNS (`pg-local-rw.${CNPG_DEMO_NAMESPACE}.svc.cluster.local`). See Q35-Q36 for new open questions derived from this.

### Codebase Analysis Findings and New Questions (2026-05-04)

**pgAdmin option (b) details**

35. [RESOLVED] `servers.json` hostname. **External: `verstappen-rbr-ver-db.<dashed-ip>.sslip.io`.** Already specified in Section 4 (pgAdmin Preconfiguration) phase 1 plan.

36. [RESOLVED] `SSLMode` in self-service `servers.json`. **`require`.** Already specified in Section 4 phase 1 plan schema.

**Traefik postgres entrypoint**

37. [UNRESOLVED] Confirm Traefik Helm chart v39.x `ports:` section structure for a TCP entrypoint. The existing `traefik/values.yaml` has no `ports:` section — all current ports (80, 443, traefik) use Helm defaults. Adding `postgres` requires explicit entry. Proposed:
    ```yaml
    ports:
      postgres:
        port: 5432
        expose:
          default: true
        exposedPort: 5432
        protocol: TCP
    ```
    Question: does `expose.default: true` expose the port on the `LoadBalancer` Service, or is a separate `service.ports` override needed? Traefik v3 Helm chart docs needed.\
    use `expose.default: true`. See, https://oneuptime.com/blog/post/2026-01-07-metallb-traefik-ingress/view#tcp-and-udp-routing

**Loki + Alloy details**

38. [UNRESOLVED] GrafanaDatasource multi-instance strategy for Loki. Should `grafana-rbr-ver` share the `dashboards: "grafana"` label with the main instance, receiving all datasources (Prometheus + Loki)? Or use a separate label and separate `GrafanaDatasource` resources? Decision: should `grafana-rbr-ver` have access to Prometheus metrics too, or only Loki?\
    Also metric access is needed

39. [RESOLVED] Loki deployment namespace. **`grafana` namespace** — consistent with Grafana Operator pattern. Loki Service reachable from Grafana instances in same namespace without cross-namespace datasource config.

40. [UNRESOLVED] How is the RustFS `backups/` bucket created currently, and what is the `objectstore-local` Service namespace? Need to:
    - Confirm `objectstore-local` K8s Service namespace (likely `demo-local-db` or a dedicated namespace)\
      confirmed
    - Confirm bucket auto-creation vs. explicit init step in `scripts/setup.sh`\
      explicit
    - Decide: create Loki bucket (`loki/`) via same init mechanism, or add a step in `monitoring/setup.sh`\
      part of setup
    - Decide: Loki uses same S3 credentials as barman, or separate RustFS user/policy?\
      use the same

41. [UNRESOLVED] Alloy chart version and River config approach for k8s log collection. Need:
    - Current stable `grafana/alloy` Helm chart version to pin in `common.sh`\
      chart version: 1.8.0
    - Current stable `grafana-community/loki` chart version for single-binary mode\
      chart version: 13.5.0. loki chart moved to "grafana-community"
    - River config structure: does the alloy-scenarios k8s/logs example use `discovery.kubernetes` → `loki.source.kubernetes` → `loki.write`? Confirm pipeline and any required JSON decode stage for CNPG logs.\
      see: https://raw.githubusercontent.com/grafana/alloy-scenarios/refs/heads/main/k8s/logs/loki-values.yml https://raw.githubusercontent.com/grafana/alloy-scenarios/refs/heads/main/k8s/logs/k8s-monitoring-values.yml https://raw.githubusercontent.com/grafana/alloy-scenarios/refs/heads/main/k8s/metrics/k8s-monitoring-values.yml

**ESO ExternalSecret label**

42. [UNRESOLVED] Does `pg-local-eso.yaml.tpl` already include `cnpg.io/reload: "true"` on its ExternalSecret template output? The demo `demo/eso-vault.sh` rotates secrets and the existing cluster reacts — but it is unclear if the label is present in the template or if reload is triggered another way. Verify before writing new ExternalSecrets.\
    part of the `externalsecret`s

**VDE creation/revocation with rbr_ver_ddl_reader**

43. [RESOLVED] `rbr_ver_vde_admin` needs `GRANT rbr_ver_ddl_reader TO rbr_ver_vde_admin`. **Yes — required.** PG16+ `CREATE ROLE ... IN ROLE <x>` requires executor to be member of `<x>`. Without this grant, the read-only dynamic user creation statement fails. Add to Q31 SQL block. Updated Q31 SQL:
    ```sql
    CREATE ROLE rbr_ver_vde_admin WITH LOGIN CREATEROLE;
    GRANT CONNECT ON DATABASE max TO rbr_ver_vde_admin;
    GRANT rbr_ver_ddl_owner TO rbr_ver_vde_admin;
    GRANT rbr_ver_ddl_admin TO rbr_ver_vde_admin;
    GRANT rbr_ver_ddl_reader TO rbr_ver_vde_admin;
    ```

**pgAdmin second deployment script**

44. [RESOLVED] pgAdmin rbr-ver setup script location. **Inline in `demo/self-service-setup.sh`.** Existing `demo/pgadmin-setup.sh` is region-scoped and not tenant-aware; extending it would change the existing demo. Keep self-service pgAdmin setup self-contained.

## Research Directions — Post-Answer (2026-05-04)

### A. VDE Admin Role Privilege Verification (blocks Phase 2 SQL design)

Verify PG18: `CREATEROLE` + membership in `rbr_ver_ddl_admin` + `rbr_ver_ddl_owner` sufficient for full creation/revocation cycle without SUPERUSER? See Q32. **Run live cluster test before finalising Phase 2 SQL.** Key check: `REASSIGN OWNED BY "{{name}}" TO rbr_ver_ddl_owner` — executor must be member of both source and target roles.

### B. Read-Only VDE Role SQL — CLOSED

Q18, Q19, Q20 all resolved. SQL confirmed. No further research needed.

### C. Loki + Alloy Integration (blocks Phase 5 and monitoring/setup.sh extension)

Decisions made: `grafana/loki` (single-binary) + `grafana/alloy`, RustFS backend, fold into `monitoring/setup.sh`. Remaining unknowns:
- Q28: exact CNPG JSON log structure and pgaudit field path — need live cluster log sample
- Q39: Loki deployment namespace
- Q40: RustFS `loki/` bucket creation
- Q41: Alloy chart version to pin + River config for k8s log collection + JSON decode

Suggested: fetch Alloy k8s logs scenario (see Q41) + run `kubectl logs -n <db-ns> <cnpg-pod> | head -3` on live cluster.

### D. psql Job Manifest (blocks Phase 3 rotation demo)

Q22 (alpine) and Q23 (internal) resolved. Draft Job manifest with:
- Image: `postgres:18-alpine`
- Target: `verstappen-rw.rbr-ver-db:5432`
- Secret mount: ESO-synced app secret (new credential after rotation)
- `restartPolicy: Never`
- Triggered from `demo/self-service-setup.sh rotate local app`

### E. ESO AppRole Policy Scope — CLOSED

Q24 resolved. New narrow policy `eso-rbr-ver` + new AppRole `eso-rbr-local` + new `ClusterSecretStore` `vault-approle-rbr`. Setup inline in `demo/self-service-setup.sh`.

### F. pgAdmin Existing Setup — CLOSED

Codebase read. Deployment hardcoded. Option (b) design captured in Q34-Q36.

### G. Dex Hash Generation — CLOSED

Q21 resolved. Option (a) confirmed. Embed defaults as `${DEX_STATIC_PASSWORD_HASH}` fallback in `common.sh`.

### H. pgAdmin Option (b) Design (blocks Phase 4)

Existing `pgadmin/deployment.yaml` is fully hardcoded (all names, configmap, secret). New Deployment `pgadmin-rbr-ver` in `pgadmin` namespace needs:
- `pgadmin-rbr-ver` Deployment, Service, Secret, ConfigMap, IngressRoute
- `servers.json` should use internal DNS or external hostname (see Q35)
- `SSLMode` choice (see Q36)
- Script changes: extend `demo/self-service-setup.sh` with pgAdmin-rbr-ver deploy step (or call `demo/pgadmin-setup.sh` with a flag)

Open: can the existing `demo/pgadmin-setup.sh` be reused with params, or does it need a separate function? Currently it loops over regions and uses `CNPG_DEMO_NAMESPACE` — not tenant-aware.

### I. Traefik `ports:` Section (blocks Phase 1 Traefik config)

`traefik/values.yaml` has no `ports:` section. The Traefik Helm chart v39.x needs a `ports.postgres:` entry to add the containerPort and Service port. Confirm structure:
```yaml
ports:
  postgres:
    port: 5432
    expose:
      default: true
    exposedPort: 5432
    protocol: TCP
```
Also confirm: is the existing Traefik Service type `LoadBalancer` already exposing 80/443 via Helm defaults? If `ports:` section is absent and those work, adding `postgres` is purely additive.

### J. Loki + Alloy Chart Versions (blocks Phase 5 `common.sh` additions)

Need to pin:
- `LOKI_CHART_VERSION` for `grafana/loki`
- `ALLOY_CHART_VERSION` for `grafana/alloy`
Add to `common.sh` alongside existing chart version vars (line 99-107).
Research: current stable versions of both charts. Check Helm repo `grafana/loki` and `grafana/alloy` release tags.

### K. RustFS Loki Bucket Setup (blocks Phase 5 Loki config)

`objectstore-local:9000` hosts existing `backups/` bucket. Loki needs separate `loki/` bucket. Questions:
- What namespace is the `objectstore-local` Service in? If `demo-local-db`, Loki config must use FQDN `objectstore-local.demo-local-db.svc.cluster.local:9000`.
- How is the `backups/` bucket created currently — is there a bucket init step in `scripts/setup.sh` or is it auto-created?
- Loki S3 credentials: same access/secret key as barman, or separate RustFS user?

### L. GrafanaDatasource Multi-Instance Strategy (blocks Phase 5)

Existing `GrafanaDatasource` (Prometheus) uses `instanceSelector: matchLabels: dashboards: "grafana"` and targets only the main `grafana` instance. For Loki datasource in both instances:
- Option (a): add label `dashboards: "grafana"` to `grafana-rbr-ver` CR → it receives all existing datasources (Prometheus + Loki). Simple but shares all datasources.
- Option (b): separate `GrafanaDatasource` resources per instance, each with its own `matchLabels`. Explicit, no accidental datasource sharing.\
  Do Option B

Decision needed: should `grafana-rbr-ver` also get the Prometheus datasource, or only Loki?\
both metrics and logs wanted

### M. ESO ExternalSecret Label Injection (blocks Phase 1 manifest)

ESO v2.4.1 supports `spec.target.template.metadata.labels`. The `cnpg.io/reload: "true"` label must appear on the generated Kubernetes Secret. Existing `pg-local-eso.yaml.tpl` — does it include this label? Confirm by reading the full ExternalSecret resources in that template. All new ExternalSecrets for `rbr-ver-db` managed roles must include:
```yaml
spec:
  target:
    template:
      metadata:
        labels:
          cnpg.io/reload: "true"
```

## Source Links

- CloudNativePG PostgreSQL configuration and managed `pgaudit`: https://cloudnative-pg.io/docs/current/postgresql_conf/
- CloudNativePG backup methods: https://cloudnative-pg.io/docs/1.29/backup/
- CloudNativePG certificates and `serverAltDNSNames`: https://cloudnative-pg.io/docs/1.29/certificates/
- CloudNativePG declarative role management: https://cloudnative-pg.io/docs/current/declarative_role_management/
- CloudNativePG external secrets integration: https://cloudnative-pg.io/docs/current/cncf-projects/external-secrets/
- Barman Cloud CNPG-I plugin concepts: https://cloudnative-pg.io/plugin-barman-cloud/docs/concepts
- Barman Cloud CNPG-I plugin usage: https://cloudnative-pg.io/plugin-barman-cloud/docs/usage/
- Vault PostgreSQL database secrets engine: https://developer.hashicorp.com/vault/docs/secrets/databases/postgresql
- Vault Kubernetes auth: https://developer.hashicorp.com/vault/docs/auth/kubernetes
- External Secrets Operator Vault provider: https://external-secrets.io/latest/provider/hashicorp-vault/
- External Secrets Operator manual refresh: https://external-secrets.io/latest/api/externalsecret/
- Traefik `IngressRouteTCP`: https://doc.traefik.io/traefik/reference/routing-configuration/kubernetes/crd/tcp/ingressroutetcp/
- Traefik v3.3.0 CRD definition (includes IngressRouteTCP v1alpha1): https://raw.githubusercontent.com/traefik/traefik/v3.3.0/docs/content/reference/dynamic-configuration/kubernetes-crd-definition-v1.yml
- Grafana Generic OAuth: https://grafana.com/docs/grafana/latest/setup-grafana/configure-access/configure-authentication/generic-oauth/
- Grafana Team Sync availability (Enterprise only): https://grafana.com/docs/grafana/latest/setup-grafana/configure-access/configure-team-sync/
- Grafana Operator documentation: https://grafana.github.io/grafana-operator/docs/
- pgAdmin server import/export: https://www.pgadmin.org/docs/pgadmin4/latest/import_export_servers.html
- pgAdmin container deployment: https://www.pgadmin.org/docs/pgadmin4/latest/container_deployment.html
- pgAdmin GitHub issue on `PasswordExecCommand` in containers: https://github.com/pgadmin-org/pgadmin4/issues/6792
- Dex configuration reference: https://dexidp.io/docs/configuration/
- PostgreSQL libpq SSL documentation (SNI): https://www.postgresql.org/docs/current/libpq-ssl.html
- PostgreSQL CREATE ROLE: https://www.postgresql.org/docs/current/sql-createrole.html
- PostgreSQL SET ROLE and object ownership: https://www.postgresql.org/docs/current/sql-set-role.html
- Grafana Alloy Helm chart: https://github.com/grafana/alloy/releases
- Grafana Loki Helm chart: https://github.com/grafana/loki/releases
- Grafana Alloy k8s logs scenario: https://github.com/grafana/alloy-scenarios/tree/main/k8s/logs
- Grafana Operator v5 spec.config reference: https://grafana.github.io/grafana-operator/docs/api/#grafanaspec
- Traefik Helm chart v3 ports configuration: https://doc.traefik.io/traefik/reference/install-configuration/providers/kubernetes/helm/
