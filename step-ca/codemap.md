# step-ca — Root Certificate Authority

## Responsibility

The `step-ca/` directory provides the **Root CA** for the entire playground PKI hierarchy. It runs as a Docker container (`smallstep/step-ca:latest`) and issues the **intermediate CA certificate** that Vault's PKI engine uses to sign leaf certificates. Every TLS certificate in the playground — whether for Vault itself, Dex, Traefik ingress, or PostgreSQL — chains back to this Root CA.

**PKI Hierarchy:**

```
step-ca Root CA                         (self-signed, lifetime ~10+ yr)
  └─ step-ca Intermediate CA            (signed by step-ca root, 5-year validity)
       └─ Vault Intermediate CA         (signed by step-ca intermediate, CSR-based)
            ├─ Vault TLS server cert    (for vault:8200)
            ├─ Dex TLS server cert      (for dex:5556)
            ├─ CNPG cluster certs       (via cert-manager ClusterIssuer → Vault)
            └─ Other leaf certs (Traefik, pgAdmin, Grafana, etc.)
```

Three-tier design: step-ca Root → step-ca Intermediate → Vault Intermediate → leaf. All leaf certs chain through Vault's PKI engine, which itself is signed by step-ca's intermediate. This means the step-ca root certificate is the single trust anchor for the entire playground.

## Design Patterns

### 1. Docker-Managed Lifecycle

The step-ca service runs **outside** any Kind cluster — it is a standalone Docker container on the host machine. This avoids bootstrapping circular dependencies (e.g., needing TLS certs from step-ca to set up cert-manager in K8s, but needing K8s to run step-ca).

- **Container image:** `smallstep/step-ca:latest`
- **Port:** 8443 (STEP_CA_PORT, configurable in common.sh)
- **Network:** Docker bridge (connected to `kind` network via DNS/hostname `step-ca`)
- **Init:** Uses `DOCKER_STEPCA_INIT_*` env vars for first-boot auto-config
- **UID:** Runs as UID 1000 (`step` user); host files use ACLs (`setfacl`) not UNIX ownership

### 2. Auto-Init via Environment Variables

The step-ca entrypoint detects empty data directories and runs `step ca init` automatically using injected env vars:

| Env Var | Value | Purpose |
|---------|-------|---------|
| `DOCKER_STEPCA_INIT_NAME` | `CloudNativePG Playground CA` | CA display name |
| `DOCKER_STEPCA_INIT_DNS_NAMES` | `localhost,step-ca,step-ca.<dashed-ip>.sslip.io` | SANs on intermediate cert |
| `DOCKER_STEPCA_INIT_ADDRESS` | `:8443` | Listen address |
| `DOCKER_STEPCA_INIT_PROVISIONER_NAME` | `admin` | Default JWK provisioner |
| `DOCKER_STEPCA_INIT_PASSWORD` | Random 24-byte base64 | CA + provisioner password |
| `DOCKER_STEPCA_INIT_DEPLOYMENT_TYPE` | `standalone` | BadgerDB (no external DB) |

### 3. Layered Configuration (Template + Generated + Override)

Configuration files use a three-layer approach:

1. **Generated `ca.json`** — Produced by `step ca init` on first container start. Contains the authority provisioners section (JWK provisioner).
2. **Template `ca.json.tpl`** — Defines desired authority settings (CRL, TLS cipher suites, DB backend). Gets envsubst'd and pushed into the container as `ca.json.override`.
3. **Merged `ca.json`** — A `jq -s` merge copies the provisioners from the generated file into the overridden authority block, producing the final config. step-ca is reloaded (SIGHUP) to pick it up.

### 4. Host-Side Key Operations (openssl over step CLI)

step CLI commands that require a TTY (like `step certificate create`) cannot run inside the container via `docker exec`. The workaround: **copy keys and certs to the host** and use `openssl` directly. This pattern is used by:

- `step-ca-renew-intermediate.sh` — generates a CSR from the intermediate key with openssl, signs it with the root CA key, replaces the cert in-place
- `vault-pki-setup.sh` — signs Vault's intermediate CSR using step-ca's intermediate CA key on the host (the step-ca container owns the signing key)

### 5. Templated K8s Wiring

The `traefik/` and `trust-manager/` subdirectories hold K8s resource templates that are applied *after* step-ca setup:

- **`traefik/service.yaml.tpl`** — Creates a Kubernetes `Service` + `Endpoints` (not an `EndpointSlice`) to route cluster traffic to the host-resident Docker container at `STEP_CA_IP:8443`. Applied per cluster region.
- **`trust-manager/bundle.yaml.tpl`** — Creates a `Bundle` CR (trust.cert-manager.io/v1alpha1) that reads a ConfigMap (`step-ca-roots`) containing the root + intermediate CA certs and injects them as trusted CAs into every namespace.

### 6. ACL-Based Volume Permissions (Not chown)

The container runs as UID 1000 but the host user is root. Instead of `chown`, the setup script applies POSIX ACLs:

```bash
sudo setfacl -R -m u:1000:rwx "${STEP_CA_DIR}"
sudo setfacl -R -d -m u:1000:rwx "${STEP_CA_DIR}"
```

For Podman with user namespaces, the UID is shifted by the subuid mapping (`SUBUID_START + 999`).

## Data & Control Flow

### Setup Flow (step-ca-setup.sh)

```
scripts/setup.sh
  └─ Phase 0: scripts/step-ca-setup.sh
       │
       ├─ Pull smallstep/step-ca:latest image
       ├─ Remove old container + state (if exists)
       ├─ Create directories: config/, pki/, secrets/, db/
       ├─ Set ACLs (UID 1000 or subuid-mapped UID)
       ├─ Write random CA password to secrets/.ca_password
       ├─ Compute sslip.io hostname (step-ca.<dashed-ip>.sslip.io)
       ├─ docker run with DOCKER_STEPCA_INIT_* env vars
       ├─ Wait for `step ca health` (polling loop, up to 60s)
       ├─ Extract root CA fingerprint → secrets/.ca_fingerprint
       ├─ Update JWK provisioner: x509-max-dur=2160h, default-dur=720h
       ├─ Add X5C provisioner (for cert-based auth / Vault intermediate)
       ├─ Apply ca.json.tpl overrides (CRL, TLS) via envsubst + jq merge
       ├─ Reload step-ca (kill -HUP 1)
       └─ Copy root+intermediate CAs into container's /etc/ssl/certs
            (needed so step-ca can verify Dex's OIDC TLS cert during
             OIDC discovery, which chains through Vault intermediate → step-ca)
```

### Post-Setup Integration (scripts/setup.sh Phase 1+)

```
Phase 1 (per cluster region):
  ├─ Create 'step-ca' namespace (dry-run kubectl)
  ├─ template step-ca/traefik/service.yaml.tpl → kubectl apply (Service + Endpoints)
  │
  └─ trust-manager (helm install):
       ├─ Create ConfigMap 'step-ca-roots' from step-ca/pki/{root,intermediate}_ca.crt
       └─ template step-ca/trust-manager/bundle.yaml.tpl → kubectl apply

Phase 1.5 (post-Dex):
  ├─ Add OIDC provisioner to step-ca (for dex-based auth)
  ├─ Add Vault intermediate CA to step-ca trust store (for Dex TLS verification)
  └─ Reload step-ca
```

### Certificate Renewal Flows

```
step-ca-renew-intermediate.sh (manual / scheduled):
  ├─ Pre-flight: check container + intermediate_ca.crt exist
  ├─ Show current cert info
  ├─ Copy intermediate key from container → host tempfile
  ├─ openssl req -new → CSR
  ├─ Copy root cert + key from container → host tempfiles
  ├─ openssl x509 -req -CA ... → signed intermediate cert (1825 days)
  ├─ Backup old cert → pki/backups/intermediate_ca.crt.<timestamp>
  ├─ Replace cert: host copy + docker cp into container
  ├─ Reload step-ca (kill -HUP 1)
  ├─ Wait for health check
  └─ Cleanup tempfiles

vault-renew-intermediate.sh:
  └─ Similar pattern: signs Vault's intermediate CSR using step-ca's
       intermediate CA key (copied from container to host)
```

### Teardown Flow (step-ca-teardown.sh)

```
scripts/teardown.sh
  └─ scripts/step-ca-teardown.sh
       ├─ docker rm -f step-ca (if running)
       ├─ sudo rm -rf pki/ secrets/ db/
       └─ sudo rm -f config/ca.json config/defaults.json config/ca.json.override
```

## Directory Map

| Path | Purpose |
|------|---------|
| `config/ca.json.tpl` | step-ca configuration template: CRL settings, TLS cipher suites (ECDHE-ECDSA only), BadgerDB storage, empty provisioners array (merged with init-generated provisioners via jq) |
| `pki/` | Runtime directory: contains `root_ca.crt` and `intermediate_ca.crt` (auto-generated by `step ca init`, replaced on renewal). Created on setup, destroyed on teardown. |
| `secrets/` | Runtime directory: `.ca_password` (CA/provisioner password), `intermediate_ca_key`, `root_ca_key`, `.ca_fingerprint`. Created on setup, destroyed on teardown. |
| `db/` | Runtime directory: BadgerDB v2 storage for step-ca certificate database. Created on setup, destroyed on teardown. |
| `traefik/service.yaml.tpl` | K8s Service + Endpoints template wiring step-ca (host port 8443) into each Kind cluster. Applied per region. |
| `trust-manager/bundle.yaml.tpl` | trust-manager Bundle CR template distributing step-ca root+intermediate CA bundle cluster-wide. |

## Integration Points

| Consumer | Mechanism | Details |
|----------|-----------|---------|
| **Vault PKI** (`vault-pki-setup.sh`) | X5C provisioner + host-side openssl | Vault's intermediate CSR is signed by step-ca's intermediate CA key. The X5C provisioner was added specifically for this. |
| **Kind Clusters** (per region) | K8s Service/Endpoints (`traefik/service.yaml.tpl`) | Cluster-internal DNS `step-ca.step-ca.svc.cluster.local:8443` routes to the host container. |
| **trust-manager** | `Bundle` CR (`trust-manager/bundle.yaml.tpl`) | Distributes step-ca root + intermediate as trusted CAs to all namespaces. |
| **cert-manager ClusterIssuer** | Vault PKI engine (signed by step-ca) | Leaf certs for Traefik, pgAdmin, Grafana, etc. are issued by Vault, which chains to step-ca. |
| **Dex OIDC** (`dex-setup.sh`) | OIDC provisioner (added post-Dex bootstrap) | step-ca verifies Dex's OIDC discovery TLS cert (which chains through step-ca → Vault intermediate). step-ca's trust store includes its own root+intermediate + Vault intermediate. |
| **Vault TLS Cert** (`vault-setup.sh`) | `step ca certificate` (JWK provisioner) | Vault's initial TLS server cert is issued directly by step-ca. |
| **External Secrets Operator** | Indirect via cert-manager/Vault | ESO ClustersSecretStores reference Vault's PKI, which chains to step-ca. |
| **Outbound TLS from step-ca** | Container trust store (`/etc/ssl/certs`) | Root + intermediate CAs are appended to the container's ca-certificates.crt so step-ca can verify Dex's OIDC cert (which includes Vault intermediate → step-ca chain). |
