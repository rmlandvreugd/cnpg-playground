#!/usr/bin/env bash
#
# Renew Vault's intermediate CA certificate (signed by step-ca).
# This script generates a new CSR from Vault's pki_int engine, signs it
# with step-ca's intermediate CA, and updates Vault with the new certificate.
#
# After renewal, any certificates issued by Vault's pki_int will chain
# through the new intermediate. Existing leaf certs remain valid until
# their own expiry.
#
# Copyright The CloudNativePG Contributors
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

VAULT_DIR="${GIT_REPO_ROOT}/vault"
VAULT_PKI_DIR="${VAULT_DIR}/pki"
STEP_CA_DIR="${GIT_REPO_ROOT}/step-ca"
STEP_CA_PKI_DIR="${STEP_CA_DIR}/pki"
STEP_CA_SECRETS_DIR="${STEP_CA_DIR}/secrets"

echo "🔄 Renewing Vault intermediate CA certificate..."

# --- Pre-flight checks ---
if ! ${CONTAINER_PROVIDER} ps --format '{{.Names}}' | grep -q "^${VAULT_CONTAINER_NAME}$"; then
    echo "❌ Error: Vault container '${VAULT_CONTAINER_NAME}' is not running."
    exit 1
fi

if ! ${CONTAINER_PROVIDER} ps --format '{{.Names}}' | grep -q "^${STEP_CA_CONTAINER_NAME}$"; then
    echo "❌ Error: step-ca container '${STEP_CA_CONTAINER_NAME}' is not running."
    exit 1
fi

ROOT_TOKEN=$(sudo cat "${VAULT_DIR}/.root_token")

_vcmd() {
    ${CONTAINER_PROVIDER} exec \
        -e VAULT_ADDR="https://127.0.0.1:${VAULT_PORT}" \
        -e VAULT_CACERT=/vault/certs/vault-ca.pem \
        -e VAULT_TOKEN="${ROOT_TOKEN}" \
        "${VAULT_CONTAINER_NAME}" \
        vault "$@"
}

# --- Show current intermediate certificate info ---
echo "📋 Current Vault intermediate CA certificate:"
_vcmd read -format=json pki_int/cert/ca 2>/dev/null | \
    jq -r '.data.certificate' | openssl x509 -noout -subject -dates -issuer 2>/dev/null || \
    echo "  (could not inspect current certificate)"

# --- Generate a new CSR from Vault's existing intermediate key ---
echo "📜 Generating new CSR from Vault's intermediate key..."
CSR=$(_vcmd write -field=csr pki_int/intermediate/generate/internal \
    common_name="CloudNativePG Playground Intermediate CA" \
    key_type=rsa key_bits=2048)

# --- Sign the CSR with step-ca's intermediate CA key using openssl ---
echo "📜 Signing new intermediate CSR with step-ca..."
CSR_FILE=$(mktemp)
echo "${CSR}" > "${CSR_FILE}"

# Copy intermediate CA cert, key, and password from step-ca container
STEP_CA_INTERMEDIATE_CERT_TMPFILE=$(mktemp)
STEP_CA_KEY_TMPFILE=$(mktemp)
STEP_CA_EXT_TMPFILE=$(mktemp)
${CONTAINER_PROVIDER} exec "${STEP_CA_CONTAINER_NAME}" cat /home/step/certs/intermediate_ca.crt > "${STEP_CA_INTERMEDIATE_CERT_TMPFILE}"
${CONTAINER_PROVIDER} cp "${STEP_CA_CONTAINER_NAME}:/home/step/secrets/intermediate_ca_key" "${STEP_CA_KEY_TMPFILE}"
STEP_CA_PASSWORD=$(${CONTAINER_PROVIDER} exec "${STEP_CA_CONTAINER_NAME}" cat /home/step/secrets/password)
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

# Build the full certificate chain (signed intermediate + step-ca root)
STEP_CA_ROOT_PEM=$(sudo cat "${STEP_CA_PKI_DIR}/root_ca.crt")
SIGNED_WITH_CHAIN="${SIGNED}
${STEP_CA_ROOT_PEM}"

# --- Backup the old certificate ---
BACKUP_DIR="${VAULT_PKI_DIR}/backups"
sudo mkdir -p "${BACKUP_DIR}"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
if [ -f "${VAULT_PKI_DIR}/intermediate.crt" ]; then
    sudo cp "${VAULT_PKI_DIR}/intermediate.crt" "${BACKUP_DIR}/intermediate.crt.${TIMESTAMP}"
    echo "📋 Backed up old certificate to ${BACKUP_DIR}/intermediate.crt.${TIMESTAMP}"
fi

# --- Update Vault with the new signed certificate ---
echo "🔄 Updating Vault with the new intermediate certificate..."
_vcmd write pki_int/intermediate/set-signed certificate="${SIGNED_WITH_CHAIN}"

# Save the new chain to disk
echo "${SIGNED_WITH_CHAIN}" | sudo tee "${VAULT_PKI_DIR}/intermediate.crt" > /dev/null
sudo chmod 644 "${VAULT_PKI_DIR}/intermediate.crt"

# --- Verify ---
echo "📋 New Vault intermediate CA certificate:"
_vcmd read -format=json pki_int/cert/ca 2>/dev/null | \
    jq -r '.data.certificate' | openssl x509 -noout -subject -dates -issuer 2>/dev/null || \
    echo "  (could not inspect new certificate)"

# --- Cleanup ---
rm -f "${CSR_FILE}" "${STEP_CA_INTERMEDIATE_CERT_TMPFILE}" "${STEP_CA_KEY_TMPFILE}" "${STEP_CA_EXT_TMPFILE}" "${SIGNED_TMPFILE}"

echo "✅ Vault intermediate CA certificate renewed successfully!"
echo "⚠️  Note: If Vault's own TLS certificate was also issued by step-ca,"
echo "   you may need to re-issue it with vault-setup.sh or manually."