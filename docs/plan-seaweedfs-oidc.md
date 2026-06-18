# SeaweedFS OIDC Plan (local region)

Status: plan 2026-06-18. Identity per `plan-tenant-personas-authelia.md`.

## Goal

Bring SeaweedFS under the Authelia identity umbrella **for humans**, while keeping machine
identities (Loki, Barman/CNPG backups) on static S3 keys — interactive OIDC does not fit
service-to-service. Two surfaces: the **Admin UI** and the **S3 API**.

Current state: host containers (`seaweedfs`, `seaweedfs-admin`, webdav, worker), single static S3
identity `loki`/`lokiS3secret` with Admin on the `loki` bucket; no auth on admin UI. Config in
`seaweedfs/config/{identities.json,security.toml}`, run flags in `scripts/setup.sh`.

`admin` super-user gets full access via `seaweedfs-admin` group.

## 1. Admin UI — authentication + OIDC

Per the SeaweedFS wiki (Admin-UI, Admin-UI-OIDC):
- Enable admin UI authentication (no more anonymous access).
- Configure OIDC against Authelia: issuer `https://authelia.<IP_DASHED>.sslip.io`, client
  `seaweedfs-admin`, scopes `openid email profile groups`, redirect to the admin UI callback.
- Map `groups` → admin role: `seaweedfs-admin` (and `admin`) → full admin; deny others.
- Admin UI served over TLS (existing step-ca cert).

New Authelia OIDC client `seaweedfs-admin` (redirect URI = admin UI `…/callback`).

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

- Admin UI: anonymous access blocked; `admin` logs in via Authelia and sees full admin; a non-admin
  user is denied.
- S3 OIDC: `admin` assumes `S3AdminRole` and lists all buckets; `rbr-ver-db-admin` can rw the
  `verstappen-backups` bucket; `rbr-po` read-only; `unrelated` denied.
- Machine path intact: Loki still writes logs; `self-service-setup.sh backup local` still creates a
  Barman backup to S3 with the split `barman` key.

## Sources

- OIDC Integration: https://github.com/seaweedfs/seaweedfs/wiki/OIDC-Integration
- Admin UI: https://github.com/seaweedfs/seaweedfs/wiki/Admin-UI
- Admin UI OIDC: https://github.com/seaweedfs/seaweedfs/wiki/Admin-UI-OIDC
- S3 IAM / identities: https://github.com/seaweedfs/seaweedfs/wiki/Amazon-S3-API
