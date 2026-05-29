# step-ca PKI Expansion Spec

## Overview

Expand the cnpg-playground PKI by introducing SmallStep `step-ca` as the authoritative Certificate Authority, with Vault PKI becoming a subordinate under the step-ca hierarchy. step-ca and Vault co-exist: step-ca's intermediate CA signs Vault's intermediate CA, establishing a unified 3-tier trust chain. trust-manager is added to clusters to distribute PKI trust bundles. step-ca PKI certificates enable TLS for services outside containers.

## PKI Hierarchy

```
step-ca Root CA (10yr TTL, standalone, BadgerDB)
  └── step-ca Intermediate CA (5yr TTL, online server)
        ├── Vault Intermediate CA (5yr TTL, signed by step-ca)
        │     ├── In-cluster leaf certs (720h / 30d) — via cert-manager
        │     └── In-cluster mTLS client certs (168h / 7d) — via cert-manager
        ├── Vault API TLS cert — issued directly from step-ca
        ├── RustFS server TLS cert — issued directly from step-ca
        └── External mTLS client certs (168h / 7d) — via step CLI
```

**Key principle:** Vault's existing self-signed root CA is eliminated. Vault PKI is re-initialized with its intermediate signed by step-ca. The Vault PKI paths (`pki/`, `pki_int/`) are kept — only the keys/certs are replaced.

## Certificate TTLs

| Certificate Type | TTL |
|---|---|
| step-ca Root CA | 10 years |
| step-ca Intermediate CA | 5 years |
| Vault Intermediate CA | 5 years |
| In-cluster leaf certs (server) | 720h (30 days) |
| mTLS client certs | 168h (7 days) |

## step-ca Deployment

### Container Configuration

- **Image:** `smallstep/step-ca` (official Docker image)
- **Deployment type:** Standalone (`--deployment-type=standalone`)
- **Database:** BadgerDB (embedded, file-based, step-ca default for single-node)
- **Port:** 8443 (avoids conflicts with Vault 8200/8202, Dex 5556, RustFS 9000+)
- **Network:** Docker container on `kind` bridge network
- **Init approach:** Hybrid — environment variables (`STEPCA_INIT_*`) for initial boot, then override specific settings via mounted `ca.json`
- **Entrypoint:** Use the [official Docker entrypoint.sh](https://github.com/smallstep/certificates/blob/master/docker/entrypoint.sh) as reference

### Cluster Connectivity

Same pattern as Vault: K8s Service + Endpoints in each cluster pointing to the step-ca container IP.

- Namespace: `step-ca` (new) or reuse `vault` namespace
- Service: headless Service + Endpoints mapping to container IP
- In-cluster URL: `https://step-ca.step-ca.svc.cluster.local:8443`

### Provisioners

| Provisioner | Purpose | When Enabled |
|---|---|---|
| JWK | Automated scripts, service accounts | Bootstrap |
| X5C | Certificate-based auth, Vault intermediate signing | Bootstrap |
| OIDC | Human operators via Dex | After Dex is running |

### Admin Secrets

step-ca admin secrets (ca.json root password, provisioner JWK keys) are stored as **encrypted files on host** — consistent with the playground approach and avoiding circular dependencies with Vault.

## Vault PKI Changes

### Re-initialization

Vault PKI paths `pki/` and `pki_int/` are kept. The setup script:

1. Generates a CSR from Vault's intermediate CA
2. Submits the CSR to step-ca for signing
3. Imports the step-ca-signed certificate back into Vault as the intermediate CA cert
4. Vault's old self-signed root is no longer used

### Vault TLS Certificate

Vault's own API TLS cert (port 8200) is **issued directly from step-ca** — not from Vault's own PKI. This avoids circular dependency and keeps a clean chain.

### Port Strategy

| Port | Protocol | Purpose |
|---|---|---|
| 8200 | HTTPS (step-ca-issued cert) | External access, in-cluster HTTPS+AppRole |
| 8202 | HTTP (plain) | Bootstrap fallback only |

In-cluster services (ESO, cert-manager) switch from HTTP 8202 to **HTTPS+AppRole on 8200** (server TLS only — verify Vault's identity, no client cert). Port 8202 remains available as a fallback during bootstrap before step-ca is available.

### Vault Intermediate Renewal

A **separate script** handles Vault intermediate CA renewal:

1. Generate CSR from Vault
2. Submit CSR to step-ca for re-signing
3. Import signed cert back into Vault
4. Restart affected workloads if needed

## trust-manager Integration

### Bundle Content

trust-manager distributes the **step-ca Root CA + step-ca Intermediate CA** bundle. Vault's intermediate is discovered via the certificate chain — not included in the trust bundle.

### Bundle Source

A **ConfigMap** created by the setup script containing the CA certs. trust-manager references this ConfigMap as the source for its `Bundle` resource.

### Cluster Installation

trust-manager is installed via Helm in each cluster (alongside cert-manager). A `Bundle` resource is created that:

- Sources from the ConfigMap
- Targets all namespaces
- Makes the CA bundle available as a ConfigMap in each namespace

## mTLS Architecture

### Selective mTLS Enforcement

mTLS is applied selectively to high-value communication paths:

| Path | mTLS Type | Issuer | Mechanism |
|---|---|---|---|
| CNPG replication (in-cluster) | Server + Client TLS | Vault PKI | cert-manager Certificate CRs |
| External DB access (psql, etc.) | Server + Client TLS | step-ca | step CLI |
| Monitoring: Prometheus → Mimir | Application-level mTLS | Vault PKI | cert-manager CRs + Helm values |
| Monitoring: Alloy → Loki/Tempo | Application-level mTLS | Vault PKI | cert-manager CRs + Helm values |
| CNPG → RustFS (S3) | Server TLS only | step-ca | HTTPS, static access keys |
| ESO → Vault | Server TLS only | step-ca (Vault cert) | HTTPS+AppRole |
| cert-manager → Vault | Server TLS only | step-ca (Vault cert) | HTTPS+AppRole |

### mTLS Client Certificate Issuance

- **In-cluster mTLS clients:** Vault PKI issues client certs via cert-manager (new mTLS client role under `pki_int/` with client auth EKU)
- **External mTLS clients:** step-ca issues client certs via `step ca certificate` CLI (manual workflow)

### Monitoring mTLS Distribution

Application-level mTLS for monitoring uses a combination of:

1. **cert-manager Certificate CRs** — Prometheus, Alloy, Mimir, Loki, Tempo each get a Certificate CR, Vault PKI issues them
2. **Helm chart values** — embed cert references in `kube-prometheus-stack`, `mimir-distributed`, `loki`, `tempo` Helm values, referencing K8s TLS secrets from cert-manager

Exact combination to be investigated during implementation based on what each Helm chart supports natively.

## Certificate Revocation

**CRL from the issuer is primary:**

- **step-ca** serves CRL endpoints for certificates it issues (external services, Vault API cert, RustFS cert)
- **Vault PKI** serves CRL endpoints for certificates it issues (in-cluster services)

No OCSP — CRL only for this playground environment.

## External Client Workflow

External clients (psql, curl, dev tools) obtain certificates and trust the PKI chain as follows:

- **Trust:** CA cert passed explicitly per-tool (e.g., `psql sslrootcert=`, `curl --cacert`) — not added to system trust store
- **Client certs:** Obtained via `step ca certificate` on the host, manually copied to the client
- **Renewal:** Manual via step CLI

## Bootstrap Sequence

The new bootstrap order in `scripts/setup.sh`:

```
1. step-ca-setup.sh          ← NEW: step-ca container + PKI init
2. vault-setup.sh             ← Existing: Vault container (now gets TLS cert from step-ca)
3. vault-pki-setup.sh         ← MODIFIED: Vault PKI signed by step-ca intermediate
4. vault-eso-setup.sh         ← Existing: ESO KV + policy
5. dex-setup.sh               ← Existing: Dex container (TLS cert from Vault PKI)
6. Per-region loop:
   - RustFS container (now with step-ca TLS cert)
   - Kind cluster creation
   - MetalLB + kube-proxy
   - step-ca wiring (Service/Endpoints)    ← NEW
   - Vault wiring (Service/Endpoints)
   - trust-manager Helm install + Bundle   ← NEW
   - cert-manager + ClusterIssuer
   - ESO + ClusterSecretStore
   - Traefik
7. vault-oidc-setup.sh        ← Existing: OIDC auth via Dex
8. step-ca OIDC provisioner   ← NEW: enable after Dex is running
9. RustFS secrets distribution
```

## Script Structure

| Script | Status | Responsibility |
|---|---|---|
| `scripts/step-ca-setup.sh` | **New** | step-ca container deployment, PKI initialization, provisioner setup (JWK + X5C), admin secret generation |
| `scripts/vault-pki-setup.sh` | **Modified** | Add step-ca as signer for Vault intermediate; re-init Vault PKI under step-ca hierarchy; request Vault API TLS cert from step-ca |
| `scripts/vault-setup.sh` | **Modified** | Request Vault TLS cert from step-ca instead of using dev-TLS auto-generation |
| `scripts/setup.sh` | **Modified** | Insert step-ca-setup.sh before vault-setup.sh; add step-ca wiring + trust-manager in per-region loop; add OIDC provisioner step after Dex |
| `scripts/step-ca-renew-intermediate.sh` | **New** | Semi-automated script: prompts for root key password, re-signs step-ca intermediate, restarts step-ca |
| `scripts/vault-renew-intermediate.sh` | **New** | Scripted process: generate CSR from Vault, submit to step-ca, import signed cert back |

## New Directory Structure

```
step-ca/
├── config/
│   └── ca.json.tpl          ← step-ca configuration template
├── pki/
│   ├── root.crt             ← Root CA certificate (on disk)
│   └── intermediate.crt     ← Intermediate CA certificate + chain
├── secrets/
│   ├── .root_password       ← Encrypted root key password
│   └── .provisioner_jwk     ← Encrypted JWK provisioner key
├── traefik/
│   └── service.yaml.tpl     ← K8s Service/Endpoints wiring step-ca into clusters
└── cert-manager/
    └── step-ca-issuer.yaml.tpl  ← (optional) step-ca issuer for cert-manager
```

## Migration Strategy

The entire playground is **recreated from scratch**. No in-place migration of existing certificates — the old Vault PKI hierarchy is torn down and all certificates are re-issued from the new step-ca-rooted hierarchy.

## Open Items

- **Monitoring mTLS cert distribution:** Exact combination of cert-manager CRs vs Helm chart values to be investigated during implementation based on native chart support
- **Offline root:** Not implemented now (standalone mode). Can be added later by separating root and intermediate CA keys
