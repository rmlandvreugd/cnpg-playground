# vault/cert-manager/

## Responsibility
Provides the cert-manager integration template that enables automated TLS certificate issuance across all Kubernetes clusters using Vault's PKI engine. The single file `clusterissuer.yaml.tpl` is the template for a cert-manager `ClusterIssuer` that authenticates to Vault via AppRole and maps to the intermediate PKI role `cluster-certs` for certificate signing. The issuer connects to Vault over HTTPS with a CA bundle that includes the full step-ca chain (root + intermediate), ensuring in-cluster TLS verification works correctly.

## Design Patterns
- **Template-driven resource generation**: Uses `${VAR}` placeholders (`${VAULT_PORT}`, `${VAULT_APPROLE_ROLE_ID}`, `${VAULT_CA_BUNDLE}`) resolved at deployment time via `envsubst` in `scripts/setup.sh`. This decouples configuration values from the resource definition.
- **Vault PKI as cert-manager issuer**: cert-manager acts as a client to Vault's PKI engine, requesting signed certificates via the `pki_int/sign/cluster-certs` endpoint. All TLS certificates in the playground chain through Vault's intermediate CA → step-ca's intermediate CA → step-ca's root CA.
- **AppRole authentication**: Authenticates to Vault using the `cert-manager` AppRole role. The RoleID is embedded in the ClusterIssuer spec (via `${VAULT_APPROLE_ROLE_ID}`), while the SecretID is stored in a separate K8s Secret (`vault-approle`) in the `cert-manager` namespace. This follows the principle of separating identity (RoleID, public) from credential (SecretID, sensitive).
- **Cluster-scoped issuer**: Uses `ClusterIssuer` (not namespaced `Issuer`) so that `Certificate` resources in any namespace across the cluster can reference it, enabling centralized PKI governance.
- **HTTPS with CA bundle**: Connects to Vault via `https://` (port 8200) with a `caBundle` containing the base64-encoded step-ca root + intermediate CA chain. This ensures cert-manager can verify Vault's TLS certificate (issued by step-ca's intermediate) without relying on the cluster's system trust store.
- **3-tier PKI trust chain**: Certificates issued through this ClusterIssuer chain through: leaf → Vault Intermediate CA → step-ca Intermediate CA → step-ca Root CA. The `vault-ca.pem` file (mounted as `vault-tls-ca` Secret) contains the full chain.

## Data & Control Flow
```
scripts/setup.sh (per cluster)
       │
       ├── reads vault/.approle_role_id
       ├── reads vault/certs/vault-ca.pem → base64 → VAULT_CA_BUNDLE
       ├── creates K8s Secret "vault-approle" (secretId) in cert-manager namespace
       ├── creates K8s Secret "vault-tls-ca" (ca.crt from vault/certs/vault-ca.pem)
       │
       ├── envsubst: ${VAULT_PORT} ${VAULT_APPROLE_ROLE_ID} ${VAULT_CA_BUNDLE}
       │
       ▼
vault/cert-manager/clusterissuer.yaml.tpl
       │
       ▼ kubectl apply
K8s ClusterIssuer (name: vault-pki)
       │
       ├── spec.vault.server ──► https://vault.vault.svc.cluster.local:8200
       ├── spec.vault.path  ──► pki_int/sign/cluster-certs
       ├── spec.vault.caBundle ──► base64(step-ca root + step-ca intermediate)
       │
       ├── auth.appRole.path ──► approle
       ├── auth.appRole.roleId ──► ${VAULT_APPROLE_ROLE_ID} (from vault/.approle_role_id)
       └── auth.appRole.secretRef ──► K8s Secret "vault-approle".secretId
                │
                ▼
         Vault AppRole auth at approle/
                │
                ▼
         Vault ACL policy "cert-manager"
                │
                ├── pki_int/sign/cluster-certs   (create, update)
                ├── pki_int/issue/cluster-certs   (create, update)
                ├── pki_int/sign/mtls-client      (create, update)
                ├── pki_int/issue/mtls-client     (create, update)
                ├── pki_int/cert/ca              (read)
                ├── pki/cert/ca                  (read)
                └── pki_int/certs                (list)
```

## Integration Points
| Consumer | Mechanism |
|----------|-----------|
| **Vault AppRole endpoint** | Authenticates via `auth/approle/login` using RoleID (inline) + SecretID (from K8s Secret) |
| **Vault PKI intermediate engine** | Signs CSRs via `pki_int/sign/cluster-certs`; issues certificates via `pki_int/issue/cluster-certs` |
| **K8s Secret `vault-approle`** | Created by `scripts/setup.sh` in `cert-manager` namespace; contains `secretId` |
| **K8s Secret `vault-tls-ca`** | Created by `scripts/setup.sh` in `cert-manager` namespace; contains step-ca root + intermediate CA chain for TLS verification |
| **Certificate resources** | Any `Certificate` resource in any namespace referencing issuer `vault-pki` (kind: ClusterIssuer) |
| **Traefik dashboard** | Uses certificates issued through this ClusterIssuer (e.g., `traefik-dashboard-cert`) |
| **Dex** | Uses certificates issued via the `dex-server` role (separate PKI role, same issuer pattern) |
| **trust-manager Bundle** | Distributes step-ca root + intermediate CA to all namespaces via `step-ca-bundle` ConfigMap |

**Consumed by**: `scripts/setup.sh` (per-cluster loop), `scripts/vault-pki-setup.sh` (creates the AppRole + policy this issuer depends on)