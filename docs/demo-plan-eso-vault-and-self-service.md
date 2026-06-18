# Demo Plan — eso-vault & self-service

Two distinct demo paths. Run them as separate narratives; do not interleave.
Both assume the base playground is already up (`./scripts/setup.sh local` /
`demo/self-service-setup.sh setup local` already executed) and `KUBECONFIG`
points at `k8s/kube-config.yaml`.

Shared mental model to state up front:
- **Vault** is the source of truth for secrets.
- **ESO** (External Secrets Operator) projects Vault data into K8s Secrets.
- **CNPG** consumes those Secrets; `cnpg.io/reload: "true"` makes rotation hot.
- **Traefik IngressRouteTCP** exposes Postgmaster over `:5432` on a *separate*
  MetalLB IP from the web LB.

---

## Path A — eso-vault (`demo/eso-vault.sh`)

**Theme:** "How does a platform team manage Postgres credentials as static
secrets without ever putting a password in a manifest?"

### A0. Framing (talk track, no commands)
- One CNPG cluster: `pg-local` in `$CNPG_DEMO_NAMESPACE`.
- Three credentials — `superuser`, `app`, `readonly` — each a Vault KV entry.
- ESO `ExternalSecret` per credential → renders a K8s Secret.

### A1. Show the setup is live
- `./demo/eso-vault.sh verify local superuser` — psql connectivity via the
  current ESO-synced superuser secret.
- `kubectl get externalsecrets -n $CNPG_DEMO_NAMESPACE` — show all 3 `Ready=True`.
- `kubectl get cluster pg-local -n $CNPG_DEMO_NAMESPACE` — cluster healthy.

### A2. Prove the secret really comes from Vault
- Read the live K8s Secret password (base64 -d) for `pg-local-app`.
- Read the same path from Vault KV (`vault kv get cnpg/pg-local/app` via the
  container) — show they match. No password lives in git.

### A3. Credential rotation (the money shot)
- `./demo/eso-vault.sh rotate local app`
  - Narrate: patch Vault KV with a new random password → annotate the
    ExternalSecret to force-sync → wait for the K8s Secret `resourceVersion`
    to change → `cnpg.io/reload` pushes it into Postgres → psql verifies.
- Repeat with `readonly` to show role-scoped rotation.
- Optional: rotate `superuser` to show even the bootstrap cred is hot-rotatable.

### A4. Transport security (mTLS + Traefik)
- Show the issued certs: `kubectl get certificate -n $CNPG_DEMO_NAMESPACE`
  (server, replication, tls-term-server, pooler-client, pooler-server).
- Show the two external endpoints:
  - TLS-termination: `pg-local-<ns>-t.<traefik-pg-ip-dashed>.sslip.io`
  - TLS-passthrough: `pg-local-<ns>-p.<traefik-pg-ip-dashed>.sslip.io`
- Connect from outside the cluster with the generated commands (both stage the
  needed cert/key/CA locally and print a ready-to-run `psql`; neither auto-connects):
  - `./demo/eso-vault.sh connect local <superuser|app|readonly>` — TLS-termination
    endpoint; Traefik does edge mTLS, Postgres authenticates by **password** (scram).
  - `./demo/eso-vault.sh connect-mtls local <superuser|app|readonly>` — TLS-passthrough
    endpoint; issues a **1h** client cert (CN = role) and authenticates by **certificate**
    (no password), demonstrating end-to-end mTLS to Postgres.

### A5. Teardown (only if resetting)
- `./demo/eso-vault.sh teardown local` — removes the demo namespace + Vault KV
  paths, leaving the base playground intact.

---

## Path B — self-service (`demo/self-service-setup.sh`)

**Theme:** "A developer self-serves a production-shaped Postgres: dynamic
credentials, a web console, observability, and backups — without a DBA."

Tenant model: `rbr` (org) / `ver` (group) / `verstappen` (cluster), split across
`rbr-ver-db` (data) and `rbr-ver` (app) namespaces.

### B0. Framing (talk track)
- Same Vault+ESO foundation as Path A for the *static* superuser/app/readonly.
- **New capability:** Vault **Database Secrets Engine** issues *dynamic*,
  1h-TTL Postgres logins mapped to stable roles via `SET ROLE`.

### B1. Show the stack is live
- `./demo/self-service-setup.sh verify local` — superuser psql + version().
- `kubectl get cluster verstappen -n rbr-ver-db` — Ready.
- `kubectl get externalsecrets -n rbr-ver-db` — superuser/app/readonly synced.

### B2. Dynamic credentials (the differentiator vs Path A)
- `./demo/self-service-setup.sh creds local tenant-admin`
  - Vault role `rbr-db-admin`, 1h TTL; note the just-in-time username/password.
- `./demo/self-service-setup.sh creds local group-admin` (role `rbr-ver-db-admin`).
- `./demo/self-service-setup.sh creds local readonly` (role `rbr-ver-db-readonly`).
- Emphasize the `SET ROLE rbr_ver_ddl_owner;` requirement before DDL so objects
  get stable ownership independent of the ephemeral login.

### B3. Developer console (pgAdmin)
- Open `https://pgadmin-...sslip.io` (printed by setup), authenticate via
  Authelia (`rbr-ver-admin@example.com`).
- Paste `group-admin` dynamic creds into the Connect dialog → run a query →
  `SET ROLE rbr_ver_ddl_owner;` then `CREATE TABLE`.

### B4. Static-credential rotation (parity with Path A)
- `./demo/self-service-setup.sh rotate local app`
- `./demo/self-service-setup.sh rotate local readonly`
  - Same Vault-patch → ESO force-sync → psql verify flow, scoped to `rbr-ver-db`.

### B5. On-demand backup to object store
- `./demo/self-service-setup.sh backup local`
  - Creates a `Backup` CR (`method: plugin`, `barman-cloud.cloudnative-pg.io`).
- `kubectl get backup -n rbr-ver-db` — show it complete; first WAL auto-creates
  the `verstappen-backups/` bucket on the local object store.

### B6. Observability (Grafana + pgaudit)
- Open `https://grafana-rbr-ver...sslip.io`, log in via Authelia OAuth.
- Show the custom CNPG metrics dashboard.
- Show the **pgaudit** dashboard — the `CREATE TABLE` from B3 appears as a DDL
  audit line (pgaudit → stdout → Loki → Grafana).
- Optional: Traefik traces (Tempo) for the psql connection path.

### B7. External connectivity (Traefik TCP)
- `psql "host=verstappen-rbr-ver-db.<ip>.sslip.io port=5432 sslmode=require ..."`
  using dynamic creds from B2.

### B9. The running app (GitOps-deployed)
- Show the `demo-app` (Litestar) pods Running in `rbr-ver`, deployed by **ArgoCD** from
  `app/helm/demo-app`. Hit its endpoint; it reads/writes the `verstappen` DB as the `app` role
  using the Vault-static-role-rotated `verstappen-app` Secret (Reloader restarts on rotation).
- Tie back to B4: rotate `app` creds → Reloader bounces the app → still healthy.

### B10. Tenant K8s access (Capsule + capsule-proxy + gangplank)
- Open `https://gangplank.<ip>.sslip.io`, log in via Authelia, download the kubeconfig.
- As **`rbr-ver-dev`**: `kubectl get pods -n rbr-ver` works; `-n rbr-ver-db` works (edit);
  another tenant's namespace is **forbidden**.
- As **`rbr-po`**: read-only `get` across all `rbr-*` namespaces; any `apply`/`delete` denied.
- As **`unrelated`**: sees nothing. Contrast with Vault DB-creds layer (independent authority).

### B11. GitOps (ArgoCD)
- Open `https://argocd.<ip>.sslip.io`, SSO via Authelia as `admin`.
- Show the `rbr-root` app-of-apps: `tenant-rbr`, `kyverno-policies`, `demo-app`, `grafana-rbr-ver`
  all `Synced/Healthy`. Make a values change in Git → watch ArgoCD re-sync.

### B12. Policy enforcement (Kyverno)
- Show the auto-generated per-driver-group RoleBindings + default-deny NetworkPolicy on `rbr-ver`.
- `kubectl run nginx --privileged ...` in `rbr-ver` → **rejected** by Kyverno (Enforce).
- A pod without resource limits → rejected. Show the PolicyReport.

### B13. SeaweedFS OIDC
- Admin UI (`https://…:23646`): anonymous blocked; `admin` logs in via Authelia → full admin.
- S3: `admin` assumes the admin role and lists all buckets; `rbr-ver-db-admin` rw on
  `verstappen-backups`; `rbr-po` read-only. Loki/Barman still use static keys (B5 backup intact).

### B14. Hardened DB config user
- Show Vault `database/config/rbr-ver-max` connects as least-priv `rbr_ver_vde_config`
  (CREATEROLE, no ownership, no superuser); its password is Vault-rotated (`rotate-root`).
- `vault read database/creds/...` still mints short-TTL roles — no superuser anywhere in the path.

### B8. Teardown (only if resetting)
- `./demo/self-service-setup.sh teardown local` — deletes the ArgoCD `rbr-root` app (cascading
  child apps), then `rbr-ver-db` + `rbr-ver`, the ClusterSecretStore, the Traefik TCP route,
  pgAdmin resources, and the `rbr` Capsule Tenant.

---

## Sequencing guidance
- If demoing both in one session: run **A** first (foundational secrets story),
  then **B** (build the DBaaS narrative on top). Don't tear down A's Vault.
- Keep two terminals: one for `*-setup.sh` commands, one live `kubectl get ...`
  watch so the audience sees reconciliation happen.
