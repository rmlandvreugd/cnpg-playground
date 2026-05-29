#!/usr/bin/env bash
#
# This script deploys a SmallStep step-ca container as the root/intermediate
# CA for the cnpg-playground. It uses the Docker entrypoint's auto-init
# mechanism (DOCKER_STEPCA_INIT_* env vars) for initial configuration and
# runs in standalone mode with BadgerDB.
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

STEP_CA_DIR="${GIT_REPO_ROOT}/step-ca"
STEP_CA_CONFIG_DIR="${STEP_CA_DIR}/config"
STEP_CA_PKI_DIR="${STEP_CA_DIR}/pki"
STEP_CA_SECRETS_DIR="${STEP_CA_DIR}/secrets"
STEP_CA_DB_DIR="${STEP_CA_DIR}/db"

# Generate a random CA password if not provided
STEP_CA_PASSWORD="${STEP_CA_PASSWORD:-$(openssl rand -base64 24)}"

echo "🚀 Setting up step-ca container..."

# Pull the image
echo "📦 Pulling step-ca image..."
${CONTAINER_PROVIDER} pull "${STEP_CA_IMAGE}"

# Stop and remove existing container if it exists
if ${CONTAINER_PROVIDER} ps -a --format '{{.Names}}' | grep -q "^${STEP_CA_CONTAINER_NAME}$"; then
    echo "🗑️ Stopping and removing existing ${STEP_CA_CONTAINER_NAME} container..."
    ${CONTAINER_PROVIDER} stop "${STEP_CA_CONTAINER_NAME}" > /dev/null 2>&1
    ${CONTAINER_PROVIDER} rm "${STEP_CA_CONTAINER_NAME}" > /dev/null 2>&1
    sudo rm -rf "${STEP_CA_PKI_DIR}" "${STEP_CA_SECRETS_DIR}" "${STEP_CA_DB_DIR}"
fi

# Ensure directories exist
echo "📁 Creating step-ca directories..."
sudo mkdir -p "${STEP_CA_CONFIG_DIR}" "${STEP_CA_PKI_DIR}" "${STEP_CA_SECRETS_DIR}" "${STEP_CA_DB_DIR}"

# Store the CA password
echo "${STEP_CA_PASSWORD}" | sudo tee "${STEP_CA_SECRETS_DIR}/.ca_password" > /dev/null
sudo chmod 600 "${STEP_CA_SECRETS_DIR}/.ca_password"

# Run the container
# Podman on SELinux-enabled hosts tries to relabel bind-mount xattrs; if the
# filesystem does not support xattrs that fails. Disable labeling instead.
SECURITY_OPTS=""
if [ "$CONTAINER_PROVIDER" = "podman" ]; then
    SECURITY_OPTS="--security-opt label=disable"
fi

echo "🏃 Starting step-ca container..."
${CONTAINER_PROVIDER} run -d \
    --name "${STEP_CA_CONTAINER_NAME}" \
    --network bridge \
    ${SECURITY_OPTS} \
    -p "${STEP_CA_PORT}:${STEP_CA_PORT}" \
    -e "DOCKER_STEPCA_INIT_NAME=${STEP_CA_CA_NAME}" \
    -e "DOCKER_STEPCA_INIT_DNS_NAMES=localhost,${STEP_CA_DNS_NAME}" \
    -e "DOCKER_STEPCA_INIT_ADDRESS=:${STEP_CA_PORT}" \
    -e "DOCKER_STEPCA_INIT_PROVISIONER_NAME=${STEP_CA_PROVISIONER_NAME}" \
    -e "DOCKER_STEPCA_INIT_PASSWORD=${STEP_CA_PASSWORD}" \
    -e "DOCKER_STEPCA_INIT_DEPLOYMENT_TYPE=standalone" \
    -v "${STEP_CA_CONFIG_DIR}:/home/step/config" \
    -v "${STEP_CA_PKI_DIR}:/home/step/certs" \
    -v "${STEP_CA_SECRETS_DIR}:/home/step/secrets" \
    -v "${STEP_CA_DB_DIR}:/home/step/db" \
    "${STEP_CA_IMAGE}"

# Wait for step-ca to be ready
echo "⏳ Waiting for step-ca to be ready..."
MAX_RETRIES=30
COUNT=0
while [ $COUNT -lt $MAX_RETRIES ]; do
    if ${CONTAINER_PROVIDER} exec \
        -e STEPPATH=/home/step \
        "${STEP_CA_CONTAINER_NAME}" \
        step ca health --ca-url "https://127.0.0.1:${STEP_CA_PORT}" \
        --root /home/step/certs/root_ca.crt 2>/dev/null; then
        echo "✅ step-ca is healthy"
        break
    fi
    sleep 2
    COUNT=$((COUNT + 1))
done

if [ $COUNT -eq $MAX_RETRIES ]; then
    echo "❌ Error: step-ca did not become healthy within the expected time."
    exit 1
fi

# Extract the root CA fingerprint (needed for clients to bootstrap)
echo "🔑 Extracting root CA fingerprint..."
CA_FINGERPRINT=$(${CONTAINER_PROVIDER} exec "${STEP_CA_CONTAINER_NAME}" \
    step certificate fingerprint /home/step/certs/root_ca.crt)
echo "${CA_FINGERPRINT}" | sudo tee "${STEP_CA_SECRETS_DIR}/.ca_fingerprint" > /dev/null
sudo chmod 600 "${STEP_CA_SECRETS_DIR}/.ca_fingerprint"

# Ensure root and intermediate certs have correct host permissions
sudo chmod 644 "${STEP_CA_PKI_DIR}/root_ca.crt" 2>/dev/null || true
sudo chmod 644 "${STEP_CA_PKI_DIR}/intermediate_ca.crt" 2>/dev/null || true

# Add X5C provisioner (for cert-based authentication, e.g. Vault intermediate signing)
echo "🔐 Adding X5C provisioner..."
${CONTAINER_PROVIDER} exec \
    -e STEPPATH=/home/step \
    "${STEP_CA_CONTAINER_NAME}" \
    step ca provisioner add x5c-provisioner --type X5C \
    --password-file /home/step/secrets/password \
    --ca-config /home/step/config/ca.json \
    || { echo "❌ Error: Failed to add X5C provisioner."; exit 1; }

# Apply ca.json overrides (CRL, TLS settings) from template
echo "🔧 Applying ca.json overrides..."
STEP_CA_PORT="${STEP_CA_PORT}" STEP_CA_DNS_NAME="${STEP_CA_DNS_NAME}" \
    envsubst '${STEP_CA_PORT} ${STEP_CA_DNS_NAME}' \
    < "${STEP_CA_DIR}/config/ca.json.tpl" \
    | ${CONTAINER_PROVIDER} exec -i "${STEP_CA_CONTAINER_NAME}" \
        sh -c 'cat > /home/step/config/ca.json.override'
# Merge: copy the authority provisioners from the generated ca.json, then apply the override
${CONTAINER_PROVIDER} exec "${STEP_CA_CONTAINER_NAME}" \
    sh -c 'jq -s ".[0].authority = .[1].authority | .[0]" /home/step/config/ca.json.override /home/step/config/ca.json > /home/step/config/ca.json.new && mv /home/step/config/ca.json.new /home/step/config/ca.json' \
    || { echo "⚠️ Warning: ca.json override merge failed, using init defaults."; }

# Reload step-ca to pick up the new provisioner and config
echo "🔄 Reloading step-ca..."
${CONTAINER_PROVIDER} exec "${STEP_CA_CONTAINER_NAME}" \
    kill -HUP 1

echo "✅ step-ca is up and running!"
echo "🔑 CA URL: https://127.0.0.1:${STEP_CA_PORT}"
echo "🔑 CA Fingerprint: ${CA_FINGERPRINT}"
echo "🔑 CA Password: ${STEP_CA_PASSWORD}"
