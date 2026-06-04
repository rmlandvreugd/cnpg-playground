# Plan: Split PKI — Vault PKI for In-Cluster Only, step-ca Intermediate for External Services

> **Status:** Draft  
> **Scope:** Restructure PKI so Vault PKI only signs Kubernetes-internal certificates, while step-ca intermediate CA signs certificates for services running outside the cluster (Vault, Dex).

---

## 1. Current State

```
step-ca Root CA (offline-capable, 10yr)
  └── step-ca Intermediate CA 1 (5yr, pathlen:1)
       └── Vault PKI Intermediate CA 2 (5yr, pathlen:0)
            │
            ├── dex-server role ──→ Dex TLS (direct Vault issue, host files)
            │
            └── cluster-certs role ──→ cert-manager ClusterIssuer "vault-pki"
                                         │
                                         ├── PostgreSQL server/replication certs
                                         ├── PgBouncer client/server certs
                                         ├── Traefik dashboard cert
                                         ├── Barman Cloud Plugin certs
                                         └── mTLS client certs

Vault TLS cert: signed by step-ca intermediate via `step ca certificate` (JWK provisioner)
```

**Problem:** Vault PKI signs both in-cluster and external certificates. Dex's TLS cert is issued by Vault PKI's `dex-server` role, but Dex runs outside the cluster as a Docker container. This conflates two trust domains.

---

## 2. Target State

```
step-ca Root CA (offline-capable, 10yr)
  └── step-ca Intermediate CA 1 (5yr, pathlen:1)
       ├── Vault TLS cert (X5C provisioner, host files)
       ├── Dex TLS cert (X5C provisioner, host files)
       │
       └── Vault PKI Intermediate CA 2 (5yr, pathlen:0)
            │
            └── cluster-certs / mtls-client roles ──→ cert-manager ClusterIssuer "vault-pki"
                                                       │
                                                       ├── PostgreSQL server/replication certs
                                                       ├── PgBouncer client/server certs
                                                       ├── Traefik dashboard cert
                                                       ├── Barman Cloud Plugin certs
                                                       └── mTLS client certs
```

**Key principle:** Vault PKI = in-cluster workloads only. step-ca intermediate = external services (host containers).

---

## 3. Changes by File

### 3.1 `scripts/step-ca-setup.sh`

**Change:** No changes needed. The X5C provisioner already exists (added at lines 276-284). The intermediate CA key is already accessible at `step-ca/secrets/intermediate_ca_key`.

### 3.2 `scripts/vault-setup.sh`

**Change:** Switch Vault TLS cert issuance from JWK provisioner to X5C provisioner.

**Current flow (lines 66-93):**
```bash
step ca certificate "${VAULT_HOST}" /tmp/vault-cert.pem /tmp/vault-key.pem \
    --provisioner "${STEP_CA_PROVISIONER_NAME}" \
    --password-file /home/step/secrets/password \
    --ca-url "https://localhost:${STEP_CA_PORT}" \
    --root /home/step/certs/root_ca.crt \
    --san "${VAULT_HOST}" --san "vault" --san "localhost" \
    --san "vault.vault.svc.cluster.local" \
    --san "${HOST_IP}" --san "127.0.0.1" \
    --not-after 720h --force
```

**New flow:**
```bash
# Define step-ca external address (same pattern as VAULT_HOST/DEX_HOST)
HOST_IP=$(hostname -I | awk '{print $1}')
HOST_IP_DASHED=$(echo "$HOST_IP" | tr '.' '-')
STEP_CA_HOST="step-ca.${HOST_IP_DASHED}.sslip.io"

# Copy intermediate CA cert+key into step-ca container for X5C signing
${CONTAINER_PROVIDER} cp "${STEP_CA_PKI_DIR}/intermediate_ca.crt" "${STEP_CA_CONTAINER_NAME}:/tmp/intermediate_ca.crt"
${CONTAINER_PROVIDER} cp "${STEP_CA_SECRETS_DIR}/intermediate_ca_key" "${STEP_CA_CONTAINER_NAME}:/tmp/intermediate_ca_key"

${CONTAINER_PROVIDER} exec \
    -e STEPPATH=/home/step \
    "${STEP_CA_CONTAINER_NAME}" \
    step ca certificate "${VAULT_HOST}" /tmp/vault-cert.pem /tmp/vault-key.pem \
    --provisioner x5c-provisioner \
    --x5c-cert /tmp/intermediate_ca.crt \
    --x5c-key /tmp/intermediate_ca_key \
    --x5c-chain /tmp/intermediate_ca.crt \
    --password-file /home/step/secrets/password \
    --ca-url "https://${STEP_CA_HOST}:${STEP_CA_PORT}" \
    --root /home/step/certs/root_ca.crt \
    --san "${VAULT_HOST}" --san "vault" --san "localhost" \
    --san "vault.vault.svc.cluster.local" \
    --san "${HOST_IP}" --san "127.0.0.1" \
    --not-after 720h --force

# Copy cert and key from step-ca container to host
VAULT_CERT_TMPDIR=$(mktemp -d)
${CONTAINER_PROVIDER} cp "${STEP_CA_CONTAINER_NAME}:/tmp/vault-cert.pem" "${VAULT_CERT_TMPDIR}/vault-cert.pem"
${CONTAINER_PROVIDER} cp "${STEP_CA_CONTAINER_NAME}:/tmp/vault-key.pem" "${VAULT_CERT_TMPDIR}/vault-key.pem"
sudo cp "${VAULT_CERT_TMPDIR}/vault-cert.pem" "${VAULT_CERT_DIR}/vault-cert.pem"
sudo cp "${VAULT_CERT_TMPDIR}/vault-key.pem" "${VAULT_CERT_DIR}/vault-key.pem"
rm -rf "${VAULT_CERT_TMPDIR}"

# Clean up intermediate CA key and cert files from container
${CONTAINER_PROVIDER} exec "${STEP_CA_CONTAINER_NAME}" rm -f /tmp/intermediate_ca.crt /tmp/intermediate_ca_key /tmp/vault-cert.pem /tmp/vault-key.pem
```

**Rationale:** Using X5C provisioner with the intermediate CA cert+key means the certificate is signed by the step-ca intermediate CA (not the root), producing a shorter chain: `leaf → step-ca Int CA 1 → step-ca Root CA`. This is consistent with how Dex will also be signed. The `--ca-url` uses the external sslip.io address (`https://step-ca.<HOST_IP_DASHED>.sslip.io:8443`) rather than localhost, since the step-ca container is connected to the kind network and can resolve the sslip.io address.

### 3.3 `scripts/dex-setup.sh`

**Change:** Replace Vault PKI issuance with step-ca X5C issuance.

**Current flow (lines 54-71):**
```bash
CERT_JSON=$(_vcmd write -format=json pki_int/issue/dex-server \
    common_name="${DEX_HOST}" \
    alt_names="dex,localhost" \
    ip_sans="${HOST_IP},127.0.0.1")
# ... extracts cert, key, ca_chain from Vault JSON response
```

**New flow:**
```bash
# Define step-ca external address (same pattern as VAULT_HOST/DEX_HOST)
HOST_IP=$(hostname -I | awk '{print $1}')
HOST_IP_DASHED=$(echo "$HOST_IP" | tr '.' '-')
STEP_CA_HOST="step-ca.${HOST_IP_DASHED}.sslip.io"
STEP_CA_PKI_DIR="${GIT_REPO_ROOT}/step-ca/pki"
STEP_CA_SECRETS_DIR="${GIT_REPO_ROOT}/step-ca/secrets"

# Copy intermediate CA cert+key into step-ca container for X5C signing
${CONTAINER_PROVIDER} cp "${STEP_CA_PKI_DIR}/intermediate_ca.crt" "${STEP_CA_CONTAINER_NAME}:/tmp/intermediate_ca.crt"
${CONTAINER_PROVIDER} cp "${STEP_CA_SECRETS_DIR}/intermediate_ca_key" "${STEP_CA_CONTAINER_NAME}:/tmp/intermediate_ca_key"

# Issue Dex TLS cert from step-ca intermediate via X5C provisioner
${CONTAINER_PROVIDER} exec \
    -e STEPPATH=/home/step \
    "${STEP_CA_CONTAINER_NAME}" \
    step ca certificate "${DEX_HOST}" /tmp/dex-cert.pem /tmp/dex-key.pem \
    --provisioner x5c-provisioner \
    --x5c-cert /tmp/intermediate_ca.crt \
    --x5c-key /tmp/intermediate_ca_key \
    --x5c-chain /tmp/intermediate_ca.crt \
    --password-file /home/step/secrets/password \
    --ca-url "https://${STEP_CA_HOST}:${STEP_CA_PORT}" \
    --root /home/step/certs/root_ca.crt \
    --san "dex" --san "localhost" \
    --san "${HOST_IP}" --san "127.0.0.1" \
    --not-after 720h --force

# Copy cert and key from step-ca container to host
${CONTAINER_PROVIDER} cp "${STEP_CA_CONTAINER_NAME}:/tmp/dex-cert.pem" "${DEX_TLS_DIR}/dex.crt"
${CONTAINER_PROVIDER} cp "${STEP_CA_CONTAINER_NAME}:/tmp/dex-key.pem" "${DEX_TLS_DIR}/dex.key"

# Build CA chain: step-ca intermediate + step-ca root
sudo cat "${STEP_CA_PKI_DIR}/intermediate_ca.crt" "${STEP_CA_PKI_DIR}/root_ca.crt" \
    | sudo tee "${DEX_TLS_DIR}/ca-chain.pem" > /dev/null
sudo cat "${STEP_CA_PKI_DIR}/intermediate_ca.crt" "${STEP_CA_PKI_DIR}/root_ca.crt" \
    | sudo tee "${DEX_TLS_DIR}/ca.crt" > /dev/null
# Append CA chain to the leaf cert for full chain verification
sudo bash -c "cat '${STEP_CA_PKI_DIR}/intermediate_ca.crt' '${STEP_CA_PKI_DIR}/root_ca.crt' >> '${DEX_TLS_DIR}/dex.crt'"

# Clean up intermediate CA key and cert files from container
${CONTAINER_PROVIDER} exec "${STEP_CA_CONTAINER_NAME}" rm -f /tmp/intermediate_ca.crt /tmp/intermediate_ca_key /tmp/dex-cert.pem /tmp/dex-key.pem

sudo chmod 644 "${DEX_TLS_DIR}/dex.crt" "${DEX_TLS_DIR}/ca.crt" "${DEX_TLS_DIR}/ca-chain.pem"
sudo chmod 640 "${DEX_TLS_DIR}/dex.key"
```

**Key differences:**
- No longer calls Vault PKI (`_vcmd write pki_int/issue/dex-server`)
- Uses `step ca certificate` with X5C provisioner inside the step-ca container
- CA chain is now `step-ca Int CA 1 + step-ca Root CA` (2 certs) instead of `Vault Int CA 2 + step-ca Int CA 1 + step-ca Root CA` (3 certs)
- Dex no longer needs Vault running to get its cert (only needs step-ca)
- The `_vcmd` helper function and `ROOT_TOKEN` variable become dead code and should be removed from `dex-setup.sh`

### 3.4 `scripts/vault-pki-setup.sh`

**Change:** Remove the `dex-server` PKI role.

**Remove lines ~120-125:**
```bash
_vcmd write pki_int/roles/dex-server \
    allowed_domains="sslip.io,dex,localhost" \
    allow_subdomains=true allow_bare_domains=true \
    allow_ip_sans=true max_ttl=720h \
    not_before_duration=0s \
    require_cn=false
```

**Rationale:** Dex no longer uses Vault PKI. The role is unused after the migration.

### 3.5 `scripts/setup.sh`

**Change:** Add a new `step-ca-external-bundle` trust-manager Bundle.

**Add after the existing bundle creation (around line 255):**

Create a new template file `step-ca/trust-manager/bundle-external.yaml.tpl`:
```yaml
apiVersion: trust.cert-manager.io/v1alpha1
kind: Bundle
metadata:
  name: step-ca-external-bundle
spec:
  sources:
    - configMap:
        name: step-ca-roots
        key: ca-certificates.crt
  target:
    configMap:
      key: ca-certificates.crt
    secret:
      key: ca.crt
```

**Note:** This bundle contains the same CA certs as `step-ca-bundle` (Root CA + Int CA 1). The distinction is semantic: `step-ca-bundle` is the general-purpose root+intermediate bundle, while `step-ca-external-bundle` is specifically for verifying certificates signed by the step-ca intermediate (external services). They can be consolidated later if desired, but having separate bundles makes the trust domain intent clear.

**In `scripts/setup.sh`, add after the vault-pki-bundle section:**
```bash
# Apply step-ca-external-bundle for verifying external service certs
# (signed by step-ca intermediate, not Vault PKI)
echo "📋 Applying step-ca-external trust-manager Bundle..."
kubectl apply --context "${CONTEXT_NAME}" -f \
    "${GIT_REPO_ROOT}/step-ca/trust-manager/bundle-external.yaml"
kubectl wait --context "${CONTEXT_NAME}" --timeout=60s \
    --for=condition=Synced bundle/step-ca-external-bundle
```

### 3.6 `vault/trust-manager/bundle.yaml.tpl`

**No changes.** The `vault-pki-bundle` continues to distribute the full chain (Root + Int CA 1 + Int CA 2) for in-cluster workload verification. This is correct because in-cluster certs are still signed by Vault PKI.

### 3.7 `step-ca/trust-manager/bundle.yaml.tpl`

**No changes.** The `step-ca-bundle` continues to distribute Root + Int CA 1.

### 3.8 New file: `step-ca/trust-manager/bundle-external.yaml`

**Create new file** (non-templated, since it only references the existing `step-ca-roots` ConfigMap):
```yaml
apiVersion: trust.cert-manager.io/v1alpha1
kind: Bundle
metadata:
  name: step-ca-external-bundle
  namespace: cert-manager
spec:
  sources:
    - configMap:
        name: step-ca-roots
        key: ca-certificates.crt
  target:
    configMap:
      key: ca-certificates.crt
    secret:
      key: ca.crt
```

### 3.9 `demo/setup.sh`

**No changes.** The barman-cloud certificate fix (applying certs before helm install) is already in place. All demo certificates use `vault-pki` ClusterIssuer, which is correct for in-cluster workloads.

### 3.10 `monitoring/setup.sh` and self-service scripts

**No changes.** The Grafana RBR-verification cert (`grafana-rbr-ver-cert`) uses `vault-pki` ClusterIssuer — correct for in-cluster workloads.

---

## 4. Trust Chain Comparison

### Before (current)

| Service | Signed By | Chain Depth |
|---------|-----------|-------------|
| Vault TLS | step-ca Int CA 1 (JWK) | leaf → Int1 → Root (3 certs) |
| Dex TLS | Vault PKI Int CA 2 (dex-server role) | leaf → Int2 → Int1 → Root (4 certs) |
| In-cluster certs | Vault PKI Int CA 2 (cluster-certs role) | leaf → Int2 → Int1 → Root (4 certs) |

### After (target)

| Service | Signed By | Chain Depth |
|---------|-----------|-------------|
| Vault TLS | step-ca Int CA 1 (X5C provisioner) | leaf → Int1 → Root (3 certs) |
| Dex TLS | step-ca Int CA 1 (X5C provisioner) | leaf → Int1 → Root (3 certs) |
| In-cluster certs | Vault PKI Int CA 2 (cluster-certs role) | leaf → Int2 → Int1 → Root (4 certs) |

**Improvement:** External services now have a shorter chain (3 vs 4 certs for Dex). Vault's chain stays at 3 but uses X5C instead of JWK for consistency.

---

## 5. Trust Bundle Distribution

| Bundle | Contents | Purpose | Namespaces |
|--------|----------|---------|------------|
| `step-ca-bundle` | Root CA + Int CA 1 | General step-ca trust | All |
| `step-ca-external-bundle` | Root CA + Int CA 1 | Verify external service certs (Vault, Dex) | All |
| `vault-pki-bundle` | Root CA + Int CA 1 + Int CA 2 | Verify in-cluster certs (CNPG, PgBouncer, etc.) | All |

**Note:** `step-ca-bundle` and `step-ca-external-bundle` contain identical CA certs. They are separate Bundle resources for semantic clarity. If desired, they can be consolidated into one in the future.

---

## 6. Bootstrap Order Changes

### Before
```
1. step-ca-setup.sh    → Root CA + Int CA 1 + X5C provisioner
2. vault-setup.sh      → Vault TLS cert (JWK provisioner) → start Vault
3. vault-pki-setup.sh  → PKI engine, sign CSR, create roles (including dex-server)
4. dex-setup.sh        → Dex TLS cert from Vault PKI (dex-server role)
5. setup.sh (per K8s)  → ClusterIssuer, trust bundles, cert-manager certs
```

### After
```
1. step-ca-setup.sh    → Root CA + Int CA 1 + X5C provisioner (unchanged)
2. vault-setup.sh      → Vault TLS cert (X5C provisioner, --ca-url uses sslip.io) → start Vault
3. vault-pki-setup.sh  → PKI engine, sign CSR, create roles (dex-server REMOVED)
4. dex-setup.sh        → Dex TLS cert from step-ca (X5C provisioner, --ca-url uses sslip.io)
5. setup.sh (per K8s)  → ClusterIssuer, trust bundles (incl. step-ca-external-bundle), cert-manager certs
```

**Key dependency change:** Dex no longer depends on Vault being running. It only needs step-ca. This means Dex can start before Vault if needed. Both Vault and Dex now use the X5C provisioner with `--ca-url https://step-ca.<HOST_IP_DASHED>.sslip.io:8443` (the external-facing sslip.io address) instead of localhost, since the step-ca container is connected to the kind network and can resolve sslip.io hostnames.

---

## 7. Certificate Renewal

| Certificate | TTL | Renewal Method |
|-------------|-----|---------------|
| Vault TLS | 720h (30d) | Manual: re-run `vault-setup.sh` or `step ca renew` |
| Dex TLS | 720h (30d) | Manual: re-run `dex-setup.sh` or `step ca renew` |
| In-cluster certs | 720h/168h | Automatic: cert-manager via `vault-pki` ClusterIssuer |

For a playground environment, manual renewal is acceptable. Production would use cert-manager with a step-ca ClusterIssuer or automated renewal scripts.

---

## 8. Documentation Updates

### 8.1 `docs/pki-architecture.md` — Full rewrite

Update the entire document to reflect:

1. **Section 1 (Overzicht):** Update the hierarchy diagram to show the split:
   - step-ca Int CA 1 → signs Vault TLS, Dex TLS (external services)
   - step-ca Int CA 1 → signs Vault PKI Int CA 2
   - Vault PKI Int CA 2 → signs all in-cluster certs

2. **Section 2.1 (step-ca):** Update "Gebruik" to include signing external service certs (Vault, Dex) via X5C provisioner, not just Vault TLS + intermediate signing.

3. **Section 2.2 (Vault):** Remove `dex-server` role from the roles table. Add note that Vault PKI is now exclusively for in-cluster workloads.

4. **Section 2.4 (trust-manager):** Add `step-ca-external-bundle` to the bundle table with its purpose.

5. **Section 3.1 (Integratie met Kubernetes):** Update the architecture diagram to show Dex and Vault outside the Vault PKI box.

6. **Section 4.1 (Bootstrap-volgorde):** Update to reflect new order (Dex no longer depends on Vault).

7. **Section 4.2 (Certificaatverlenging):** Add rows for Vault TLS and Dex TLS with manual renewal method.

8. **Section 5.2 (Least-privilege):** Remove `dex-server` role reference.

9. **Section 8 (Samenvatting):** Update to mention the trust domain separation.

### 8.2 `docs/plan-barman-cert-manager-tls.md` — Minor update

Add a note that barman-cloud certs use `vault-pki` ClusterIssuer (in-cluster), which is correct per the new PKI split. No functional changes needed.

### 8.3 `docs/plan-ingressroute-tcp-mtls.md` — Minor update

Update the CA chain diagram to show that external-facing certs (Dex, Vault) are now signed by step-ca intermediate, while in-cluster mTLS certs remain on Vault PKI. The mTLS architecture for PostgreSQL access is unchanged.

### 8.4 `vault/codemap.md` — Update

Update the PKI hierarchy description to note that Vault PKI is now exclusively for in-cluster workloads, and that external services (Dex, Vault itself) use step-ca intermediate directly.

---

## 9. Implementation Order

1. **Create `step-ca/trust-manager/bundle-external.yaml`** — New trust-manager Bundle resource
2. **Update `scripts/vault-setup.sh`** — Switch from JWK to X5C provisioner
3. **Update `scripts/dex-setup.sh`** — Replace Vault PKI issuance with step-ca X5C issuance; remove `_vcmd` helper function and `ROOT_TOKEN` variable (now dead code); add `STEP_CA_PKI_DIR` and `STEP_CA_SECRETS_DIR` variable definitions
4. **Update `scripts/vault-pki-setup.sh`** — Remove `dex-server` role
5. **Update `scripts/setup.sh`** — Add `step-ca-external-bundle` application
6. **Update `docs/pki-architecture.md`** — Full rewrite per section 8.1
7. **Update `docs/plan-barman-cert-manager-tls.md`** — Minor note per section 8.2
8. **Update `docs/plan-ingressroute-tcp-mtls.md`** — Update CA chain diagram per section 8.3
9. **Update `vault/codemap.md`** — Update PKI description per section 8.4
10. **Test:** Run `./scripts/setup.sh local` then `./demo/setup.sh` and verify all certs

---

## 10. Verification Steps

After implementation, verify:

```bash
# 1. Check Vault TLS cert chain (should be: leaf → Int1 → Root, signed by step-ca Int1 via X5C)
#    Uses the external sslip.io address, same as --ca-url in the issuance commands
echo | openssl s_client -connect vault.${HOST_IP_DASHED}.sslip.io:8200 -showcerts 2>/dev/null \
  | openssl x509 -noout -issuer -subject

# 2. Check Dex TLS cert chain (should be: leaf → Int1 → Root, signed by step-ca Int1 via X5C)
echo | openssl s_client -connect dex.${HOST_IP_DASHED}.sslip.io:5556 -showcerts 2>/dev/null \
  | openssl x509 -noout -issuer -subject

# 3. Check in-cluster cert chain (should be: leaf → Int2 → Int1 → Root, signed by Vault PKI)
kubectl --context kind-k8s-local -n cnpg-system get certificate barman-cloud-server -o yaml

# 4. Verify trust bundles are synced
kubectl --context kind-k8s-local get bundle

# 5. Verify dex-server role is gone from Vault
docker exec vault vault read pki_int/roles/dex-server 2>&1 | grep "no role at"

# 6. Verify Dex is healthy (using the external sslip.io address)
curl -sf --cacert dex/tls/ca-chain.pem https://dex.${HOST_IP_DASHED}.sslip.io:5556/dex/.well-known/openid-configuration

# 7. Verify step-ca X5C provisioner is listed
docker exec -e STEPPATH=/home/step step-ca step ca provisioner list | grep x5c-provisioner
```