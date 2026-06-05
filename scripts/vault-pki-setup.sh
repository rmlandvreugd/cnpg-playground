#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

VAULT_DIR="${GIT_REPO_ROOT}/vault"
VAULT_PKI_DIR="${VAULT_DIR}/pki"
STEP_CA_DIR="${GIT_REPO_ROOT}/step-ca"
STEP_CA_PKI_DIR="${STEP_CA_DIR}/pki"
STEP_CA_SECRETS_DIR="${STEP_CA_DIR}/secrets"

HOST_IP=$(hostname -I | awk '{print $1}')
HOST_IP_DASHED=$(echo "$HOST_IP" | tr '.' '-')
VAULT_HOST="vault.${HOST_IP_DASHED}.sslip.io"

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
    issuing_certificates="https://${VAULT_HOST}:${VAULT_PORT}/v1/pki/ca" \
    crl_distribution_points="https://${VAULT_HOST}:${VAULT_PORT}/v1/pki/crl"

# --- Intermediate PKI engine (signed by step-ca) ---
echo "📜 Enabling intermediate PKI engine..."
_vcmd secrets enable -path=pki_int pki
_vcmd secrets tune -max-lease-ttl=43800h pki_int

# Generate CSR from Vault's intermediate CA
CSR=$(_vcmd write -field=csr pki_int/intermediate/generate/internal \
    common_name="CloudNativePG Playground Intermediate CA" \
    key_type=rsa key_bits=2048)

# Sign the CSR with step-ca's intermediate CA key using openssl on the host
# (step certificate sign requires a TTY which isn't available in docker exec)
echo "📜 Signing Vault intermediate CSR with step-ca..."
CSR_FILE=$(mktemp)
echo "${CSR}" > "${CSR_FILE}"

# Copy intermediate CA cert, key, and password from step-ca container
STEP_CA_INTERMEDIATE_CERT_TMPFILE=$(mktemp)
STEP_CA_KEY_TMPFILE=$(mktemp)
STEP_CA_EXT_TMPFILE=$(mktemp)
docker exec "${STEP_CA_CONTAINER_NAME}" cat /home/step/certs/intermediate_ca.crt > "${STEP_CA_INTERMEDIATE_CERT_TMPFILE}"
docker cp "${STEP_CA_CONTAINER_NAME}:/home/step/secrets/intermediate_ca_key" "${STEP_CA_KEY_TMPFILE}"
STEP_CA_PASSWORD=$(docker exec "${STEP_CA_CONTAINER_NAME}" cat /home/step/secrets/password)
printf "basicConstraints=critical,CA:TRUE,pathlen:0\nkeyUsage=critical,digitalSignature,keyCertSign,cRLSign" > "${STEP_CA_EXT_TMPFILE}"

# Sign the CSR with openssl (5 years = 1825 days)
SIGNED_TMPFILE=$(mktemp)
openssl x509 -req -in "${CSR_FILE}" \
    -CA "${STEP_CA_INTERMEDIATE_CERT_TMPFILE}" \
    -CAkey "${STEP_CA_KEY_TMPFILE}" \
    -CAcreateserial \
    -days 1825 \
    -passin "pass:${STEP_CA_PASSWORD}" \
    -extfile "${STEP_CA_EXT_TMPFILE}" \
    -out "${SIGNED_TMPFILE}" 2>&1

SIGNED=$(cat "${SIGNED_TMPFILE}")

# Clean up temp files
rm -f "${CSR_FILE}" "${STEP_CA_INTERMEDIATE_CERT_TMPFILE}" "${STEP_CA_KEY_TMPFILE}" "${STEP_CA_EXT_TMPFILE}" "${SIGNED_TMPFILE}"

# Build the full certificate chain (intermediate + root)
STEP_CA_ROOT_PEM=$(sudo cat "${STEP_CA_PKI_DIR}/root_ca.crt")
SIGNED_WITH_CHAIN="${SIGNED}
${STEP_CA_ROOT_PEM}"

echo "${SIGNED_WITH_CHAIN}" | sudo tee "${VAULT_PKI_DIR}/intermediate.crt" > /dev/null
sudo chmod 644 "${VAULT_PKI_DIR}/intermediate.crt"

# Set the signed intermediate in Vault
_vcmd write pki_int/intermediate/set-signed certificate="${SIGNED_WITH_CHAIN}"

_vcmd write pki_int/config/urls \
    issuing_certificates="https://${VAULT_HOST}:${VAULT_PORT}/v1/pki_int/ca" \
    crl_distribution_points="https://${VAULT_HOST}:${VAULT_PORT}/v1/pki_int/crl"

# --- Issuance roles ---
echo "📋 Creating PKI roles..."
_vcmd write pki_int/roles/cluster-certs \
    allowed_domains="sslip.io,cluster.local" \
    allow_subdomains=true allow_bare_domains=true \
    allow_any_name=true \
    allow_ip_sans=true max_ttl=720h \
    not_before_duration=0s \
    require_cn=false \
    key_type=ec key_bits=256 \
    enforce_hostnames=false
# Vault CLI cannot set cn_validations to empty array; use API to clear it
curl -s -X PUT \
    -H "X-Vault-Token: ${ROOT_TOKEN}" \
    -H "Content-Type: application/json" \
    --cacert "${VAULT_DIR}/certs/vault-ca.pem" \
    "https://127.0.0.1:${VAULT_PORT}/v1/pki_int/roles/cluster-certs" \
    -d '{
        "allowed_domains": "sslip.io,cluster.local",
        "allow_subdomains": true,
        "allow_bare_domains": true,
        "allow_any_name": true,
        "allow_ip_sans": true,
        "max_ttl": "720h",
        "not_before_duration": "0s",
        "require_cn": false,
        "key_type": "ec",
        "key_bits": 256,
        "cn_validations": [],
        "enforce_hostnames": false
    }' > /dev/null

# mTLS client role for in-cluster mutual TLS
_vcmd write pki_int/roles/mtls-client \
    allowed_domains="sslip.io,cluster.local" \
    allow_subdomains=true allow_bare_domains=true \
    allow_any_name=true \
    allow_ip_sans=true max_ttl=168h \
    not_before_duration=0s \
    client_flag=true server_flag=false \
    require_cn=false \
    key_type=ec key_bits=256 \
    enforce_hostnames=false
# Vault CLI cannot set cn_validations to empty array; use API to clear it
curl -s -X PUT \
    -H "X-Vault-Token: ${ROOT_TOKEN}" \
    -H "Content-Type: application/json" \
    --cacert "${VAULT_DIR}/certs/vault-ca.pem" \
    "https://127.0.0.1:${VAULT_PORT}/v1/pki_int/roles/mtls-client" \
    -d '{
        "allowed_domains": "sslip.io,cluster.local",
        "allow_subdomains": true,
        "allow_bare_domains": true,
        "allow_any_name": true,
        "allow_ip_sans": true,
        "max_ttl": "168h",
        "not_before_duration": "0s",
        "client_flag": true,
        "server_flag": false,
        "require_cn": false,
        "key_type": "ec",
        "key_bits": 256,
        "cn_validations": [],
        "enforce_hostnames": false
    }' > /dev/null

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
