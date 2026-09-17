# Plan: Klio tiered backup for the self-service and eso-vault demos

Status: plan — nothing implemented yet. Tracked as a beads epic, one child per
spike (see [Spikes](#spikes-beads-children)).

## Goals

1. Install the **Klio operator** (`klio.cnpg.io`) next to CNPG and the
   barman-cloud plugin in `cnpg-system`.
2. Every demo cluster (`verstappen` in `rbr-ver-db`, `pg-local` in
   `demo-local-db`) runs **both** plugins by default:
   barman-cloud (WAL archiver + scheduled base backups to SeaweedFS) and Klio
   (WAL streaming + scheduled base backups, tier 1 → tier 2).
3. **Tiered storage**: tier 1 = Klio Server PVCs, tier 2 = SeaweedFS S3.
4. **Shared N:1** architecture: one Klio Server in its own namespace serves all
   clusters of a Capsule tenant (across its driver-groups).
5. Keep the tenant → driver-group model (`<tenant>`, `<tenant>-<dg>`,
   `<tenant>-<dg>-db`) intact; Klio adds `<tenant>-klio`.
6. All certs from **Vault PKI**, all secrets via **Vault KV + ESO** — no
   `kubectl create secret` with literal credentials, no upstream demo keys.

## Decisions

| Topic | Decision | Consequence |
|---|---|---|
| Klio Server scope | **One per Capsule tenant**: `rbr-klio` | N:1 inside a tenant; no shared encryption key or WAL-by-name exposure across tenants. New tenant ⇒ new server |
| Schedules | **Both active**, staggered | barman stays `isWALArchiver`; Klio streams WAL via slot `klio`. Two ScheduledBackups per cluster |
| mTLS certs | **Dedicated Vault PKI per Klio server + ESO** | Server cert → PushSecret → Vault KV → ExternalSecret (`tls.crt` only) into each cluster namespace |
| eso-vault demo | **Own server** `demo-local-klio` + new barman ObjectStore | eso-vault stays runnable without self-service; `demo-local-db` stays non-tenant |
| Tier 2 target | **Bucket per server**: `klio-rbr`, `klio-local` | Scoped SeaweedFS identity per bucket |
| Tier 1 storage | local-path PVCs (data, cache, queue) | Demo only; docs advise dedicated nodes/storage in prod |
| Encryption key | age key generated at setup, stored in Vault KV, delivered by ESO | Key loss = tier 1/2 data loss; Vault is the source of truth |
| Versions | Klio **v0.0.20** (chart `oci://ghcr.io/cloudnative-pg/klio-operator-chart`) | Compat with local CNPG chart 0.28.0 / barman chart 0.6.0 checked in Spike 1; bump CNPG to 1.30 if needed |

## Research findings

Sources: upstream cnpg-playground (`demo/setup.sh`, `demo/funcs_requirements.sh`,
`scripts/common.sh`, `demo/templates/klio/*`), cloudnative-pg.io/klio docs
(architectures, installation, tiers), klio source (`lifecycle.go`,
`klioconfig/config.go`, `grpcclient/connection.go`, `kopia.go`, `walserver.go`,
`server_reconciler.go`).

### Klio

| Topic | Finding |
|---|---|
| License | Apache-2.0, public images on ghcr.io, no pull secret. Status: experimental. Requires PG ≥ 15 |
| Install | Helm chart into the **CNPG operator namespace** (`cnpg-system`). Needs cert-manager + `age` CLI |
| Plugin certs | Chart values `certmanager.createPluginServerCertificate` / `createPluginClientCertificate` (secrets `klio-plugin-server-tls` / `klio-plugin-client-tls`). Set to `false` and issue from `vault-pki`, same as barman (`scripts/common.sh:495-509`) |
| CRDs | `Server` and `PluginConfiguration`, `klio.cnpg.io/v1alpha1` |
| Server | StatefulSet + Service. Ports 51515 (base backup), 52000 (WAL); +51516/52001 when tier 2 set. Fields: `tlsSecretName`, `caSecretName` (client CA), `tier1{cache,data,encryptionKeyFile,identityFile}`, `queue.pvcTemplate` (NATS JetStream, required with tier 1), `tier2{cache,s3{bucketName,endpoint,region,prefix,accessKeyId,secretAccessKey,customCaBundle}}`, `mode` (standard / read-only). All referenced Secrets live in the Server namespace |
| PluginConfiguration | Must live in the **Cluster namespace** and exist **before** the Cluster. Fields: `serverAddress`, `clientSecretName`, `serverSecretName`, `clusterName`, per-tier `retention`, `tier2.enableBackup/enableRecovery`, `walPrefetch` |
| Tier 1 | Server PVCs: continuous WAL + base backup catalog (Kopia, dedup, age-encrypted); retention enforced here |
| Tier 2 | S3 only. Async copy from tier 1; snapshots pinned `klio.io/tier2` until copied. Restore falls back to tier 2 only with `enableRecovery: true` |
| WAL path | Sidecar opens physical slot `klio` over local peer replication. Needs `pg_hba`: `local replication all peer map=local`. Do **not** set `isWALArchiver` |
| Direction | Cluster ns → Klio ns only; the server never connects to PG |
| Client auth | Server requires client cert signed by `caSecretName`. CN must be `klio@<clusterName>`, but the check is **client-side**; WAL gRPC takes `clusterName` from the request (UNVERIFIED whether an interceptor binds it to the CN) |
| Shared key | All clusters on one Server share one encryption key; docs recommend a Server per tenant |
| clusterName | Unique per Server, not reusable after deletion |
| Server cert in client ns | `serverSecretName` is mounted in the PG pod ⇒ Secret must exist in the **Cluster namespace**. Kopia client **pins the SHA-256 of the leaf** `tls.crt` ⇒ must be the leaf, not a CA. Renewal ⇒ re-sync + probably sidecar restart (UNVERIFIED) |
| Disable | Removing Klio leaves slot `klio` behind ⇒ WAL accumulates; drop it manually |

### Klio + barman-cloud on one Cluster

- Upstream playground default with `KLIO=true`: both plugins. barman
  `isWALArchiver: true`, Klio listed without it.
- Base backups via separate ScheduledBackups
  (`pluginConfiguration.name: barman-cloud.cloudnative-pg.io` vs `klio.cnpg.io`).
  Upstream suspends Klio's; this plan keeps **both active**.
- Restore: one source per bootstrap; Klio `externalClusters` entry uses
  `plugin.name: klio.cnpg.io` + `parameters.pluginConfigurationRef`.
- Adding Klio to an existing cluster needs a restart.

### Current repo state

| Area | Location |
|---|---|
| Operator install | `scripts/setup.sh:771-772` → `install_cnpg_operator` / `install_barman_plugin` (`scripts/common.sh:467-510`); versions `scripts/common.sh:221-222` |
| Barman plugin certs | `demo/yaml/barman-cloud/certificate-{server,client}.yaml` (ClusterIssuer `vault-pki`) |
| Tenant | `manifests/capsule-tenant-rbr.yaml` — owners `oidc:capsule-admin`, `oidc:rbr-db-admin`; ArgoCD app `tenant-rbr` |
| Tenant namespaces | `rbr-ver`, `rbr-ver-db` created by impersonating the owner, labels `capsule.clastix.io/tenant=rbr`, `cnpg.io/driver-group=ver` (`demo/self-service-setup.sh:247-278`) |
| RoleBindings | Kyverno `manifests/kyverno/generate-tenant-rolebindings.yaml` |
| ESO | ClusterSecretStores `vault-approle-rbr` (KV `cnpg`) and `vault-approle-rbr-db` (database engine), **no namespace conditions** (`demo/self-service-setup.sh:147-231`) |
| Self-service backups | SeaweedFS Service+Endpoints + `seaweedfs-barman` creds in `rbr-ver-db` (`demo/self-service-setup.sh:290-327`); ObjectStore `demo/yaml/self-service/rbr-ver-db/objectstore-rbr-ver.yaml`; Cluster plugins `cluster-verstappen.yaml.tpl:83-88`; ScheduledBackup `:129`; `backup` subcommand `demo/self-service-setup.sh:796-813`; teardown `:839-862` |
| SeaweedFS | identities + bucket creation `scripts/setup.sh:427-489`; server cert SANs `seaweedfs` + IP |
| eso-vault | `demo-local-db`, cluster `pg-local` **without any backup plugin** (`demo/yaml/local/pg-local-eso.yaml.tpl`, `pg_hba` `:65`, certs `:48`); cert issuance `demo/eso-vault.sh:163-177`; Cluster apply `:210-221` |
| Trust bundles | `step-ca-external-bundle`, `vault-pki-bundle` (trust-manager, all namespaces) |
| Vault PKI | `pki_int/roles/cluster-certs` has `allow_any_name=true` (`scripts/vault-pki-setup.sh:109-112`) — **not** usable for Klio client certs |
| Policies | default NetworkPolicy ingress-only on tenant ns (Calico); image policy allows `ghcr.io/*`; PSS exclude list `kyverno/policies-values.yaml:23-55`; `require-resources-probes` Audit only |

## Architecture

```
cnpg-system:  cnpg-operator · barman-cloud plugin · klio operator (plugin)

tenant rbr (Capsule)
 ├─ rbr-klio             Klio Server "klio"  (tier1 PVCs + NATS queue)
 │    ├─ klio-server-tls        Certificate  (Issuer klio-rbr → Vault pki_klio_rbr)
 │    ├─ klio-client-ca         CA of pki_klio_rbr (trust for client certs)
 │    ├─ klio-encryption        ExternalSecret ← Vault KV cnpg/klio/rbr/encryption
 │    ├─ klio-s3                ExternalSecret ← Vault KV cnpg/klio/rbr/s3
 │    ├─ PushSecret             klio-server-tls tls.crt → Vault KV cnpg/klio/rbr/server-cert
 │    └─ Service seaweedfs      → SeaweedFS host container (tier 2: bucket klio-rbr)
 ├─ rbr-ver-db           Cluster verstappen
 │    ├─ plugins: barman-cloud (isWALArchiver) + klio.cnpg.io
 │    ├─ PluginConfiguration klio-verstappen → klio.rbr-klio.svc:51515
 │    ├─ klio-client-verstappen ExternalSecret ← Vault KV cnpg/klio/rbr/clients/verstappen
 │    ├─ klio-server-cert       ExternalSecret ← Vault KV cnpg/klio/rbr/server-cert (tls.crt only)
 │    └─ ScheduledBackups: barman (e.g. 02:00) · klio (e.g. 03:00)
 └─ rbr-<dg>-db …        more clusters → same server (N:1)

demo-local (eso-vault, non-tenant)
 ├─ demo-local-klio      Klio Server (pki_klio_local, bucket klio-local)
 └─ demo-local-db        Cluster pg-local: barman ObjectStore (bucket pg-local-backups) + klio
```

### Client cert issuance (per cluster)

Client certs are issued in the **Klio namespace** (the only place with the
tenant's Klio Issuer), then synced to the cluster namespace via Vault KV, so
tenant cluster namespaces never hold an Issuer that can mint `klio@*` certs:

1. `Certificate klio-client-<cluster>` in `rbr-klio`, CN `klio@<cluster>`,
   Issuer `klio-rbr`.
2. `PushSecret` → `cnpg/klio/rbr/clients/<cluster>` (`tls.crt`, `tls.key`, `ca.crt`).
3. `ExternalSecret` in `rbr-<dg>-db` → Secret `klio-client-<cluster>`.

Per-tenant CA (`pki_klio_rbr`) means a cert from another tenant is rejected by
this server even if its CN collides.

### ESO stores

New `ClusterSecretStore vault-klio-rbr` (KV `cnpg`, path scope `klio/rbr/*`)
with `spec.conditions[].namespaceSelector` =
`capsule.clastix.io/tenant=rbr`, backed by a new AppRole `eso-klio-rbr`
(read/write on `cnpg/data/klio/rbr/*` — write is needed for PushSecret).
eso-vault gets `vault-klio-local` limited to `demo-local-klio` / `demo-local-db`.

### Retention (demo values)

| Tier | Retention |
|---|---|
| Klio tier 1 | `keepLatest: 5`, `keepDaily: 7` |
| Klio tier 2 | `keepDaily: 7`, `keepWeekly: 4`, `keepMonthly: 6` |
| barman ObjectStore | `retentionPolicy: 30d` |

## Spikes (beads children)

1. **Klio operator install + version compat** —
   `install_klio_operator` in `scripts/common.sh` (`KLIO_VERSION=0.0.20`),
   called after `install_barman_plugin` (`scripts/setup.sh:772`). Plugin
   server/client certs from `vault-pki` (new `demo/yaml/klio/certificate-{server,client}.yaml`),
   `prometheus.enable=true`. Verify against CNPG chart 0.28.0 / barman 0.6.0;
   bump to CNPG 1.30 + barman v0.14 if it fails.
2. **Vault + SeaweedFS foundations** — `pki_klio_<tenant>` intermediate
   (signed by existing root, role `client` with CN `klio@*`, role `server` for
   `klio.<ns>.svc*`), AppRole + policy `eso-klio-<tenant>`, KV seeds (age key
   generated with `age-keygen`, S3 creds). SeaweedFS identity + bucket
   `klio-<tenant>` in `scripts/setup.sh:427-489`. Verify Vault accepts
   non-hostname CN `klio@verstappen` (`enforce_hostnames=false`,
   `allow_glob_domains`, or `cn_validations=disabled`) — UNVERIFIED.
3. **Tenant Klio Server (`rbr-klio`)** — Capsule namespace created via
   owner impersonation, labels like `rbr-ver-db`; namespaced cert-manager
   Issuer (Vault, `pki_klio_rbr`); ClusterSecretStore `vault-klio-rbr` with
   namespace conditions; ExternalSecrets (age key, S3); Server CR (tier1 +
   queue + tier2 `klio-rbr`, `customCaBundle` from `step-ca-external-bundle`);
   PushSecret for server `tls.crt`; SeaweedFS Service+Endpoints. Check PSS /
   Kyverno admission for the Server pods and Capsule quota/storage-class.
4. **Wire verstappen (self-service)** — client Certificate + PushSecret in
   `rbr-klio`; ExternalSecrets in `rbr-ver-db`; PluginConfiguration applied
   before the Cluster; `cluster-verstappen.yaml.tpl` adds `klio.cnpg.io`
   plugin + `pg_hba local replication all peer map=local`; Klio
   ScheduledBackup (staggered vs barman); `backup [barman|klio]` subcommand;
   teardown deletes PluginConfiguration/Klio backups, Server, PVCs, KV paths,
   and drops slot `klio` if the cluster survives.
5. **eso-vault: barman + own Klio server** — ObjectStore + bucket
   `pg-local-backups`, SeaweedFS identity, Vault KV/ESO creds; `demo-local-klio`
   namespace with Server (bucket `klio-local`, `pki_klio_local`); wire `pg-local`
   same as spike 4; add `backup` subcommand and teardown to `demo/eso-vault.sh`.
6. **Validation + risk checks** — restore from tier 1, and from tier 2 with
   tier 1 wiped (`enableRecovery: true`); SeaweedFS ↔ Kopia compatibility;
   server-cert renewal (fingerprint pinning → restart needed?); whether a
   Secret with only `tls.crt` suffices; confirm cross-cluster WAL access by
   name within a tenant; NetworkPolicy allows `rbr-*-db` → `rbr-klio`
   51515/52000(+51516/52001) and blocks other tenants.
7. **Monitoring + docs** — ServiceMonitors for Klio operator and Server into
   `monitoring/platform`, optional Grafana dashboard; update
   `docs/self-service-demo.md`, `docs/eso-vault-demo.md`, `demo/README.md`
   with tier diagram, `backup`/restore walkthrough and the security caveats.

Dependencies: 1 → 2 → 3 → 4; 2 → 5; 4, 5 → 6 → 7.

## Risks / open items

- Klio is **experimental** (v0.0.x); CRD fields may change between releases.
- Server-side authorization of `clusterName` vs cert CN is UNVERIFIED — within
  one tenant any cluster could possibly read another's WAL. Accepted: same
  tenant, same trust boundary.
- Leaf-cert pinning makes server-cert rotation disruptive; use a long duration
  (e.g. 1 year) for the demo and document the rotation procedure.
- Kopia on SeaweedFS is untested upstream (upstream uses RustFS).
- Disabling Klio on a live cluster leaves slot `klio` → WAL bloat.
