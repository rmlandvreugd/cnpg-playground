# vault/

## Responsibility
Central secrets management layer for the CloudNativePG Playground. Provides a standalone HashiCorp Vault instance (Docker container in **non-dev production mode**) that serves as the PKI authority, secrets store, and authentication broker for all Kubernetes clusters in the playground.

Key responsibilities:
- **Secrets storage**: KV v2 engine at `cnpg/` for CloudNativePG database credentials consumed via External Secrets Operator (ESO)
- **PKI hierarchy**: 3-tier hierarchy — step-ca Root CA → step-ca Intermediate CA → Vault Intermediate CA → leaf certificates for cluster workloads (PostgreSQL instances, Traefik, Dex) and cluster-internal mTLS
- **Authentication broker**: AppRole auth for machine-to-machine (ESO, cert-manager), OIDC auth via Dex for human operators, userpass auth for fallback admin access
- **Audit trail**: File-based audit logging capturing all API operations

## Design Patterns
- **Standalone Vault (non-dev mode)**: Runs as a single Docker container with `vault server -config=/vault/config/vault-config.hcl`. Uses file storage backend (`vault/data/`), requires initialization with 1 unseal key and explicit unseal. No HA clustering — appropriate for a learning environment.
- **3-tier PKI hierarchy**: step-ca Root CA → step-ca Intermediate CA (both in the step-ca container) → **Vault Intermediate CA** (signed by step-ca's intermediate via openssl) → leaf certificates. Vault no longer generates its own root CA. The `pki/` engine imports the step-ca root certificate for CA chain serving. The `pki_int/` engine generates a CSR that is signed on the host by step-ca's intermediate CA key (openssl is used instead of `step certificate sign` because step CLI requires a TTY). This follows production best practices: the root CA is offline-capable in step-ca, and Vault's intermediate compromise is containable.
- **3 issuance roles** (`dex-server`, `cluster-certs`, `mtls-client`) with distinct `allowed_domains` constraints enforce which workloads can request certificates for which DNS names. The `mtls-client` role defines `client_flag=true server_flag=false` and a shorter max TTL (168h). All roles set `not_before_duration=0s` to prevent "notBefore before signer's notBefore" errors.
- **Per-region AppRole separation**: Each Kubernetes region gets its own AppRole role (`eso-<region>`) scoped to the `eso-cnpg` policy, ensuring least-privilege access to the `cnpg/` KV store.
- **Machine identity via SecretRef**: AppRole RoleID/SecretID pairs are stored as Kubernetes Secrets (`vault-approle`, `vault-approle-creds`) in each cluster's target namespace rather than embedded in ClusterIssuer/ClusterSecretStore templates.
- **TLS-only primary API**: Vault API is served over TLS (port 8200) using a certificate issued by step-ca (stored in `vault/certs/vault-cert.pem`, `vault-key.pem`). A plain-text listener on port 8202 exists only as a bootstrap fallback. In-cluster consumers verify TLS using the step-ca root chain (`vault-ca.pem`).
- **Vault's own TLS cert issued by step-ca**: During `vault-setup.sh`, the script requests a server certificate from step-ca with SANs for the sslip.io hostname (`vault.<host-ip-dashed>.sslip.io`), localhost, and the bridge-network IP. The full chain (step-ca root + intermediate) is concatenated into `vault-ca.pem` for client verification.

## Data & Control Flow
```
[Operator/automation scripts]
       |
       v
[Vault Container] ─── file storage ──► vault/data/
  port 8200 (TLS, step-ca cert)         vault/logs/
  port 8202 (plain, bootstrap)          vault/pki/
  auth methods:                         vault/certs/
    ├─ userpass (admin)                 vault/config/vault-config.hcl
    ├─ approle (ESO, cert-manager)      vault/.root_token
    └─ oidc   (Dex, human users)        vault/.unseal_key
                                         vault/.approle_role_id
                                         vault/.approle_secret_id
       |
       ├──► cnpg/ (KV v2) ──► ESO ClusterSecretStore ──► ExternalSecret ──► K8s Secret
       │       path: cnpg/data/*    (read)
       │       path: cnpg/metadata/* (list)
       │
       ├──► pki_int/ (Vault Intermediate CA, signed by step-ca) ──► cert-manager ClusterIssuer
       │       sign/cluster-certs    (POST)
       │       issue/cluster-certs   (POST)
       │       sign/mtls-client      (POST)
       │       issue/mtls-client     (POST)
       │       cert/ca               (GET)
       │
       ├──► pki/ (serves step-ca root chain) ──► CA chain for clients
       │       cert/ca               (GET)
       │       config/urls           (AIA/CRL distribution endpoints)
       │
       ├──► pki_int/ (dex-server role) ──► Dex TLS certificate
       │
       └──► audit logging ──► vault/logs/audit.log
```

**Bootstrap order** (from `scripts/setup.sh`):
1. `step-ca-setup.sh` — starts step-ca container, generates Root CA + Intermediate CA
2. `vault-setup.sh` — requests Vault TLS cert from step-ca, starts Vault container with HCL config, initializes, unseals, enables userpass auth, creates admin user
3. `vault-pki-setup.sh` — enables `pki/` engine (imports step-ca root), enables `pki_int/` engine, generates CSR, signs with step-ca intermediate via openssl, sets signed intermediate, creates issuance roles, creates cert-manager AppRole
4. `vault-eso-setup.sh` — enables `cnpg/` KV v2 engine, writes `eso-cnpg` read-only policy
5. Per cluster: `eso-setup.sh` — creates per-region AppRole, installs ESO Helm chart, deploys ClusterSecretStore
6. `vault-oidc-setup.sh` — enables OIDC auth method, configures Dex as provider, creates OIDC role

**Intermediate renewal** (`vault-renew-intermediate.sh`):
1. Generates a new CSR from Vault's existing intermediate key (`pki_int/intermediate/generate/internal`)
2. Signs the CSR on the host with step-ca's intermediate CA key using openssl
3. Backs up the old intermediate certificate to `vault/pki/backups/`
4. Sets the new signed certificate via `pki_int/intermediate/set-signed`
5. Saves the new chain to `vault/pki/intermediate.crt`

## Integration Points
| Consumer | Mechanism | Vault Path/Engine | Credentials |
|----------|-----------|-------------------|-------------|
| **cert-manager** (ClusterIssuer) | AppRole auth → PKI sign | `pki_int/sign/cluster-certs`, `pki_int/sign/mtls-client` | `vault-approle` K8s Secret (secretId); RoleID from `vault/.approle_role_id` |
| **ESO** (ClusterSecretStore) | AppRole auth → KV read | `cnpg/data/*`, `cnpg/metadata/*` | `vault-approle-creds` K8s Secret (roleId, secretId); per-region AppRole |
| **Dex** (OIDC) | PKI cert | `pki_int/issue/dex-server` | step-ca → Vault Intermediate CA chain |
| **Traefik** (K8s Service) | Network (TCP) | N/A — Service/Endpoints routing to Vault container IP | step-ca chain for TLS verification |
| **Human operators** | OIDC login via Dex | `auth/oidc` → `oidc-policy` (KV read) | Dex credentials (user@example.com) |
| **Admin** | userpass login | `auth/userpass` | `vault-admin` password |

**Consumed by scripts**: `scripts/vault-setup.sh`, `scripts/vault-pki-setup.sh`, `scripts/vault-eso-setup.sh`, `scripts/vault-oidc-setup.sh`, `scripts/eso-setup.sh`, `scripts/setup.sh`, `scripts/vault-renew-intermediate.sh`, `scripts/vault-teardown.sh`
