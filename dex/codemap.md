# dex/

## Responsibility
Hosts the Dex OIDC identity provider configuration for the playground. Dex acts as the central authentication gateway, issuing ID tokens via the OIDC authorization code flow to downstream consumers (Vault and Grafana) so users authenticate once and access both the secrets engine and monitoring dashboards. Dex's TLS certificate is issued by Vault PKI and chains through a two-tier hierarchy (Vault intermediate → step-ca intermediate → step-ca root); the server certificate bundle includes the full chain so clients can verify without the CA bundle. This directory owns the deployment artifacts (config templates, TLS material, lifecycle scripts) needed to bootstrap and run Dex as a Docker container alongside the Kind clusters.

## Design Patterns
- **Sidecar OIDC Gateway**: Dex runs as a standalone Docker container (not inside Kind) and is reachable via an sslip.io DNS name, allowing all Kind clusters and the host to share a single OIDC authority.
- **Static OAuth2 Client Registry**: Consumers are registered as `staticClients` with pre-shared secrets — no dynamic client registration. Each client declares its allowed `redirectURIs` to harden the OAuth callback flow.
- **Static Password Database**: Authentication is backed by `enablePasswordDB: true` with bcrypt-hashed passwords defined in configuration. No external user store is required; users and their group memberships are declared in YAML.
- **Templated Configuration**: The rendered `config/dex-config.yaml` is produced from `config/dex-config.yaml.tpl` via `envsubst` at setup time, with variables sourced from `.env` files, enabling environment-specific hostnames and secrets.
- **Group-Based RBAC Bindings**: Static users carry group memberships (e.g. `rbr-db-admin`, `rbr-ver-db-admin`) that downstream consumers (Vault OIDC role mappings, Grafana org roles) translate into authorization boundaries.
- **Full-Chain TLS Serving**: The server certificate file (`tls/dex.crt`) contains the leaf cert followed by the step-ca intermediate and step-ca root CAs, so TLS clients receive the complete trust chain during the handshake without needing a separate CA bundle.

## Data & Control Flow
1. **Setup** — `scripts/dex-setup.sh` is invoked by `scripts/setup.sh`. It issues a TLS certificate for Dex via Vault PKI (role `pki_int/issue/dex-server`), writes certs into `tls/`, builds the full CA chain by appending the step-ca intermediate and root CAs to `dex.crt`, `ca.crt`, and `ca-chain.pem` (so the chain reads: leaf → Vault intermediate → step-ca intermediate → step-ca root), runs `envsubst` on the template to produce `config/dex-config.yaml`, and starts the Dex container with mounted config and TLS volumes. Later in the bootstrap, `scripts/setup.sh` adds the Vault intermediate CA to step-ca's system trust store and registers an OIDC provisioner on step-ca pointing at Dex's discovery URL.
2. **Startup** — Dex loads `config/dex-config.yaml`, initialises a SQLite3 database at `/var/dex/dex.db`, binds HTTPS on `0.0.0.0:5556`, and exposes the OIDC discovery endpoint at `/<issuer-path>/.well-known/openid-configuration`.
3. **Authentication** — A user visits Vault or Grafana, which redirects to Dex's `/authorize` endpoint. Dex presents a login form validated against `staticPasswords`, issues an authorization code, which the consumer exchanges at `/token` for an ID token (and optionally an access token). The consumer verifies the ID token using Dex's public keys at `/keys`.
4. **Teardown** — `scripts/dex-teardown.sh` stops the container and removes the rendered `config/dex-config.yaml` (the `.gitignore` prevents committed generated files).

## Integration Points
| Consumer | Mechanism | Purpose |
|---|---|---|
| **Vault** | OIDC `staticClients[0]` (`vault-client`) | Authenticates Vault UI users; redirect URIs point at Vault's OIDC callback path on ports 8200/8250 |
| **Grafana** | OIDC `staticClients[1]` (`grafana-rbr-ver`) | Authenticates Grafana users via generic OAuth; redirect URI targets `grafana-rbr-ver.*.sslip.io` |
| **Vault PKI** | TLS cert issued by `pki_int/issue/dex-server` | Provides the leaf HTTPS certificate for Dex's web listener; the Vault intermediate CA is the first link in the trust chain |
| **step-ca PKI** | Full-chain trust anchor: step-ca intermediate + root CAs are appended to `dex.crt`, `ca.crt`, and `ca-chain.pem` | step-ca's intermediate and root CAs complete the trust chain so clients can verify leaf → Vault int → step-ca int → step-ca root |
| **step-ca (OIDC provisioner)** | step-ca registers a `dex` OIDC provisioner using Dex's discovery URL | step-ca delegates authentication to Dex for certificate issuance; step-ca's trust store includes the Vault intermediate CA so it can verify Dex's TLS cert during OIDC flow |
| **Kind clusters** | Not direct consumer; Dex runs host-side | Grafana and Vault instances inside Kind clusters reach Dex via the sslip.io hostname |
| **scripts/setup.sh** | Orchestrates bootstrap | Calls `dex-setup.sh` during `setup` and `dex-teardown.sh` during `teardown` |
