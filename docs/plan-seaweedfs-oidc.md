# SeaweedFS OIDC Plan (local region)

Status: in progress 2026-06-25. Identity per `plan-tenant-personas-authelia.md`.

## Validated decisions (2026-06-25, against SeaweedFS wiki + deepwiki source)

- **Admin UI OIDC — NOT available in OSS.** The OSS `weed admin` binary has no OIDC code
  path at all (`auth_middleware.go` only checks `-adminUser`/`-adminPassword`); OIDC admin
  login is not even Enterprise-gated, it simply does not exist in the OSS image. Section 1
  is therefore handled at the **edge**: front the admin UI with Traefik + Authelia
  forward-auth + the local password backstop. As of 2026-06-29 this is folded into the
  broader external edge-Traefik effort — see `docs/plan-external-edge-traefik.md`;
  `cnpg-playground-yt4` becomes a child of that epic. The scaffolded `seaweedfs-admin`
  Authelia OIDC client is already removed (only a NOTE remains in
  `authelia/config/configuration.yaml`).
- **S3 OIDC/STS — open source.** `-s3.iam.config` (sts/providers/policies/roles) works on
  the OSS image, and `-s3.config` (static keys) + `-s3.iam.config` run **together**. Static
  machine identities stay in `identities.json`; humans assume roles via STS.
- **Barman migration — rbr-ver-db tenant now, pg-local deferred.** Barman backups targeted
  RustFS, not SeaweedFS (plan's "both ride loki identity" was inaccurate). The rbr-ver-db
  tenant (`verstappen-backups`) is migrated to SeaweedFS with the `barman` identity; the
  generic pg-local (`default` ns, RustFS) migration is left as a follow-up to keep the
  multi-region RustFS path stable.
- **Static identities split**: `admin` (full Admin, bootstrap buckets only), `loki`
  (RW on `loki` only — blanket Admin dropped; bucket-init uses `admin` creds), `barman`
  (RW/List on `backups` + `verstappen-backups`).
- **Group→role mapping** (iam.json `roleMapping`, no `defaultRole` = deny others):
  `admin`→S3AdminRole (s3:*), `rbr-ver-db-admin`→S3BackupRWRole, `rbr-po`→S3BackupRORole
  (both scoped to `verstappen-backups`). Authelia issuer
  `https://authelia.<TRAEFIK_IP_DASHED>.sslip.io`, jwksUri `…/jwks.json`. Provider
  `tlsCaCert` = vault pki_int + step-ca chain bundle (Authelia's Traefik cert is vault-pki).

## Goal

Bring SeaweedFS under the Authelia identity umbrella **for humans**, while keeping machine
identities (Loki, Barman/CNPG backups) on static S3 keys — interactive OIDC does not fit
service-to-service. Two surfaces: the **Admin UI** and the **S3 API**.

Current state: host containers (`seaweedfs`, `seaweedfs-admin`, webdav, worker), single static S3
identity `loki`/`lokiS3secret` with Admin on the `loki` bucket; no auth on admin UI. Config in
`seaweedfs/config/{identities.json,security.toml}`, run flags in `scripts/setup.sh`.

`admin` super-user gets full access via `seaweedfs-admin` group.

## 1. Admin UI — authentication (edge forward-auth, not in-app OIDC)

OSS `weed admin` has no OIDC code path, so SSO is enforced at the edge rather than in the
admin binary. The admin UI (host container, HTTPS on :23646, local
`-adminUser`/`-adminPassword`) is fronted by the external edge Traefik with an Authelia
**forward-auth** middleware:
- Edge router `seaweedfs-admin.<EDGE_IP_DASHED>.sslip.io` → admin container `:23646`
  (`scheme: https`, `insecureSkipVerify`), with the forward-auth middleware attached.
- Authelia `access_control` rule: `policy: one_factor`, `subject:
  ["group:seaweedfs-admin","group:admin"]` (deny others). Browser is redirected to
  Authelia, then proxied to the UI on success.
- `-adminUser`/`-adminPassword` stays as a behind-proxy backstop.

This work is part of `docs/plan-external-edge-traefik.md` (epic), tracked as
`cnpg-playground-yt4`. The previously scaffolded Authelia `seaweedfs-admin` OIDC client is
removed (no in-app OIDC).

## 2. S3 API — OIDC via IAM/STS

Per the SeaweedFS OIDC-Integration wiki, the S3 gateway uses an **IAM config** (`-iam.config`
JSON) with an STS OIDC provider; humans call `AssumeRoleWithWebIdentity` with an Authelia JWT and
receive temporary S3 credentials scoped by a **role + trust policy** keyed on the `groups` claim.
**Static identities coexist** in the same config — so Loki/Barman keep working.

`seaweedfs/config/iam.json` (shape):

```jsonc
{
  "sts": {
    "providers": [{
      "name": "authelia",
      "issuer": "https://authelia.${IP_DASHED}.sslip.io",
      "clientId": "seaweedfs-s3",
      "jwksUri": "https://authelia.${IP_DASHED}.sslip.io/jwks.json",
      "claimMappings": { "groups": "groups", "email": "email" }
    }]
  },
  "roles": [
    { "name": "S3AdminRole",  "trustPolicy": "groups contains 'seaweedfs-admin' or 'admin'",
      "policy": "Admin (all buckets)" },
    { "name": "rbr-ver-rw",   "trustPolicy": "groups contains 'rbr-ver-db-admin'",
      "policy": "Read/Write/List on bucket verstappen-backups" },
    { "name": "rbr-po-ro",    "trustPolicy": "groups contains 'rbr-po'",
      "policy": "Read/List on all rbr-* backup buckets" }
  ]
}
```

(Exact JSON keys/policy syntax to be confirmed against the wiki during implementation — see open
items.) New Authelia OIDC client `seaweedfs-s3`.

## 3. Static machine identities (keep, but split)

Replace the single shared `loki` key with **per-identity** keys in `identities.json`:

| Identity | Access key | Scope |
|---|---|---|
| `loki`   | `loki` / dedicated secret   | Admin/RW on bucket `loki` |
| `barman` | `barman` / dedicated secret | RW/List on backup buckets (`*-backups`) |
| `mimir`/`tempo` (RustFS today) | unchanged | — |

Add a **per-tenant backup bucket + identity** as driver groups grow (e.g. `verstappen-backups` used
by Barman for `rbr-ver`). Update Loki config and the CNPG `ObjectStore`/Barman secrets to the split
keys (currently both ride the `loki` identity).

## 4. Wire-up

- `scripts/setup.sh` SeaweedFS block: add admin-UI auth+OIDC flags/config; add `-s3.iam.config`
  (or equivalent) pointing at `iam.json`; mount the new config + Authelia CA into the container.
- `scripts/common.sh`: client secrets for `seaweedfs-admin`/`seaweedfs-s3`; split machine keys.
- `authelia/config/configuration.yaml.tpl`: the two new OIDC clients.

## Open items (validate against the linked wiki during implementation)

- Exact Admin-UI OIDC config keys (deepwiki lacked the Admin-UI pages; follow the user-linked wiki).
- Exact `-iam.config` schema: STS provider fields, role `trustPolicy` / `AssumeRoleWithWebIdentity`
  claim matching syntax, and policy document format.
- Whether the SeaweedFS version in `SEAWEEDFS_IMAGE` supports the IAM/STS OIDC path (pin a version
  that does).

## Verification

Planned:
- Admin UI: anonymous access blocked; `admin` logs in via Authelia and sees full admin; a non-admin
  user is denied.
- S3 OIDC: `admin` assumes `S3AdminRole` and lists all buckets; `rbr-ver-db-admin` can rw the
  `verstappen-backups` bucket; `rbr-po` read-only; `unrelated` denied.
- Machine path intact: Loki still writes logs; `self-service-setup.sh backup local` still creates a
  Barman backup to S3 with the split `barman` key.

Verified live (2026-06-26, rebuilt local cluster):
- **Static identity split** — `barman` WRITE `verstappen-backups` OK, READ `loki` DENIED
  (least-privilege confirmed). `loki` lost blanket Admin; bucket-init now uses the `admin` identity.
- **Backup buckets pre-created** in setup. Fixed `minio/mc` ENTRYPOINT bug: image is
  `ENTRYPOINT [mc]`, so the bucket-create step must use `--entrypoint sh … -c "…"` (not `sh -c`).
  Without pre-created buckets, the first barman write triggers SeaweedFS auto-create, which needs
  the global `Admin` action — correctly denied to `barman`, so backups fail until buckets exist.
- **Barman → SeaweedFS migration works end-to-end** — WAL archiving (`verstappen/wals/`) and an
  on-demand base backup both succeed (`verstappen/base/<ts>/data.tar` + `backup.info`); Backup CR
  reaches `completed`.
- **iam.json OIDC/STS** renders correctly (issuer, `enabled:true`, `clientId=seaweedfs-s3`,
  `jwksUri=…/jwks.json`, 3 roles, group→role map, 32-byte signingKey). Gateway boots with
  "Starting S3 API Server with advanced IAM integration" + "Registered IAM gRPC service", no
  provider errors. `-s3.config` + `-s3.iam.config` + all three mounts present.
- **Not yet exercised**: human `AssumeRoleWithWebIdentity` with a real Authelia JWT (provider
  config validated structurally only). Admin UI auth deferred → `cnpg-playground-yt4`.

## Sources

- OIDC Integration: https://github.com/seaweedfs/seaweedfs/wiki/OIDC-Integration
- Admin UI: https://github.com/seaweedfs/seaweedfs/wiki/Admin-UI
- Admin UI OIDC: https://github.com/seaweedfs/seaweedfs/wiki/Admin-UI-OIDC
- S3 IAM / identities: https://github.com/seaweedfs/seaweedfs/wiki/Amazon-S3-API
