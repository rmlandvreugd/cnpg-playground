#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

VAULT_DIR="${GIT_REPO_ROOT}/vault"
VAULT_PKI_DIR="${VAULT_DIR}/pki"
STEP_CA_DIR="${GIT_REPO_ROOT}/step-ca"
STEP_CA_PKI_DIR="${STEP_CA_DIR}/pki"
STEP_CA_SECRETS_DIR="${STEP_CA_DIR}/secrets"

echo "🔐 Bootstrapping Vault PKI (signed by step-ca)..."

ROOT_TOKEN=$(sudo cat "${VAULT_DIR}/.root_token")

_vcmd() {
    ${CONTAINER_PROVIDER} exec \
        -e VAULT_ADDR="https://127.0.0.1:${VAULT_PORT}" \
        -e VAULT_CACERT=/vault/certs/vault-ca.pem \
        -e VAULT_TOKEN="${ROOT_TOKEN}" \
        "${VAULT_CONTAINER_NAME}" \
        vault "$@"
}
_vcmd_stdin() {
    ${CONTAINER_PROVIDER} exec -i \
        -e VAULT_ADDR="https://127.0.0.1:${VAULT_PORT}" \
        -e VAULT_CACERT=/vault/certs/vault-ca.pem \
        -e VAULT_TOKEN="${ROOT_TOKEN}" \
        "${VAULT_CONTAINER_NAME}" \
        vault "$@"
}

_scmd() {
    ${CONTAINER_PROVIDER} exec \
        -e STEPPATH=/home/step \
        "${STEP_CA_CONTAINER_NAME}" \
        step "$@"
}

sudo mkdir -p "${VAULT_PKI_DIR}"

# --- Root PKI engine (kept for CA chain serving, no longer generates its own root) ---
echo "📜 Enabling root PKI engine (serves step-ca root chain)..."
_vcmd secrets enable pki
_vcmd secrets tune -max-lease-ttl=87600h pki

# Import the step-ca root certificate into Vault's pki/ engine
# so that Vault can serve the full CA chain to clients
STEP_CA_ROOT_CERT=$(sudo cat "${STEP_CA_PKI_DIR}/root_ca.crt")
echo "${STEP_CA_ROOT_CERT}" | sudo tee "${VAULT_PKI_DIR}/root.crt" > /dev/null
sudo chmod 644 "${VAULT_PKI_DIR}/root.crt"

_vcmd write pki/config/urls \
    issuing_certificates="https://127.0.0.1:${VAULT_PORT}/v1/pki/ca" \
    crl_distribution_points="https://127.0.0.1:${VAULT_PORT}/v1/pki/crl"

# --- Intermediate PKI engine (signed by step-ca) ---
echo "📜 Enabling intermediate PKI engine..."
_vcmd secrets enable -path=pki_int pki
_vcmd secrets tune -max-lease-ttl=43800h pki_int

# Generate CSR from Vault's intermediate CA
CSR=$(_vcmd write -field=csr pki_int/intermediate/generate/internal \
    common_name="CloudNativePG Playground Intermediate CA" \
    key_type=rsa key_bits=2048)

# Sign the CSR with step-ca (instead of Vault's own root)
echo "📜 Signing Vault intermediate CSR with step-ca..."
# Write CSR to a temp file inside the step-ca container
CSR_FILE=$(mktemp)
echo "${CSR}" > "${CSR_FILE}"

# Copy CSR into step-ca container and sign it
${CONTAINER_PROVIDER} cp "${CSR_FILE}" "${STEP_CA_CONTAINER_NAME}:/tmp/vault-intermediate.csr"
rm -f "${CSR_FILE}"

# Sign and write output to a file to avoid stdout capture issues
_scmd ca sign /tmp/vault-intermediate.csr \
    --provisioner "${STEP_CA_PROVISIONER_NAME}" \
    --password-file /home/step/secrets/password \
    --ca-url "https://127.0.0.1:${STEP_CA_PORT}" \
    --root /home/step/certs/root_ca.crt \
    --profile intermediate-ca \
    --not-after 43800h \
    --force \
    --output-file /tmp/vault-intermediate-signed.crt

# Copy signed cert back to host
${CONTAINER_PROVIDER} cp "${STEP_CA_CONTAINER_NAME}:/tmp/vault-intermediate-signed.crt" "${VAULT_PKI_DIR}/.signed.tmp"
SIGNED=$(sudo cat "${VAULT_PKI_DIR}/.signed.tmp")
sudo rm -f "${VAULT_PKI_DIR}/.signed.tmp"

# Clean up from step-ca container
${CONTAINER_PROVIDER} exec "${STEP_CA_CONTAINER_NAME}" rm -f /tmp/vault-intermediate.csr /tmp/vault-intermediate-signed.crt

# Build the full certificate chain (intermediate + root)
STEP_CA_ROOT_PEM=$(sudo cat "${STEP_CA_PKI_DIR}/root_ca.crt")
SIGNED_WITH_CHAIN="${SIGNED}
${STEP_CA_ROOT_PEM}"

echo "${SIGNED_WITH_CHAIN}" | sudo tee "${VAULT_PKI_DIR}/intermediate.crt" > /dev/null
sudo chmod 644 "${VAULT_PKI_DIR}/intermediate.crt"

# Set the signed intermediate in Vault
_vcmd write pki_int/intermediate/set-signed certificate="${SIGNED_WITH_CHAIN}"

_vcmd write pki_int/config/urls \
    issuing_certificates="https://127.0.0.1:${VAULT_PORT}/v1/pki_int/ca" \
    crl_distribution_points="https://127.0.0.1:${VAULT_PORT}/v1/pki_int/crl"

# --- Issuance roles ---
echo "📋 Creating PKI roles..."
_vcmd write pki_int/roles/dex-server \
    allowed_domains="sslip.io,dex,localhost" \
    allow_subdomains=true allow_bare_domains=true \
    allow_ip_sans=true max_ttl=720h \
    require_cn=false

_vcmd write pki_int/roles/cluster-certs \
    allowed_domains="sslip.io,cluster.local" \
    allow_subdomains=true allow_bare_domains=true \
    allow_ip_sans=true max_ttl=720h \
    require_cn=false

# mTLS client role for in-cluster mutual TLS
_vcmd write pki_int/roles/mtls-client \
    allowed_domains="sslip.io,cluster.local" \
    allow_subdomains=true allow_bare_domains=true \
    allow_ip_sans=true max_ttl=168h \
    client_flag=true server_flag=false \
    require_cn=false

# --- cert-manager policy ---
echo "📋 Creating cert-manager policy..."
cat <<'EOF' | _vcmd_stdin policy write cert-manager -
path "pki_int/sign/cluster-certs"  { capabilities = ["create","update"] }
path "pki_int/issue/cluster-certs" { capabilities = ["create","update"] }
path "pki_int/sign/mtls-client"    { capabilities = ["create","update"] }
path "pki_int/issue/mtls-client"   { capabilities = ["create","update"] }
path "pki_int/cert/ca"             { capabilities = ["read"] }
path "pki/cert/ca"                 { capabilities = ["read"] }
path "pki_int/certs"               { capabilities = ["list"] }
EOF

# --- AppRole for cert-manager ---
echo "🔑 Creating cert-manager AppRole..."
_vcmd auth enable approle
_vcmd write auth/approle/role/cert-manager \
    token_policies=cert-manager secret_id_ttl=0

ROLE_ID=$(_vcmd read  -field=role_id   auth/approle/role/cert-manager/role-id)
SECRET_ID=$(_vcmd write -field=secret_id -f auth/approle/role/cert-manager/secret-id)

echo "${ROLE_ID}"   | sudo tee "${VAULT_DIR}/.approle_role_id"   > /dev/null
echo "${SECRET_ID}" | sudo tee "${VAULT_DIR}/.approle_secret_id" > /dev/null
sudo chmod 600 "${VAULT_DIR}/.approle_role_id" "${VAULT_DIR}/.approle_secret_id"

echo "✅ Vault PKI ready (signed by step-ca). AppRole role_id: ${ROLE_ID}"
