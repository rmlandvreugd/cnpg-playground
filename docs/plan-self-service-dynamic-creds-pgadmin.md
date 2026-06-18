# Self-service: Vault-dynamic app creds + per-namespace mTLS pgAdmin (temp DBA)

## Context

`demo/self-service-setup.sh` today provisions database login via Vault KV + ESO: it writes
`cnpg/rbr/ver/{superuser,app,readonly}` to Vault KV, projects each through an `ExternalSecret` into
the `rbr-ver-db` namespace as a `cnpg.io/reload` Secret, and CNPG (`managed.roles` in
`cluster-verstappen.yaml.tpl`) consumes them. The `app` role's password is **statically owned by
CNPG** (`passwordSecret: verstappen-app`), there is a permanent `readonly` role, and the existing
pgAdmin (`demo/yaml/self-service/pgadmin/`) sits in a **shared `pgadmin` namespace** connecting over
Traefik with a **password**.

We are changing the credential model to be **Vault-driven and ephemeral**, and making pgAdmin a
**per-database, mTLS-only** client:

1. The `app` user's password becomes a **Vault-managed dynamic credential** (rotated by Vault, not
   pinned by CNPG).
2. The permanent **`readonly` role is removed entirely** (both the static CNPG role and the dynamic
   Vault role).
3. pgAdmin is deployed **inside the DB namespace** (`rbr-ver-db`) and connects to `verstappen-rw`
   over **mTLS** (`SSLMode=verify-full`, client cert, no password) as a **temporary DBA** role that
   the provisioning script mints on demand with a TTL.

This is the script-first realisation (Phase 1). Phase 2 documents wrapping the identical steps as
Argo Events + Workflows (the original event-driven goal), with no rework of the Phase-1 artifacts.

## Locked decisions (from Q&A)

| Decision | Choice |
|---|---|
| **App credential model** | **Static-role password rotation.** Vault `database/static-roles/app` keeps username `app`, `rotation_period=24h`; CNPG `managed.roles.app` **drops `passwordSecret`** (CNPG stops managing the password); ESO reads `database/static-creds/app` → Secret `verstappen-app`. |
| **Engine** | **Both: script now, Argo later.** Phase 1 = extend `self-service-setup.sh` end-to-end. Phase 2 = documented follow-up wrapping the same steps in Argo Events + Workflows. |
| **pgAdmin auth** | **Full mTLS.** Fixed username = cert CN; cert-manager `Certificate`; `SSLMode=verify-full`; **no password** to Postgres. |
| **Readonly removal** | **Remove both** static (`managed.roles.readonly`, `externalsecret-verstappen-readonly`, KV `cnpg/rbr/ver/readonly`) **and** dynamic (`database/roles/rbr-ver-db-readonly`). pgAdmin gets **only** the temp DBA. |
| **Temp DBA identity** | **Script-minted, fixed name + TTL.** Script (as `vde-admin`) runs `CREATE ROLE rbr_ver_db_dba_<gen> LOGIN VALID UNTIL '<ttl>' IN ROLE rbr_ver_ddl_admin`; cert-manager issues a `Certificate` with `CN=<that name>`; `pg_hba … cert` authenticates it (no password). "Temporary" = `VALID UNTIL` + teardown `DROP ROLE`. |

## Architecture & flow (Phase 1)

```
provision  (self-service-setup.sh, runs as vault-admin + vde-admin)
   │
   ├─ Vault: write database/static-roles/app (username=app, rotation_period=24h)
   │         → Vault rotates app's password and owns it
   │         → ESO ClusterSecretStore(db) reads database/static-creds/app
   │            └─► Secret verstappen-app (cnpg.io/reload)  ──► CNPG app role (no passwordSecret)
   │
   ├─ Postgres (psql as vde-admin):
   │     CREATE ROLE rbr_ver_db_dba_<gen> LOGIN VALID UNTIL '<now+TTL>'
   │            IN ROLE rbr_ver_ddl_admin
   │
   ├─ cert-manager: Certificate CN=rbr_ver_db_dba_<gen>, issuerRef ClusterIssuer/vault-pki
   │            └─► Secret pgadmin-verstappen-dba-tls (tls.crt/tls.key/ca.crt)
   │
   └─ pgAdmin in rbr-ver-db: Deployment + Service + IngressRoute + servers.json
            initContainer stages certs (chmod 600 key, chown 5050)
            └──mTLS, verify-full──► verstappen-rw:5432
                 pg_hba: hostssl all all all cert   (CN rbr_ver_db_dba_<gen> → that role)
```

## Reuse (do **not** reinvent)

- **mTLS Certificate pattern** — `demo/eso-vault.sh` `connect-mtls)` block (~L343–391): `Certificate`
  with `CN=ROLE`, `dnsNames:[ROLE]`, `issuerRef: ClusterIssuer/vault-pki`, ECDSA 256, `kubectl wait`
  Ready; plus `stage_secret_certs()` (~L107) which `chmod 600` the key for libpq.
- **CNPG mTLS server + pg_hba CN→role** — `demo/yaml/local/pg-local-eso.yaml.tpl` (L61–82):
  `certificates: {serverTLSSecret, serverCASecret: vault-pki-bundle, clientCASecret: vault-pki-bundle}`
  and `pg_hba: [hostssl replication streaming_replica all cert, hostssl all cnpg_pooler_pgbouncer all cert,
  hostssl all all all cert, host all all all scram-sha-256]`. **Verstappen lacks all of this** — mirror it.
- **pgAdmin manifest shapes** — `demo/yaml/self-service/pgadmin/*` (Deployment, Service, ConfigMap
  servers.json, Secret creds, IngressRoute) — re-namespace into `rbr-ver-db` and add the mTLS volumes.
- **Vault DB engine machinery** — already in `self-service-setup.sh` (~L270–335): `database/config`,
  dynamic `database/roles`, approle policy writes, `_vcmd`, `wait_for_external_secret`, `psql_primary`.
- **ESO force-sync idiom** — `kubectl annotate externalsecret … force-sync=$(date +%s)` (eso-vault.sh).

## Changes

### A. Vault — app static-role + remove readonly (`self-service-setup.sh`)
- After bootstrap (the `app` role must already exist), write
  `vault write database/static-roles/app db_name=<conn> username=app rotation_period=24h
  rotation_statements=ALTER ROLE "app" WITH PASSWORD '{{password}}'`. Vault now owns/rotates the
  password. (One-time bootstrap still uses the initial `verstappen-app` Secret; static-role takes over
  after.)
- Grant the approle policy `read` on `database/static-creds/app`.
- **Remove dynamic** `database/roles/rbr-ver-db-readonly` and its `allowed_roles` entry; drop the
  `readonly` references in the KV-write, ESO-loop, rotate, creds, and teardown paths (mapped earlier:
  usage ~L22/24, policy ~L123–125, KV ~L182, ESO loops ~L193/197, allowed_roles ~L310, dynamic role
  ~L328–333, echo ~L524, rotate ~L543–544, creds branch ~L619–621, teardown ~L638).

### B. New ESO store for the database engine — `vault/eso/clustersecretstore-db.yaml.tpl`
- `ClusterSecretStore` `vault-approle-rbr-db`, vault provider pointed at the **`database`** secret
  engine (Vault KV-v2 store `vault-approle-rbr` cannot read `database/*`). Same approle auth +
  `caProvider` → `vault-pki-bundle`. Applied by the setup script before repointing the app ES.

### C. App ExternalSecret → static-creds (`externalsecret-verstappen-app.yaml`)
- `secretStoreRef` → `vault-approle-rbr-db`; `data.remoteRef.key` → `database/static-creds/app`
  (`username`, `password`); keep target Secret name `verstappen-app` + `cnpg.io/reload: "true"`.

### D. Cluster mTLS + role changes (`cluster-verstappen.yaml.tpl`)
- `managed.roles.app`: **delete `passwordSecret`** (CNPG no longer manages the password).
- **Delete** `managed.roles.readonly` and the `externalsecret-verstappen-readonly.yaml` file; remove
  `cnpg/rbr/ver/readonly` from the KV write path.
- Add the `certificates` block (mirror pg-local: `serverTLSSecret: verstappen-server-tls`,
  `serverCASecret`/`clientCASecret: vault-pki-bundle`) and the four `pg_hba` lines (incl.
  `hostssl all all all cert`).
- Add a cert-manager `Certificate verstappen-server-tls` (issuerRef `ClusterIssuer/vault-pki`) whose
  SANs include `verstappen-rw` and the existing `verstappen-rbr-ver-db.${TRAEFIK_IP_DASHED}.sslip.io`
  so `verify-full` from pgAdmin succeeds.
- Ensure `rbr_ver_ddl_admin` exists (it is the DBA parent role the temp DBA inherits) — add to
  `postInitApplicationSQL` if not already created elsewhere.

### E. `provision` subcommand — mint temp DBA + cert (`self-service-setup.sh`)
- New subcommand that, as `vde-admin` via `psql_primary`:
  `gen=$(openssl rand -hex 4); DBA=rbr_ver_db_dba_$gen; CREATE ROLE "$DBA" LOGIN
  VALID UNTIL '<now+TTL>' IN ROLE rbr_ver_ddl_admin;` then applies a `Certificate` (CN/dnsNames=$DBA,
  ClusterIssuer/vault-pki, ECDSA 256, secret `pgadmin-verstappen-dba-tls`) reusing the connect-mtls
  shape, `kubectl wait` Ready, and `envsubst`-renders + applies the pgAdmin manifests (Change F) with
  `DBA` exported. Teardown drops the role and deletes the cert + pgAdmin resources.

### F. pgAdmin → `rbr-ver-db` + mTLS (`demo/yaml/self-service/pgadmin/*`)
- All four manifests re-namespaced to `rbr-ver-db` (servers.json ConfigMap, Secret creds, Deployment
  + Service, IngressRoute).
- `servers.json.tpl`: single server — `Host: verstappen-rw`, `Port: 5432`, `SSLMode: verify-full`,
  `Username: ${DBA}`, `MaintenanceDB: max`, `SSLCert/SSLKey/SSLRootCert: /certs/{tls.crt,tls.key,ca.crt}`.
- `deployment-pgadmin-rbr-ver.yaml`: mount Secret `pgadmin-verstappen-dba-tls`; add an `emptyDir`
  `/certs` and a `busybox` **initContainer** that copies the certs in, `chmod 600` the key, `chown
  5050` (pgAdmin uid) — libpq rejects group/world-readable `sslkey`.
- IngressRoute stays on Traefik `web`, Host `pgadmin-rbr-ver.${TRAEFIK_IP_DASHED}.sslip.io`.

### G. Docs (`docs/`)
- This plan (`docs/plan-self-service-dynamic-creds-pgadmin.md`).
- A **Phase 2 (Argo)** section: same propagation chain wrapped as Argo Events resource EventSource
  (watch `verstappen-app` Secret, marker label) → Sensor → Workflow re-running steps E/F as native
  `resource` templates; ArgoCD + Rollouts install-only. No Phase-1 artifact changes required.

## Files

| File | Action |
|---|---|
| `demo/self-service-setup.sh` | app static-role; drop readonly (all paths); `provision`/teardown subcommands; apply new store + pgAdmin |
| `vault/eso/clustersecretstore-db.yaml.tpl` | **new** — `vault-approle-rbr-db` (database engine) |
| `demo/yaml/self-service/rbr-ver-db/externalsecret-verstappen-app.yaml` | repoint store + `database/static-creds/app` |
| `demo/yaml/self-service/rbr-ver-db/externalsecret-verstappen-readonly.yaml` | **delete** |
| `demo/yaml/self-service/rbr-ver-db/cluster-verstappen.yaml.tpl` | drop app passwordSecret + readonly role; add mTLS certs + pg_hba; add server Certificate |
| `demo/yaml/self-service/pgadmin/servers.json.tpl` | ns `rbr-ver-db`; `verstappen-rw`; verify-full; `${DBA}`; cert paths |
| `demo/yaml/self-service/pgadmin/deployment-pgadmin-rbr-ver.yaml` | ns `rbr-ver-db`; cert volume + emptyDir + initContainer |
| `demo/yaml/self-service/pgadmin/secret-pgadmin-rbr-ver.yaml.tpl` | ns `rbr-ver-db` |
| `demo/yaml/self-service/pgadmin/ingressroute-pgadmin-rbr-ver.yaml.tpl` | ns `rbr-ver-db` |
| `docs/plan-self-service-dynamic-creds-pgadmin.md` | **this plan** + Phase 2 Argo section |

## Verification (end-to-end)

1. `bash -n demo/self-service-setup.sh`; context = `kind-local`.
2. **App dynamic creds**: run setup → `vault read database/static-roles/app` shows
   `rotation_period=24h`; ESO `verstappen-app` Ready; `kubectl get secret verstappen-app -o
   jsonpath` password matches `vault read database/static-creds/app`; CNPG `app` login works with it.
   Force a rotation (`vault write -f database/rotate-role/app`) → ESO re-syncs → new password works.
3. **Readonly gone**: no `readonly` role in `\du`; no `externalsecret-verstappen-readonly`; no
   `database/roles/rbr-ver-db-readonly` in `vault list database/roles`.
4. **Cluster mTLS**: `kubectl get certificate verstappen-server-tls -n rbr-ver-db` Ready; `pg_hba`
   shows the `hostssl … cert` lines.
5. **provision**: `self-service-setup.sh provision` → `\du` shows `rbr_ver_db_dba_<gen>` with
   `VALID UNTIL`; `kubectl get certificate -n rbr-ver-db` shows `pgadmin-verstappen-dba-tls` Ready;
   `kubectl get deploy,svc,ingressroute -n rbr-ver-db | grep pgadmin` Available.
6. **Browser**: open `http://pgadmin-rbr-ver.<dashed-ip>.sslip.io`, log in with printed pgAdmin creds;
   the pre-loaded `verstappen-rw` server connects over SSL with **no Postgres password prompt** (cert
   auth) and has DBA/DDL privileges.
7. **Temporary**: after TTL (or teardown) the DBA role is gone — `psql` as that CN fails; pgAdmin
   resources + cert removed.

## Risks / checkpoints

- **Bootstrap ordering**: the `app` static-role can only be created **after** the role exists. Bootstrap
  with the one-time `verstappen-app` password, then create the static-role (Vault rotates → owns it),
  then repoint ESO. CNPG with no `passwordSecret` leaves the password to Vault.
- **ESO engine mount**: KV-v2 store `vault-approle-rbr` cannot read `database/*` → the separate
  `vault-approle-rbr-db` store (Change B) is required, plus the approle policy grant (Change A).
- **libpq key perms**: `sslkey` must be `chmod 600` + owned by uid 5050 → initContainer staging.
- **`verify-full` SAN**: `verstappen-rw` must be in the server cert SANs → added in Change D.
- **DDL parent role**: temp DBA inherits `rbr_ver_ddl_admin`; confirm that role exists/has the intended
  grants before minting.
- Track execution as **beads** issues (one per change A–G) created at execution time, per project rule.

---

## Phase 2 — Argo event-driven realisation (follow-up)

Phase 1 above is fully script-driven. Phase 2 wraps the **identical** provisioning steps (Changes E
and F) in the Argo ecosystem so that propagating a credential auto-triggers cert issuance + pgAdmin
deployment, with **no changes** to the Phase-1 manifests.

- **Install**: ArgoCD is **already installed and wired** as the GitOps engine for tenant resources
  (see [`plan-argocd-gitops.md`](plan-argocd-gitops.md)). Phase 2 adds only the event-driven layer:
  `argo-workflows`, `argo-events`, `argo-rollouts` via the existing `helm_upgrade_install` convention
  (`--repo-url https://argoproj.github.io/argo-helm`), plus the Argo Events NATS `EventBus`.
- **Trigger**: an Argo Events **resource EventSource** watches the ESO-created `verstappen-app`
  Secret in `rbr-ver-db`, filtered to a single marker label (e.g. `pgadmin.cnpg.io/provision=true`
  stamped via the ExternalSecret target template) so it fires once per database.
- **Reconcile**: a **Sensor** submits an Argo **WorkflowTemplate** (`provision-pgadmin`) whose DAG
  re-runs Phase-1 steps as native `resource` templates — mint the temp DBA, apply the `Certificate`,
  then apply the pgAdmin Secret/ConfigMap/Deployment/Service/IngressRoute into `rbr-ver-db`.
- **RBAC**: EventSource SA scoped to `get/list/watch secrets` in `rbr-ver-db` **only** (secrets are
  sensitive); Workflow SA bound (RoleBinding) into `rbr-ver-db` for certificates/secrets/configmaps/
  deployments/services/ingressroutes.
- **ArgoCD is already wired** as the GitOps engine for tenant resources
  ([`plan-argocd-gitops.md`](plan-argocd-gitops.md)); Phase 2 adds only the event-driven layer
  (Argo Events/Workflows) and Argo Rollouts.

## Hardened DB config user (Workstream C)

The Vault database secrets engine connects with a dedicated, least-privilege **config user** that is
distinct from both the Postgres superuser and the dynamically-issued roles:

- Create role **`rbr_ver_vde_config`** — `LOGIN`, `CREATEROLE`, **no table ownership**, **not**
  superuser. It is the connection identity in `database/config/rbr-ver-max` and the only role that
  mints/drops the dynamic roles. Replaces direct use of any broader admin role for role lifecycle.
- Enable Vault **root-credential rotation**: after configuring the connection, call
  `vault write -f database/rotate-root/rbr-ver-max` so even the config user's password is
  Vault-owned. Remove the config password from any plaintext/KV path afterward.
- Net: **no Postgres superuser anywhere in the create/delete-user path.**

Verification: `database/config/rbr-ver-max` shows `username=rbr_ver_vde_config`; `\du` shows it as
`Create role` only; `vault read database/creds/...` still issues short-TTL roles; the config
password no longer matches any seeded value (rotated).

## App deployment (Workstream E)

Deploy the sample app (`app/helm/demo-app`, Litestar/Python) into the **`rbr-ver`** namespace,
connected to the `verstappen` CNPG cluster in `rbr-ver-db`:

- **Credentials**: `credentialsMode=static`, reading the **`verstappen-app`** Secret that this plan
  already makes a Vault **static-role-rotated** credential (via the db `ClusterSecretStore`).
  Stakater Reloader restarts the app on rotation (parity with Change C/E here).
- **Connectivity**: runtime via the pooler (`pooler-rbr-ver-rw.rbr-ver-db`); **migrations** run as an
  `initContainer` against `verstappen-rw.rbr-ver-db` (direct, bypassing the pooler for DDL).
- **Image**: built from `app/Dockerfile` and `kind load`ed by `self-service-setup.sh` (ArgoCD
  deploys the chart but does not build images).
- **Ownership**: the chart is reconciled by the **ArgoCD app-of-apps**
  ([`plan-argocd-gitops.md`](plan-argocd-gitops.md)); the script only builds/loads the image and
  applies the root Application. The app's `app` role schema is owned by `rbr_ver_ddl_owner`.

Verification: `demo-app` pods Running in `rbr-ver` and serving; rotating the `app` credential
(Change A) bounces the app via Reloader with no downtime; the app reads/writes through the pooler.
