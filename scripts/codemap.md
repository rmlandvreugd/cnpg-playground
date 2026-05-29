# scripts/

## Responsibility

The `scripts/` directory is the **lifecycle manager and bootstrap orchestrator** for the CloudNativePG playground. It provides a set of idempotent shell scripts that provision, configure, inspect, and tear down a multi-region CloudNativePG (PostgreSQL operator for Kubernetes) learning environment. This environment supports three regions — **`local`** (the primary learning environment, single-region standalone), **`eu`** (primary in multi-region setup), and **`us`** (DR replica) — each with its own Kind-based Kubernetes cluster, S3-compatible object store (RustFS), and shared external services (step-ca Root CA, HashiCorp Vault, Dex OIDC). The scripts handle:

- **Environment bootstrapping**: kernel tuning (sysctl), dependency validation, container runtime detection
- **External service provisioning**: step-ca (Root CA / intermediate CA), Vault (secrets/PKI/OIDC), Dex (OIDC provider), RustFS (object storage)
- **Multi-region cluster orchestration**: Kind cluster creation, MetalLB load balancer setup, Traefik ingress, cert-manager, trust-manager, External Secrets Operator (ESO)
- **Cross-cluster secret distribution**: S3 credentials propagated to every cluster
- **Observability wiring**: Traefik tracing configuration for OTel collector integration
- **PKI certificate renewal**: Intermediate CA renewal for both step-ca and Vault
- **Full teardown**: Graceful destroy of all resources with idempotent cleanup

## Design Patterns

### 1. Source-Based Module Composition (Mixin Pattern)

All operational scripts source `common.sh` as their first action, which in turn sources `funcs_regions.sh`. This creates a **flat namespace of shared variables and functions** available to every consumer script without explicit import chains.

```
setup.sh ──source──▶ common.sh ──source──▶ funcs_regions.sh
teardown.sh ──source──▶ common.sh
info.sh ──source──▶ common.sh
step-ca-setup.sh ──source──▶ common.sh
vault-setup.sh ──source──▶ common.sh
vault-pki-setup.sh ──source──▶ common.sh
dex-setup.sh ──source──▶ common.sh
step-ca-teardown.sh ──source──▶ common.sh
vault-teardown.sh ──source──▶ common.sh
step-ca-renew-intermediate.sh ──source──▶ common.sh
vault-renew-intermediate.sh ──source──▶ common.sh
...
```

### 2. Auto-Correction on Load (Self-Healing Init)

`common.sh` performs sysctl threshold checking at **source time** (lines 25–56). If kernel parameters fall below minimum thresholds (`fs.inotify.max_user_watches`, `kernel.keys.maxkeys`, etc.), it **automatically invokes `tune-sysctl.sh`** before the rest of the script executes. This ensures the host kernel is configured correctly for Kind clusters without requiring a separate manual step.

### 3. Helm Wrapper Abstraction

`helm_upgrade_install()` in `common.sh` (lines 193–219) provides a consistent interface for Helm chart deployment. It normalizes flags across all call sites: namespace creation, explicit kube-context, version pinning, waiting, and timeout. It also supports an optional `--repo-url` flag for non-OCI chart repositories.

### 4. Container-Exec RPC Adapter

Multiple scripts define local functions that wrap CLI commands executed **inside** containers via `$CONTAINER_PROVIDER exec`. This abstracts the container boundary and provides consistent environment variables:

- **`_vcmd()` / `_vcmd_stdin()`** — Vault CLI adapter used by `vault-setup.sh`, `vault-pki-setup.sh`, `vault-eso-setup.sh`, `vault-oidc-setup.sh`, `dex-setup.sh`, `eso-setup.sh`. Sets `VAULT_ADDR`, `VAULT_CACERT`, `VAULT_TOKEN`. The `_stdin` variant pipes policy writes via stdin.
- **`_scmd()`** — step CLI adapter used by `vault-pki-setup.sh`, `step-ca-setup.sh`. Sets `STEPPATH=/home/step`.
- **`_srenew()`** (implicit pattern) — step-ca intermediate renewal in `step-ca-renew-intermediate.sh` and `vault-renew-intermediate.sh` uses `openssl` on the **host** filesystem rather than inside containers because `step certificate sign` requires a TTY not available via `$CONTAINER_PROVIDER exec`. Cert/key material is copied out of containers, signed, and copied back.

### 5. Template-Driven Configuration (envsubst)

All YAML/configuration files with dynamic values (Vault service definitions, Traefik ingress routes, Dex config, cert-manager ClusterIssuer, ESO ClusterSecretStore) use `envsubst` for variable substitution. Templates use the `.tpl` extension and are rendered at runtime by exporting variables then piping through `envsubst`.

### 6. Idempotent Teardown with Guard Checks

Every teardown script (`teardown.sh`, `step-ca-teardown.sh`, `vault-teardown.sh`, `dex-teardown.sh`) checks for resource existence before attempting deletion:
- `kind get clusters | grep` for cluster existence
- `$CONTAINER_PROVIDER ps -a` for container existence
- `$CONTAINER_PROVIDER volume inspect` for volume existence
- `helm status` guard in `helm_uninstall_if_present()`

### 7. Region-Based Multi-Tenancy Partitioning

The `REGIONS` array (set by `set_regions()` or `detect_running_regions()` in `funcs_regions.sh`) drives all per-region operations. The default is `("eu" "us")`, but `local` is a fully-supported first-class region — pass it as an argument (e.g., `scripts/setup.sh local`). Cluster names, kubeconfig contexts, RustFS container names, MetalLB IP ranges, and ESO AppRole roles are all derived from the region identifier using helper functions (`get_cluster_name()`, `get_cluster_context()`).

**`local` is the primary learning environment**: the ESO and self-service demo scripts (`demo/eso-vault.sh`, `demo/self-service-setup.sh`) only support `local` mode.

MetalLB IP allocation uses **deterministic partitioning** of the Kind Docker bridge subnet:
- `/24` subnets: vary the 4th octet in blocks of 25 per region
- `/16` subnets: vary the 3rd octet downward from 255

### 8. Phase-Based Lifecycle with Sequential Delegation

`setup.sh` divides provisioning into numbered phases (Phase 0: external services, Phase 1: per-region infra, Phase 2: cross-cluster secrets) and delegates to sub-scripts via direct invocation. This forms a **sequential orchestration pipeline** where each sub-script is a self-contained module.

## Data & Control Flow

### Setup Flow (`setup.sh`)

```
Entry: setup.sh [region1 region2 ...]
  │
  ├─ 1. Source common.sh
  │     ├─ Validate sysctl thresholds → auto-invoke tune-sysctl.sh if needed
  │     ├─ Define all version variables and credential defaults (step-ca, Vault, Dex, cert-manager, trust-manager, ESO, Traefik, MetalLB, etc.)
  │     ├─ Validate required CLI tools (kind, kubectl, helm, jq, etc.)
  │     ├─ Auto-detect container provider (docker/podman)
  │     ├─ Resolve GIT_REPO_ROOT and KUBE_CONFIG_PATH
  │     └─ Source funcs_regions.sh → set_regions(argv) populates ${REGIONS[@]}
  │
  ├─ 2. Pre-flight check: verify no existing clusters (exits if found)
  │
  ├─ 3. Phase 0 — External Services (sequential)
  │     ├─ step-ca-setup.sh
  │     │     └─ Deploys step-ca container (Root CA) via auto-init env vars
  │     │     └─ Generates root + intermediate CA certs
  │     │     └─ Updates JWK provisioner max TTL to 2160h
  │     │     └─ Adds X5C provisioner (for cert-based auth)
  │     │     └─ Applies ca.json overrides (CRL, TLS) from template
  │     │     └─ Adds root + intermediate CAs to container trust store
  │     │     └─ Writes .ca_password, .ca_fingerprint to step-ca/secrets/
  │     ├─ vault-setup.sh
  │     │     └─ Requests TLS cert from step-ca for Vault's sslip.io hostname
  │     │     └─ Deploys Vault non-dev container with file storage + audit logging
  │     │     └─ Initializes Vault (1 key share, 1 threshold), unseals
  │     │     └─ Writes .unseal_key and .root_token to vault/
  │     │     └─ Enables userpass auth, creates admin user
  │     ├─ vault-pki-setup.sh
  │     │     └─ Enables root PKI engine (serves step-ca root chain)
  │     │     └─ Enables pki_int engine, generates CSR, signs with step-ca intermediate via openssl on host
  │     │     └─ Creates PKI roles (dex-server, cluster-certs, mtls-client) with not_before_duration=0s
  │     │     └─ Creates cert-manager AppRole → writes .approle_role_id / .approle_secret_id
  │     ├─ vault-eso-setup.sh
  │     │     └─ Enables cnpg/ KV v2 mount
  │     │     └─ Writes eso-cnpg policy
  │     └─ dex-setup.sh
  │           └─ Issues TLS cert from Vault PKI for dex (dex-server role)
  │           └─ Appends step-ca intermediate + root to dex.crt, ca.crt, ca-chain.pem (full chain)
  │           └─ Generates Dex config from templates
  │           └─ Deploys Dex container, polls OIDC discovery endpoint
  │
  ├─ 4. Phase 1 — Per-Region Provisioning (loop over REGIONS)
  │     │
  │     │  For each region:
  │     │  ┌─ a) Create RustFS container (S3-compatible object store)
  │     │  │     └─ Docker volume + container on incrementing host port
  │     │  ├─ b) Create Kind cluster (using kind-config.yaml)
  │     │  │     └─ Label nodes by role (postgres, infra, app)
  │     │  ├─ c) Install MetalLB (Helm)
  │     │  │     └─ Enable strict ARP, compute IP range from subnet + region index
  │     │  │     └─ Create IPAddressPool + L2Advertisement
  │     │  ├─ d) Connect containers to Kind network
  │     │  │     └─ Docker network connect kind (RustFS, step-ca, Vault, Dex containers)
  │     │  ├─ e) Wire step-ca into K8s
  │     │  │     └─ Create step-ca namespace + headless Service/Endpoints from template
  │     │  ├─ f) Wire Vault into K8s
  │     │  │     └─ Create vault namespace + headless Service/Endpoints from template
  │     │  ├─ g) Install cert-manager (OCI Helm)
  │     │  │     └─ Wait for cert-manager-webhook deployment ready
  │     │  ├─ h) Install trust-manager (OCI Helm)
  │     │  │     └─ Wait for trust-manager webhook deployment ready
  │     │  │     └─ Create step-ca-roots ConfigMap with root + intermediate CA
  │     │  │     └─ Apply trust-manager Bundle resource (distributes step-ca root to all namespaces)
  │     │  ├─ i) Create cert-manager secrets
  │     │  │     └─ Create vault-approle (secretId) and vault-tls-ca (ca.crt) secrets
  │     │  │     └─ Apply vault-pki ClusterIssuer (HTTPS + caBundle)
  │     │  ├─ j) Install External Secrets Operator (per-region)
  │     │  │     └─ eso-setup.sh (called with REGION + CONTEXT_NAME exported)
  │     │  │     └─ Creates Vault AppRole for this region
  │     │  │     └─ Installs ESO Helm chart
  │     │  │     └─ Creates vault-approle-creds Secret + ClusterSecretStore
  │     │  └─ k) Install Traefik (OCI Helm)
  │     │        └─ Non-hub regions: no tracing args initially
  │     │        └─ Hub region: wired to OTel collector endpoint
  │     │        └─ TLS certificate from Vault PKI → cert-manager Certificate
  │     │        └─ HTTPS IngressRoute for dashboard
  │     │
  │     └─ Store objectstore port mapping for Phase 2
  │
  ├─ 5. vault-oidc-setup.sh (post-loop, single execution)
  │     └─ Enables OIDC auth method in Vault
  │     └─ Configures Dex as OIDC provider (discovery URL, CA chain)
  │     └─ Creates oidc-policy + oidc-user role
  │
  ├─ 6. Add step-ca OIDC provisioner (post-Dex, single execution)
  │     └─ Adds Vault intermediate CA to step-ca trust store (for Dex TLS verification)
  │     └─ Adds Dex OIDC provisioner to step-ca via `step ca provisioner add`
  │     └─ Reloads step-ca with kill -HUP 1
  │
  └─ 7. Phase 2 — Cross-Cluster Secret Distribution
        └─ For each region × each objectstore:
             └─ kubectl create secret (RustFS credentials)
```

### Teardown Flow (`teardown.sh`)

```
Entry: teardown.sh [region1 region2 ...]
  │
  ├─ Source common.sh → detect_running_regions(argv) or auto-detect
  │
  ├─ For each region:
  │     ├─ kind delete cluster
  │     ├─ docker rm -f RustFS container
  │     ├─ docker volume rm RustFS data volume
  │     └─ kubectl config delete-context / delete-cluster (clean up kubeconfig)
  │
  ├─ step-ca-teardown.sh
  │     └─ docker rm -f step-ca container
  │     └─ rm -rf step-ca/{pki,secrets,db}
  │     └─ rm -f step-ca/config/{ca.json,defaults.json,ca.json.override}
  │
  ├─ vault-teardown.sh
  │     └─ docker rm -f vault container
  │     └─ rm -rf vault/{data,logs,certs,pki}
  │     └─ rm -f .unseal_key .root_token .approle_role_id .approle_secret_id
  │
  └─ dex-teardown.sh
        └─ docker rm -f dex container
        └─ rm -rf dex/{tls,config/dex-config.yaml}
```

### Info Flow (`info.sh`)

```
Entry: info.sh
  │
  ├─ Source common.sh
  ├─ Validate KUBE_CONFIG_PATH exists
  ├─ detect_running_regions()
  └─ For each region:
        ├─ kubectl version
        ├─ kubectl get nodes -o wide
        ├─ kubectl get secrets
        └─ get_traefik_lb_ip() → construct sslip.io URLs for Traefik/Grafana
```

### State Transitions

| State | Trigger | Script | Outcome |
|-------|---------|--------|---------|
| HOST_UNCONFIGURED | `common.sh` sourced | `tune-sysctl.sh` | sysctl params ≥ threshold |
| STEP_CA_DOWN → STEP_CA_UP | `setup.sh` Phase 0 | `step-ca-setup.sh` | step-ca container running, root + intermediate CA generated |
| VAULT_DOWN → VAULT_UP | `setup.sh` Phase 0 | `vault-setup.sh` | Vault container running with step-ca TLS cert, `.root_token` written |
| VAULT_PKI_UNCONFIGURED → CONFIGURED | `setup.sh` Phase 0 | `vault-pki-setup.sh` | Root + intermediate PKI (signed by step-ca), AppRole for cert-manager |
| DEX_DOWN → DEX_UP | `setup.sh` Phase 0 | `dex-setup.sh` | Dex container running, full-chain TLS, OIDC discovery ready |
| CLUSTER_NOT_EXIST → CLUSTER_EXISTS | `setup.sh` Phase 1 per region | `kind create cluster` via setup.sh | Kind cluster created |
| METALLB_NOT_INSTALLED → INSTALLED | `setup.sh` Phase 1 per region | `helm_upgrade_install` | MetalLB + IP pool + L2 advertisement |
| CERT_MANAGER_NOT_INSTALLED → INSTALLED | `setup.sh` Phase 1 per region | `helm_upgrade_install` | cert-manager installed |
| TRUST_MANAGER_NOT_INSTALLED → INSTALLED | `setup.sh` Phase 1 per region | `helm_upgrade_install` | trust-manager installed, Bundle distributes step-ca root |
| ESO_NOT_INSTALLED → INSTALLED | `setup.sh` Phase 1 per region | `eso-setup.sh` | ESO Helm chart + ClusterSecretStore |
| TRAEFIK_NOT_INSTALLED → INSTALLED | `setup.sh` Phase 1 per region | `helm_upgrade_install` | Traefik + TLS dashboard |
| STEP_CA_OIDC_UNCONFIGURED → CONFIGURED | `setup.sh` after Phase 1 | Direct steps in setup.sh | Dex OIDC provisioner added to step-ca |
| VAULT_OIDC_UNCONFIGURED → CONFIGURED | `setup.sh` after Phase 1 | `vault-oidc-setup.sh` | OIDC auth enabled, role created |
| RUSTFS_SECRETS_NOT_DISTRIBUTED → DISTRIBUTED | `setup.sh` Phase 2 | Direct kubectl in setup.sh | S3 credentials in each cluster |
| STEP_CA_INT_NEEDS_RENEWAL → RENEWED | Manual | `step-ca-renew-intermediate.sh` | Intermediate CA cert re-signed by root CA |
| VAULT_INT_NEEDS_RENEWAL → RENEWED | Manual | `vault-renew-intermediate.sh` | Vault intermediate CA cert re-signed by step-ca |
| ANY → DESTROYED | `teardown.sh` | All teardown scripts | Clusters/containers/volumes/files removed |

## Integration Points

### External Dependencies (CLI Tools)

| Tool | Version Pinned | Used By |
|------|---------------|---------|
| `kind` | no | All scripts (cluster lifecycle) |
| `kubectl` | no | All scripts (K8s API operations) |
| `helm` | no | `common.sh` (`helm_upgrade_install`), `eso-setup.sh` |
| `jq` | no | `dex-setup.sh`, `vault-setup.sh`, `vault-pki-setup.sh`, `step-ca-setup.sh` (JSON parsing) |
| `openssl` | no | `step-ca-setup.sh`, `vault-pki-setup.sh`, `step-ca-renew-intermediate.sh`, `vault-renew-intermediate.sh` (CSR generation, cert signing) |
| `envsubst` | no | `setup.sh`, `dex-setup.sh`, `eso-setup.sh`, `step-ca-setup.sh` (template rendering) |
| `git` | no | `common.sh` (`rev-parse --show-toplevel`) |
| `grep`/`sed` | no | Various (string manipulation, parsing) |
| `sudo` | no | `vault-setup.sh`, `vault-teardown.sh`, `dex-setup.sh`, `tune-sysctl.sh` |
| `setfacl` | no | `vault-setup.sh`, `dex-setup.sh` (container UID permissions) |

### Container Images Referenced

| Image | Variable | Consumer |
|-------|----------|----------|
| `rustfs/rustfs:latest` | `RUSTFS_IMAGE` | `setup.sh` (object store) |
| `smallstep/step-ca:latest` | `STEP_CA_IMAGE` | `step-ca-setup.sh` |
| `hashicorp/vault:2.0` | `VAULT_IMAGE` | `vault-setup.sh` |
| `ghcr.io/dexidp/dex:v2.45.1` | `DEX_IMAGE` | `dex-setup.sh` |
| `traefik:v3.3` | `TRAEFIK_IMAGE` | `setup.sh` (via Helm) |
| `ghcr.io/mendhak/http-https-echo:40` | (hardcoded) | `lb-test.yaml` (test manifest) |

### Helm Chart References (via `helm_upgrade_install`)

| Release Name | Chart Source | Version Variable | Installed By |
|-------------|-------------|------------------|--------------|
| `metallb` | `metallb/metallb` (repo) | `METALLB_CHART_VERSION` | `setup.sh` |
| `cert-manager` | `oci://quay.io/jetstack/charts/cert-manager` | `CERT_MANAGER_CHART_VERSION` | `setup.sh` |
| `trust-manager` | `oci://quay.io/jetstack/charts/trust-manager` | `TRUST_MANAGER_CHART_VERSION` | `setup.sh` |
| `external-secrets` | `external-secrets` (repo) | `ESO_CHART_VERSION` | `eso-setup.sh` |
| `traefik` | `oci://ghcr.io/traefik/helm/traefik` | `TRAEFIK_CHART_VERSION` | `setup.sh` |

### File System Artifacts

| Path Pattern | Producer | Consumer |
|-------------|----------|----------|
| `step-ca/pki/root_ca.crt` | `step-ca-setup.sh` | `vault-setup.sh`, `vault-pki-setup.sh`, `dex-setup.sh`, `setup.sh` (trust-manager ConfigMap) |
| `step-ca/pki/intermediate_ca.crt` | `step-ca-setup.sh` | `vault-pki-setup.sh`, `dex-setup.sh`, `setup.sh`, `step-ca-renew-intermediate.sh` |
| `step-ca/secrets/.ca_password` | `step-ca-setup.sh` | `vault-pki-setup.sh`, `step-ca-renew-intermediate.sh`, `vault-renew-intermediate.sh` |
| `step-ca/secrets/.ca_fingerprint` | `step-ca-setup.sh` | (user reference for bootstrapping) |
| `step-ca/config/ca.json` | `step-ca-setup.sh` (auto-generated) | step-ca container |
| `step-ca/config/ca.json.override` | `step-ca-setup.sh` (from template) | step-ca container (merged) |
| `vault/.root_token` | `vault-setup.sh` | `vault-pki-setup.sh`, `vault-eso-setup.sh`, `dex-setup.sh`, `eso-setup.sh`, `vault-renew-intermediate.sh` |
| `vault/.unseal_key` | `vault-setup.sh` | (emergency access) |
| `vault/.approle_role_id` | `vault-pki-setup.sh` | `setup.sh` (cert-manager ClusterIssuer) |
| `vault/.approle_secret_id` | `vault-pki-setup.sh` | `setup.sh` (cert-manager secret) |
| `vault/.eso_${REGION}_role_id` | `eso-setup.sh` | (debug/recovery) |
| `vault/.eso_${REGION}_secret_id` | `eso-setup.sh` | (debug/recovery) |
| `vault/certs/vault-cert.pem` | `vault-setup.sh` (from step-ca) | Vault container (TLS server cert) |
| `vault/certs/vault-key.pem` | `vault-setup.sh` (from step-ca) | Vault container (TLS server key) |
| `vault/certs/vault-ca.pem` | `vault-setup.sh` (step-ca root + intermediate chain) | All `_vcmd()` calls, `setup.sh` (cert-manager) |
| `vault/pki/root.crt` | `vault-pki-setup.sh` | (served by Vault PKI engine) |
| `vault/pki/intermediate.crt` | `vault-pki-setup.sh` | (reference, served by Vault) |
| `dex/tls/dex.crt` | `dex-setup.sh` | Dex container (server cert + full chain) |
| `dex/tls/dex.key` | `dex-setup.sh` | Dex container |
| `dex/tls/ca.crt` | `dex-setup.sh` | Dex container (CA chain with step-ca) |
| `dex/tls/ca-chain.pem` | `dex-setup.sh` | (readiness poll, OIDC discovery verification) |
| `dex/config/dex-config.yaml` | `dex-setup.sh` | Dex container |
| `k8s/kube-config.yaml` | `setup.sh` (kind + kubectl) | `info.sh`, user access |

### API / Endpoint Integrations

| Endpoint | Purpose | Consumer |
|----------|---------|----------|
| `https://127.0.0.1:8443` | step-ca HTTPS API (internal) | `_scmd()` via container exec |
| `https://127.0.0.1:8200` | Vault HTTPS API (internal) | `_vcmd()` via container exec |
| `https://dex.<ip>.sslip.io:5556/dex/.well-known/openid-configuration` | Dex OIDC discovery | `dex-setup.sh` (readiness poll), `vault-oidc-setup.sh` (OIDC config), `setup.sh` (step-ca OIDC provisioner) |
| `https://step-ca.<ip>.sslip.io:8443` | step-ca HTTPS API (from K8s) | cert-manager ClusterIssuer, K8s workloads |
| `https://vault.<ip>.sslip.io:8200` | Vault HTTPS API (from K8s) | cert-manager ClusterIssuer, ESO ClusterSecretStore |
| OTel Collector gRPC (hub region only) | Traefik tracing export | Traefik Helm values via `setup.sh` |
| `sslip.io` DNS wildcard | Dynamic hostnames for step-ca/Traefik/Vault/Dex | `setup.sh`, `vault-oidc-setup.sh`, `dex-setup.sh`, `step-ca-setup.sh` |

### Script Call Graph

```
scripts/
├── common.sh               (shared config, sysctl check, utils, sources funcs_regions.sh)
├── funcs_regions.sh         (region name helpers, auto-detection)
├── tune-sysctl.sh           (kernel parameter tuning, invoked autonomously by common.sh)
│
├── setup.sh                 (main orchestrator)
│   ├── step-ca-setup.sh     (step-ca Root CA container + provisioners)
│   ├── vault-setup.sh       (Vault container + step-ca TLS + userpass)
│   ├── vault-pki-setup.sh   (PKI engines, signed by step-ca, cert-manager AppRole)
│   ├── vault-eso-setup.sh   (cnpg KV mount + eso-cnpg policy)
│   ├── dex-setup.sh         (Dex OIDC container with full chain TLS)
│   ├── eso-setup.sh         (per-region ESO install + ClusterSecretStore)
│   └── vault-oidc-setup.sh  (Vault OIDC auth with Dex)
│
├── teardown.sh              (main destroyer)
│   ├── step-ca-teardown.sh  (step-ca container + pki/secrets/db/config)
│   ├── vault-teardown.sh    (Vault container + data/logs/certs/pki + tokens)
│   └── dex-teardown.sh      (Dex container + tls/config)
│
├── step-ca-renew-intermediate.sh   (renew step-ca intermediate CA cert)
├── vault-renew-intermediate.sh     (renew Vault intermediate CA cert via step-ca)
│
├── info.sh                  (status display)
│
└── lb-test.yaml             (static K8s manifest, not a script)
```

### Directory Boundary

The scripts in this directory are the **sole entry points** for the playground lifecycle. They are invoked from the project root (e.g., `./scripts/setup.sh`) and are not sourced by non-script code. The `scripts/` directory is a consumer of templates and configuration files located in sibling directories (`step-ca/`, `vault/`, `dex/`, `traefik/`, `k8s/`) and a producer of runtime state files (`vault/.root_token`, `step-ca/pki/root_ca.crt`, `k8s/kube-config.yaml`, etc.) consumed by other tools and user workflows.
