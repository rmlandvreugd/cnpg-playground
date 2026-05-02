# CNPG Self-Service Demo: Review, Research, Plan

Status: research complete — ready for implementation  
Date: 2026-05-01 (research closed 2026-05-01)  
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

Decisions added after research closure (2026-05-01):

- Traefik v3.3.0 already includes `IngressRouteTCP` CRD (`ingressroutetcps.traefik.io`, version `v1alpha1`). No separate CRD install needed.
- PostgreSQL `libpq` (PG14+) sends TLS SNI when connecting with a hostname and `sslmode=require`. Traefik `HostSNI(...)` passthrough routing is confirmed viable.
- Port 5432 is reachable from the host via the MetalLB IP on rootless Podman + Kind on Linux, identically to ports 80 and 443. No special Podman or Kind configuration is required.
- Adding the `postgres` entrypoint to Traefik requires: `--entrypoints.postgres.address=:5432` in Deployment args, a `postgres` containerPort in the Deployment, and a `postgres` port in the Traefik Service. No NET_BIND_SERVICE change is needed (5432 is unprivileged).
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
- Vault Database Secrets Engine `creation_statements`:
  ```sql
  CREATE ROLE "{{name}}" WITH LOGIN PASSWORD '{{password}}' VALID UNTIL '{{expiration}}' IN ROLE rbr_ver_ddl_admin;
  ```
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
- Add to `traefik/deployment.yaml` args: `--entrypoints.postgres.address=:5432`
- Add containerPort `5432` (name: `postgres`) to Deployment
- Add port `5432` to `traefik/services.yaml` Traefik Service
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
- Port 5432 is above 1024 (unprivileged). No `NET_BIND_SERVICE` change is needed for the Traefik container to bind it. The existing `NET_BIND_SERVICE` grant in `traefik/deployment.yaml` remains correct and harmless.
- Port 5432 is reachable from the host via the MetalLB IP on rootless Podman + Kind on Linux. The Podman user namespace does not block network namespace routing. All MetalLB ports route identically; 80/443 already working proves the network path.

Open questions:

- [RESOLVED] Does the current Traefik CRD install include TCP CRD support? **Yes — IngressRouteTCP CRD v1alpha1 included in v3.3.0 manifest.**
- [RESOLVED] Does PostgreSQL client/Vault driver send SNI with `sslmode=require` and hostname? **Yes — libpq sends SNI by default (PG14+).**
- [RESOLVED] Does rootless Podman allow host reachability to the MetalLB IP on port `5432`? **Yes — identical to ports 80/443.**
- [RESOLVED] Should Traefik dashboard HTTP/TLS setup stay untouched and only add the `postgres` entrypoint? **Yes — add postgres entrypoint only.**
- [UNRESOLVED] The IngressRouteTCP uses the `rbr-ver-db` namespace while living in `traefik`. Confirm `allowCrossNamespace=true` is active in this cluster before applying.

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
GRANT CONNECT ON DATABASE max TO rbr_ver_ddl_admin;
GRANT USAGE, CREATE ON SCHEMA public TO rbr_ver_ddl_admin;
GRANT rbr_ver_ddl_owner TO rbr_ver_ddl_admin;
```

- Create Vault role `rbr-db-admin`:

```bash
vault write database/roles/rbr-db-admin \
  db_name="rbr-ver-max" \
  creation_statements="CREATE ROLE \"{{name}}\" WITH LOGIN PASSWORD '{{password}}' VALID UNTIL '{{expiration}}' IN ROLE rbr_ver_ddl_admin;" \
  revocation_statements="REASSIGN OWNED BY \"{{name}}\" TO rbr_ver_ddl_owner; DROP OWNED BY \"{{name}}\"; DROP ROLE IF EXISTS \"{{name}}\";" \
  default_ttl="1h" \
  max_ttl="4h"
```

- Create Vault role `rbr-ver-db-admin` with the same statements (membership distinction is in the Vault policy, not the DB role creation SQL):

```bash
vault write database/roles/rbr-ver-db-admin \
  db_name="rbr-ver-max" \
  creation_statements="CREATE ROLE \"{{name}}\" WITH LOGIN PASSWORD '{{password}}' VALID UNTIL '{{expiration}}' IN ROLE rbr_ver_ddl_admin;" \
  revocation_statements="REASSIGN OWNED BY \"{{name}}\" TO rbr_ver_ddl_owner; DROP OWNED BY \"{{name}}\"; DROP ROLE IF EXISTS \"{{name}}\";" \
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
- [UNRESOLVED] Should the docs explicitly warn that on-demand backups do not include Kubernetes Secrets (credentials, certificates)? **Likely yes — add to runbook.**

### 7. ESO Rotation

Plan:

- ESO refresh interval can remain the default for the first demo.
- All managed-role Secrets must carry the label `cnpg.io/reload: "true"` so CNPG automatically reconciles passwords when ESO updates the Secret.
- Add `rotate local app` script option that updates Vault KV and annotates the `ExternalSecret`:

```bash
kubectl annotate es pg-local-app -n rbr-ver-db \
  force-sync="$(date +%s)" --overwrite
```

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
- [UNRESOLVED] Should the rotation test run from app namespace `rbr-ver` using a Job (to simulate app connectivity), or from a local psql client?

### 8. ESO Auth Method

Plan:

- First demo: AppRole (existing pattern), documented as local-only scaffolding.
- AppRole role names: consider `eso-rbr-ver-local` (tenant-scoped) instead of current region-scoped `eso-local`. Allows future expansion to multiple tenants without naming conflicts.
- Second milestone: Kubernetes auth variant for ESO. Requires TokenReview, issuer/audience decisions, and Vault-to-Kubernetes-API reachability. Deferred.
- VDE admin auth: userpass or OIDC (human-driven), separate from ESO machine-to-machine auth.

Findings:

- No new research findings specific to ESO auth. Existing plan stands.

Open questions:

- [UNRESOLVED] Should AppRole role names become tenant-scoped now (`eso-rbr-ver-local`) or remain region-scoped (`eso-local`)? Tenant-scoped is cleaner for multi-tenant expansion but requires changing existing setup.
- [UNRESOLVED] Should Kubernetes auth milestone happen before or after Grafana/Dex?

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

1. Confirm `allowCrossNamespace=true` is active in the deployed Traefik (already set in `traefik/deployment.yaml` args — verify with `kubectl get deployment traefik -n traefik -o jsonpath='{.spec.template.spec.containers[0].args}'`).
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

Also update `traefik/deployment.yaml` and `traefik/services.yaml` to add the `postgres` entrypoint on port 5432.

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

These questions were not resolved by the research closure and require explicit decisions before or during implementation:

1. Should `SET ROLE rbr_ver_ddl_owner` be mandatory (required in pgAdmin workflow docs) or optional best practice?
2. Should a read-only VDE role (`rbr-ver-db-readonly`) be added in phase 1, or deferred to phase 2?
3. Should tenant admin (`rbr-db-admin`) get Grafana `Admin` and group admin (`rbr-ver-db-admin`) get `Editor`, or should both get `Editor` for the local demo?
4. Does the installed Grafana Operator CRD version support `"auth.generic_oauth"` dotted key in `spec.config`? Verify on a running cluster before implementing phase 5.
5. Should Dex config overlay use `envsubst` for new user password hashes, or a separate bcrypt-generation step in the setup script?
6. For the pgAdmin `.pgpass` init container: use the `rbr-db-admin` Vault role (tenant scope) or `rbr-ver-db-admin` (group scope)?
7. Should the rotation test (`rotate local app`) run from a psql Job in `rbr-ver` namespace, or from a local psql client?
8. Should AppRole role names become tenant-scoped now (`eso-rbr-ver-local`) or remain region-scoped (`eso-local`)?
9. Should `demo/self-service-setup.sh teardown` remove Vault VDE roles and policies, or keep them for inspection?
10. Should `docs/self-service-research-nl.md` be deleted to avoid confusion, or left stale until implementation is complete?
11. Is Loki present in the monitoring stack? If yes, pgaudit dashboard panels become feasible. Verify with `kubectl get pods -n monitoring | grep loki` after `monitoring/setup.sh` runs.

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
