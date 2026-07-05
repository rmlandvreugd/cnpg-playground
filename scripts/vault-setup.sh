#!/usr/bin/env bash
#
# This script deploys a standalone HashiCorp Vault container with TLS
# (cert issued by step-ca), connected to the 'kind' Docker network.
# It runs Vault in non-dev mode with 1 unseal key, initializes and
# unseals automatically, then enables userpass auth.
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
STEP_CA_DIR="${GIT_REPO_ROOT}/step-ca"
STEP_CA_PKI_DIR="${STEP_CA_DIR}/pki"
STEP_CA_SECRETS_DIR="${STEP_CA_DIR}/secrets"

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
sudo mkdir -p "${VAULT_DATA_DIR}" "${VAULT_LOG_DIR}" "${VAULT_CERT_DIR}"

# --- Request Vault TLS certificate from step-ca via X5C provisioner ---
echo "📜 Requesting Vault TLS certificate from step-ca (X5C provisioner)..."

HOST_IP=$(hostname -I | awk '{print $1}')
HOST_IP_DASHED=$(echo "$HOST_IP" | tr '.' '-')
VAULT_HOST="vault.${TRAEFIK_EDGE_IP_DASHED}.sslip.io"
STEP_CA_HOST="step-ca.${HOST_IP_DASHED}.sslip.io"

# Copy intermediate CA cert+key into step-ca container for X5C signing
${CONTAINER_PROVIDER} cp "${STEP_CA_PKI_DIR}/intermediate_ca.crt" "${STEP_CA_CONTAINER_NAME}:/tmp/intermediate_ca.crt"
${CONTAINER_PROVIDER} cp "${STEP_CA_SECRETS_DIR}/intermediate_ca_key" "${STEP_CA_CONTAINER_NAME}:/tmp/intermediate_ca_key"

# Request a server TLS cert from step-ca for Vault using the X5C provisioner.
# This signs with the step-ca intermediate CA (not the root), producing a shorter
# chain: leaf → step-ca Int CA 1 → step-ca Root CA.
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
    --san "${VAULT_HOST}" \
    --san "vault" \
    --san "localhost" \
    --san "vault.vault.svc.cluster.local" \
    --san "${HOST_IP}" \
    --san "127.0.0.1" \
    --not-after 720h \
    --force

# Copy the cert and key from step-ca container to host
# Use a temp dir since vault/certs/ may not be writable by the current user yet
VAULT_CERT_TMPDIR=$(mktemp -d)
${CONTAINER_PROVIDER} cp "${STEP_CA_CONTAINER_NAME}:/tmp/vault-cert.pem" "${VAULT_CERT_TMPDIR}/vault-cert.pem"
${CONTAINER_PROVIDER} cp "${STEP_CA_CONTAINER_NAME}:/tmp/vault-key.pem" "${VAULT_CERT_TMPDIR}/vault-key.pem"
sudo cp "${VAULT_CERT_TMPDIR}/vault-cert.pem" "${VAULT_CERT_DIR}/vault-cert.pem"
sudo cp "${VAULT_CERT_TMPDIR}/vault-key.pem" "${VAULT_CERT_DIR}/vault-key.pem"
rm -rf "${VAULT_CERT_TMPDIR}"

# Clean up intermediate CA key and cert files from step-ca container
${CONTAINER_PROVIDER} exec "${STEP_CA_CONTAINER_NAME}" rm -f /tmp/intermediate_ca.crt /tmp/intermediate_ca_key /tmp/vault-cert.pem /tmp/vault-key.pem

# Build the CA chain: step-ca root + intermediate
sudo cat "${STEP_CA_PKI_DIR}/root_ca.crt" "${STEP_CA_PKI_DIR}/intermediate_ca.crt" \
    | sudo tee "${VAULT_CERT_DIR}/vault-ca.pem" > /dev/null

sudo chmod 644 "${VAULT_CERT_DIR}/vault-cert.pem" "${VAULT_CERT_DIR}/vault-ca.pem"
sudo chmod 640 "${VAULT_CERT_DIR}/vault-key.pem"

echo "✅ Vault TLS certificate issued by step-ca"

# Use ACLs to grant the container's vault user (UID 100) permissions on the host
echo "🔐 Setting ACLs for Vault container user (UID 100)..."
if [ "$CONTAINER_PROVIDER" = "podman" ]; then
    # Clear stale/malformed ACL entries from previous runs
    sudo setfacl -R -b "${VAULT_DIR}"
    SUBUID_START=$(grep "^$(id -un):" /etc/subuid | head -n1 | cut -d: -f2)
    VAULT_HOST_UID=$((SUBUID_START + 99))
    sudo setfacl -R -m "u:${VAULT_HOST_UID}:rwx" "${VAULT_DIR}"
    sudo setfacl -R -d -m "u:${VAULT_HOST_UID}:rwx" "${VAULT_DIR}"
else
    sudo setfacl -R -m u:100:rwx "${VAULT_DIR}"
    sudo setfacl -R -d -m u:100:rwx "${VAULT_DIR}"
fi

# Run the container in non-dev mode with the HCL config
# Podman on SELinux-enabled hosts tries to relabel bind-mount xattrs; if the
# filesystem does not support xattrs that fails. Disable labeling instead.
SECURITY_OPTS=""
if [ "$CONTAINER_PROVIDER" = "podman" ]; then
    SECURITY_OPTS="--security-opt label=disable"
fi

${CONTAINER_PROVIDER} run -d \
    --name "${VAULT_CONTAINER_NAME}" \
    --network bridge \
    ${SECURITY_OPTS} \
    -p "${VAULT_PORT}:${VAULT_PORT}" \
    -p "${VAULT_HTTP_PORT}:${VAULT_HTTP_PORT}" \
    -v "${VAULT_CONFIG_DIR}:/vault/config" \
    -v "${VAULT_DATA_DIR}:/vault/data" \
    -v "${VAULT_LOG_DIR}:/vault/logs" \
    -v "${VAULT_CERT_DIR}:/vault/certs" \
    --cap-add=IPC_LOCK \
    "${VAULT_IMAGE}" \
    vault server -config=/vault/config/vault-config.hcl

# Wait for Vault to start (use host curl against the TLS endpoint)
echo "⏳ Waiting for Vault to start..."
MAX_RETRIES=30
COUNT=0
while [ $COUNT -lt $MAX_RETRIES ]; do
    if curl -skf "https://127.0.0.1:${VAULT_PORT}/v1/sys/seal-status" >/dev/null 2>&1; then
        break
    fi
    sleep 2
    COUNT=$((COUNT + 1))
done

if [ $COUNT -eq $MAX_RETRIES ]; then
    echo "❌ Error: Vault did not start within the expected time."
    exit 1
fi

echo "✅ Vault is up and responding!"

if [ $COUNT -eq $MAX_RETRIES ]; then
    echo "❌ Error: Vault did not start within the expected time."
    exit 1
fi

echo "✅ Vault is up and responding!"

# --- Initialize Vault (if not already initialized) ---
INIT_STATUS=$(curl -sk "https://127.0.0.1:${VAULT_PORT}/v1/sys/init" 2>/dev/null)

if echo "${INIT_STATUS}" | jq -e '.initialized == false' > /dev/null 2>&1; then
    echo "🔧 Initializing Vault with 1 unseal key..."
    INIT_OUTPUT=$(${CONTAINER_PROVIDER} exec \
        -e VAULT_ADDR="https://127.0.0.1:${VAULT_PORT}" \
        -e VAULT_CACERT=/vault/certs/vault-ca.pem \
        "${VAULT_CONTAINER_NAME}" \
        vault operator init -key-shares=1 -key-threshold=1 -format=json)

    UNSEAL_KEY=$(echo "${INIT_OUTPUT}" | jq -r '.unseal_keys_b64[0]')
    ROOT_TOKEN=$(echo "${INIT_OUTPUT}" | jq -r '.root_token')

    echo "🔑 Unseal Key: ${UNSEAL_KEY}"
    echo "🗝️ Root Token: ${ROOT_TOKEN}"

    # Store the unseal key and root token for other scripts
    echo "${UNSEAL_KEY}" | sudo tee "${VAULT_DIR}/.unseal_key" > /dev/null
    sudo chmod 600 "${VAULT_DIR}/.unseal_key"
    echo "${ROOT_TOKEN}" | sudo tee "${VAULT_DIR}/.root_token" > /dev/null
    sudo chmod 600 "${VAULT_DIR}/.root_token"

    # Unseal Vault
    echo "🔓 Unsealing Vault..."
    ${CONTAINER_PROVIDER} exec \
        -e VAULT_ADDR="https://127.0.0.1:${VAULT_PORT}" \
        -e VAULT_CACERT=/vault/certs/vault-ca.pem \
        "${VAULT_CONTAINER_NAME}" \
        vault operator unseal "${UNSEAL_KEY}"
else
    echo "🔷 Vault is already initialized. Skipping init."
    ROOT_TOKEN=$(sudo cat "${VAULT_DIR}/.root_token" 2>/dev/null || echo "")

    # Unseal if sealed
    SEAL_STATUS=$(curl -sk "https://127.0.0.1:${VAULT_PORT}/v1/sys/seal-status" 2>/dev/null || true)

    if echo "${SEAL_STATUS}" | jq -e '.sealed == true' > /dev/null 2>&1; then
        UNSEAL_KEY=$(sudo cat "${VAULT_DIR}/.unseal_key" 2>/dev/null || echo "")
        if [ -n "${UNSEAL_KEY}" ]; then
            echo "🔓 Unsealing Vault..."
            ${CONTAINER_PROVIDER} exec \
                -e VAULT_ADDR="https://127.0.0.1:${VAULT_PORT}" \
                -e VAULT_CACERT=/vault/certs/vault-ca.pem \
                "${VAULT_CONTAINER_NAME}" \
                vault operator unseal "${UNSEAL_KEY}"
        else
            echo "⚠️ Warning: Vault is sealed but no unseal key found."
        fi
    fi
fi

# Verify Vault is unsealed
echo "🔎 Verifying Vault is unsealed..."
${CONTAINER_PROVIDER} exec \
    -e VAULT_ADDR="https://127.0.0.1:${VAULT_PORT}" \
    -e VAULT_CACERT=/vault/certs/vault-ca.pem \
    -e VAULT_TOKEN="${ROOT_TOKEN}" \
    "${VAULT_CONTAINER_NAME}" \
    vault status > /dev/null

# Enable audit device to log all operations to a file
echo "📋 Enabling Vault audit logging..."
${CONTAINER_PROVIDER} exec \
    -e VAULT_ADDR="https://127.0.0.1:${VAULT_PORT}" \
    -e VAULT_CACERT=/vault/certs/vault-ca.pem \
    -e VAULT_TOKEN="${ROOT_TOKEN}" \
    "${VAULT_CONTAINER_NAME}" \
    vault audit enable \
    file file_path=/vault/logs/audit.log 2>/dev/null || echo "  Audit already enabled, continuing"

echo "👤 Enabling userpass auth and creating admin user..."
${CONTAINER_PROVIDER} exec \
    -e VAULT_ADDR="https://127.0.0.1:${VAULT_PORT}" \
    -e VAULT_CACERT=/vault/certs/vault-ca.pem \
    -e VAULT_TOKEN="${ROOT_TOKEN}" \
    "${VAULT_CONTAINER_NAME}" \
    vault auth enable \
    userpass 2>/dev/null || echo "  userpass already enabled, continuing"

echo 'path "*" { capabilities = ["create","read","update","delete","list","sudo"] }' \
    | ${CONTAINER_PROVIDER} exec -i \
        -e VAULT_ADDR="https://127.0.0.1:${VAULT_PORT}" \
        -e VAULT_CACERT=/vault/certs/vault-ca.pem \
        -e VAULT_TOKEN="${ROOT_TOKEN}" \
        "${VAULT_CONTAINER_NAME}" \
        vault policy write \
        admin -

${CONTAINER_PROVIDER} exec \
    -e VAULT_ADDR="https://127.0.0.1:${VAULT_PORT}" \
    -e VAULT_CACERT=/vault/certs/vault-ca.pem \
    -e VAULT_TOKEN="${ROOT_TOKEN}" \
    "${VAULT_CONTAINER_NAME}" \
    vault write \
    auth/userpass/users/"${VAULT_ADMIN_USER}" \
    password="${VAULT_ADMIN_PASSWORD}" \
    policies=admin

echo "✅ Userpass admin created: ${VAULT_ADMIN_USER}"
echo "🔎 Verifying Vault CLI connectivity..."
${CONTAINER_PROVIDER} exec \
    -e VAULT_ADDR="https://127.0.0.1:${VAULT_PORT}" \
    -e VAULT_CACERT=/vault/certs/vault-ca.pem \
    -e VAULT_TOKEN="${ROOT_TOKEN}" \
    "${VAULT_CONTAINER_NAME}" \
    vault status > /dev/null

echo "💻 To use Vault CLI, run:"
echo "export VAULT_ADDR='https://127.0.0.1:${VAULT_PORT}'"
echo "export VAULT_TOKEN='${ROOT_TOKEN}'"
echo "export VAULT_CACERT='${VAULT_CERT_DIR}/vault-ca.pem'"
echo "vault status"
