#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

VAULT_DIR="${GIT_REPO_ROOT}/vault"
VAULT_PKI_DIR="${VAULT_DIR}/pki"

echo "🔐 Bootstrapping Vault PKI..."

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

sudo mkdir -p "${VAULT_PKI_DIR}"

# --- Root PKI engine ---
echo "📜 Enabling root PKI engine..."
_vcmd secrets enable pki
_vcmd secrets tune -max-lease-ttl=87600h pki

ROOT_CERT=$(_vcmd write -field=certificate pki/root/generate/internal \
    common_name="CloudNativePG Playground Root CA" ttl=87600h)
echo "${ROOT_CERT}" | sudo tee "${VAULT_PKI_DIR}/root.crt" > /dev/null
sudo chmod 644 "${VAULT_PKI_DIR}/root.crt"

_vcmd write pki/config/urls \
    issuing_certificates="https://127.0.0.1:${VAULT_PORT}/v1/pki/ca" \
    crl_distribution_points="https://127.0.0.1:${VAULT_PORT}/v1/pki/crl"

# --- Intermediate PKI engine ---
echo "📜 Enabling intermediate PKI engine..."
_vcmd secrets enable -path=pki_int pki
_vcmd secrets tune -max-lease-ttl=43800h pki_int

CSR=$(_vcmd write -field=csr pki_int/intermediate/generate/internal \
    common_name="CloudNativePG Playground Intermediate CA" \
    key_type=rsa key_bits=2048)

SIGNED=$(_vcmd write -field=certificate pki/root/sign-intermediate \
    csr="${CSR}" format=pem_bundle ttl=43800h)
echo "${SIGNED}" | sudo tee "${VAULT_PKI_DIR}/intermediate.crt" > /dev/null
sudo chmod 644 "${VAULT_PKI_DIR}/intermediate.crt"

_vcmd write pki_int/intermediate/set-signed certificate="${SIGNED}"

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

# --- cert-manager policy ---
echo "📋 Creating cert-manager policy..."
cat <<'EOF' | _vcmd_stdin policy write cert-manager -
path "pki_int/sign/cluster-certs"  { capabilities = ["create","update"] }
path "pki_int/issue/cluster-certs" { capabilities = ["create","update"] }
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

echo "✅ Vault PKI ready. AppRole role_id: ${ROLE_ID}"
