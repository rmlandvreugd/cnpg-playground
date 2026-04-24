#!/usr/bin/env bash
#
# This script deploys a standalone HashiCorp Vault container in "dev mode"
# with persistent storage and TLS, connected to the 'kind' Docker network.
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

# Source common configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

VAULT_DIR="${GIT_REPO_ROOT}/vault"
VAULT_CONFIG_DIR="${VAULT_DIR}/config"
VAULT_DATA_DIR="${VAULT_DIR}/data"
VAULT_LOG_DIR="${VAULT_DIR}/logs"
VAULT_CERT_DIR="${VAULT_DIR}/certs"

echo "🚀 Setting up Vault container..."

# Pull the image
echo "📦 Pulling Vault image..."
${CONTAINER_PROVIDER} pull "${VAULT_IMAGE}"

# Stop and remove existing container if it exists
if ${CONTAINER_PROVIDER} ps -a --format '{{.Names}}' | grep -q "^${VAULT_CONTAINER_NAME}$"; then
    echo "🗑️ Stopping and removing existing ${VAULT_CONTAINER_NAME} container..."
    ${CONTAINER_PROVIDER} stop "${VAULT_CONTAINER_NAME}" > /dev/null 2>&1
    ${CONTAINER_PROVIDER} rm "${VAULT_CONTAINER_NAME}" > /dev/null 2>&1
    sudo rm -rf "${VAULT_DIR}/data"
    sudo rm -rf "${VAULT_DIR}/logs"
    sudo rm -rf "${VAULT_DIR}/certs"
fi

# Ensure directories exist
mkdir -p "${VAULT_DATA_DIR}" "${VAULT_LOG_DIR}" "${VAULT_CERT_DIR}"

# Use ACLs to grant the container's vault user (UID 100) permissions on the host
echo "🔐 Setting ACLs for Vault container user (UID 100)..."
sudo setfacl -R -m u:100:rwx "${VAULT_DIR}"
sudo setfacl -R -d -m u:100:rwx "${VAULT_DIR}"

# Run the container
# We use -dev for automatic unseal and root token generation.
# We use -config to point to our persistent storage.
# We use -dev-tls and -dev-tls-cert-dir to enable TLS and store generated certs.
# We use SKIP_CHOWN=true to avoid permission issues with mounted volumes.
${CONTAINER_PROVIDER} run -d \
    --name "${VAULT_CONTAINER_NAME}" \
    -p "${VAULT_PORT}:${VAULT_PORT}" \
    -e SKIP_CHOWN=true \
    -v "${VAULT_CONFIG_DIR}:/vault/config" \
    -v "${VAULT_DATA_DIR}:/vault/data" \
    -v "${VAULT_LOG_DIR}:/vault/logs" \
    -v "${VAULT_CERT_DIR}:/vault/certs" \
    --cap-add=IPC_LOCK \
    -e SKIP_SETCAP=true \
    -e SKIP_CHOWN=true \
    "${VAULT_IMAGE}" \
    server -dev \
    -dev-listen-address="0.0.0.0:${VAULT_PORT}" \
    -dev-tls \
    -dev-tls-cert-dir=/vault/certs \
    -config=/vault/config/vault-config.hcl

echo "⏳ Waiting for Vault to start and generate root token..."
# Wait for logs to contain the root token
MAX_RETRIES=15
COUNT=0
UNSEAL_KEY=""
ROOT_TOKEN=""
while [ $COUNT -lt $MAX_RETRIES ]; do
    LOGS=$(${CONTAINER_PROVIDER} logs "${VAULT_CONTAINER_NAME}" 2>&1)
    if echo "$LOGS" | grep -q "Unseal Key:"; then
        UNSEAL_KEY=$(echo "$LOGS" | grep "Unseal Key:" | awk '{print $3}')
    fi
    if echo "$LOGS" | grep -q "Root Token:"; then
        ROOT_TOKEN=$(echo "$LOGS" | grep "Root Token:" | awk '{print $3}')
        break
    fi
    sleep 10
    COUNT=$((COUNT + 1))
done

if [ -z "${UNSEAL_KEY}" ]; then
    echo "❌ Error: Failed to retrieve Vault unseal key."
    exit 1
fi

if [ -z "${ROOT_TOKEN}" ]; then
    echo "❌ Error: Failed to retrieve Vault root token."
    exit 1
fi

echo "✅ Vault is up and running!"
echo "🔑 Unseal Key: ${UNSEAL_KEY}"
echo "🗝️ Root Token: ${ROOT_TOKEN}"

echo "🌐 Connecting vault to the Kind network..."
$CONTAINER_PROVIDER network connect kind "${VAULT_CONTAINER_NAME}"

# Store the root token for other scripts
echo "${UNSEAL_KEY}" > "${VAULT_DIR}/.unseal_key"
chmod 600 "${VAULT_DIR}/.unseal_key"
echo "${ROOT_TOKEN}" > "${VAULT_DIR}/.root_token"
chmod 600 "${VAULT_DIR}/.root_token"

# Store the CA certificate for vault CLI usage
# In -dev-tls mode, Vault generates vault-ca.pem in the cert-dir
# Wait for the CA file to appear
COUNT=0
while [ $COUNT -lt 10 ]; do
    if [ -f "${VAULT_CERT_DIR}/vault-ca.pem" ]; then
        break
    fi
    sleep 1
    COUNT=$((COUNT + 1))
done

if [ ! -f "${VAULT_CERT_DIR}/vault-ca.pem" ]; then
    echo "⚠️ Warning: vault-ca.pem not found in ${VAULT_CERT_DIR}."
else
    echo "✅ CA Certificate found: ${VAULT_CERT_DIR}/vault-ca.pem"
fi

# Enable audit device to log all operations to a file
echo "📋 Enabling Vault audit logging..."
${CONTAINER_PROVIDER} exec -e VAULT_TOKEN="${ROOT_TOKEN}" "${VAULT_CONTAINER_NAME}" \
    vault audit enable \
    -address="https://127.0.0.1:${VAULT_PORT}" \
    -ca-cert=/vault/certs/vault-ca.pem \
    file file_path=/vault/logs/audit.log

echo "💻 To use Vault CLI, run:"
echo "export VAULT_ADDR='https://127.0.0.1:${VAULT_PORT}'"
echo "export VAULT_TOKEN='${ROOT_TOKEN}'"
echo "export VAULT_CACERT='${VAULT_CERT_DIR}/vault-ca.pem'"
echo "vault status"
