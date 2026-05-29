# vault/config/

## Responsibility
Supplies the Vault server runtime configuration (`vault-config.hcl`) that is mounted into the Vault container at `/vault/config`. This HCL file controls persistent storage backend, TLS listener settings, clustering, and logging behavior for the standalone Vault instance running in non-dev (production) mode.

## Design Patterns
- **Single-file minimal config**: A single `vault-config.hcl` file keeps the configuration simple and auditable, matching the learning environment philosophy.
- **File-backed storage**: Uses Vault's `storage "file"` backend pointed at `/vault/data` (bind-mounted to `vault/data/` on the host). This is the simplest persistent backend, suitable for single-node non-production deployments.
- **TLS-only listener**: Port 8200 serves the Vault API with TLS using certificates issued by step-ca (stored in `vault/certs/`). The TLS cert, key, and CA chain are referenced directly in the HCL config. There is no plain-text listener — all API access requires TLS.
- **Bootstrap fallback listener**: Port 8202 is a plain-text listener (`tls_disable = 1`) intended only as a bootstrap fallback for initial setup/unseal operations. It should not be used for production traffic.
- **Clustering disabled**: `cluster_addr` is set to a loopback address (`127.0.0.1:8201`) but no HA clustering is configured — this is a standalone instance.
- **No mlock**: `disable_mlock = true` avoids requiring `CAP_IPC_LOCK` or `--cap-add=IPC_LOCK` issues in container environments, at the cost of potential memory pressure (acceptable for a playground).
- **step-ca-issued TLS**: Vault's own TLS certificate is issued by step-ca's JWK provisioner with SANs for the host's sslip.io hostname, localhost, and the host IP. This ensures all clients (in-cluster and host-side) can verify Vault's identity.

## Data & Control Flow
```
vault/config/vault-config.hcl
       │
       ▼ bind-mount
Vault container: /vault/config/
       │
       ▼ loaded at startup (vault server -config=/vault/config/vault-config.hcl)
Vault server process
       │
       ├── storage "file" ──► /vault/data/ (vault/data/ on host)
       ├── listener "tcp" port 8200 ──► TLS (vault-cert.pem + vault-key.pem + vault-ca.pem)
       ├── listener "tcp" port 8202 ──► plain-text fallback (tls_disable = 1)
       └── log settings ──► /vault/logs/vault.log
```

The config file is consumed by the Vault process on startup and is not re-read during runtime. Changes require a container restart.

## Integration Points
| Consumer | Mechanism |
|----------|-----------|
| **Vault container** (`vault-setup.sh`) | Mounted as `-v "${VAULT_CONFIG_DIR}:/vault/config"` at `docker run`; Vault started with `vault server -config=/vault/config/vault-config.hcl` |
| **vault/certs/** | TLS cert, key, and CA chain referenced by the HCL listener block |
| **vault/data/** | File storage backend writes runtime data here (excluded from codemap as runtime data) |
| **vault/logs/** | `log_file` directive writes operation logs (excluded from codemap as runtime data) |
| **K8s ESO / cert-manager** | Connect via TLS port 8200 through the K8s Service (vault.vault.svc.cluster.local:8200) with step-ca CA bundle |
| **Host** | Connects via TLS port 8200 using `vault-ca.pem` (step-ca root + intermediate chain) |

The config HCL is not directly consumed by any K8s resource — its effects are indirect via the Vault server process behavior.