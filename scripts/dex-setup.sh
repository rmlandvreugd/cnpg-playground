#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

DEX_DIR="${GIT_REPO_ROOT}/dex"
DEX_CONFIG_DIR="${DEX_DIR}/config"
DEX_TLS_DIR="${DEX_DIR}/tls"
STEP_CA_DIR="${GIT_REPO_ROOT}/step-ca"
STEP_CA_PKI_DIR="${STEP_CA_DIR}/pki"
STEP_CA_SECRETS_DIR="${STEP_CA_DIR}/secrets"

echo "🚀 Setting up Dex OIDC container..."

HOST_IP=$(hostname -I | awk '{print $1}')
HOST_IP_DASHED=$(echo "$HOST_IP" | tr '.' '-')
DEX_HOST="dex.${HOST_IP_DASHED}.sslip.io"
VAULT_HOST="vault.${HOST_IP_DASHED}.sslip.io"
STEP_CA_HOST="step-ca.${HOST_IP_DASHED}.sslip.io"

# Remove existing container and stale certs
if ${CONTAINER_PROVIDER} ps -a --format '{{.Names}}' | grep -q "^${DEX_CONTAINER_NAME}$"; then
    echo "🗑️ Removing existing ${DEX_CONTAINER_NAME} container..."
    ${CONTAINER_PROVIDER} rm -f "${DEX_CONTAINER_NAME}" > /dev/null 2>&1
    sudo rm -rf "${DEX_TLS_DIR}"
fi

sudo mkdir -p "${DEX_TLS_DIR}" "${DEX_CONFIG_DIR}"

# ACLs for Dex container UID 1001
echo "🔐 Setting ACLs for Dex container user (UID 1001)..."
if [ "$CONTAINER_PROVIDER" = "podman" ]; then
    sudo setfacl -R -b "${DEX_DIR}"
    SUBUID_START=$(grep "^$(id -un):" /etc/subuid | head -n1 | cut -d: -f2)
    DEX_HOST_UID=$((SUBUID_START + 1000))
    sudo setfacl -R -m  "u:${DEX_HOST_UID}:rwx" "${DEX_DIR}"
    sudo setfacl -R -d -m "u:${DEX_HOST_UID}:rwx" "${DEX_DIR}"
else
    sudo setfacl -R -m  u:1001:rwx "${DEX_DIR}"
    sudo setfacl -R -d -m u:1001:rwx "${DEX_DIR}"
fi

# Issue TLS cert for Dex from step-ca intermediate via X5C provisioner.
# Dex is an external service (host container), so its cert is signed by the
# step-ca intermediate CA rather than Vault PKI (which is for in-cluster workloads).
echo "📜 Issuing Dex TLS certificate from step-ca (X5C provisioner)..."

# Copy intermediate CA cert+key into step-ca container for X5C signing
${CONTAINER_PROVIDER} cp "${STEP_CA_PKI_DIR}/intermediate_ca.crt" "${STEP_CA_CONTAINER_NAME}:/tmp/intermediate_ca.crt"
${CONTAINER_PROVIDER} cp "${STEP_CA_SECRETS_DIR}/intermediate_ca_key" "${STEP_CA_CONTAINER_NAME}:/tmp/intermediate_ca_key"

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
    --san "${DEX_HOST}" --san "dex" --san "localhost" \
    --san "${HOST_IP}" --san "127.0.0.1" \
    --not-after 720h --force

# Copy cert and key from step-ca container to host
# Use a temp dir since dex/tls/ may not be writable by the current user yet
DEX_CERT_TMPDIR=$(mktemp -d)
${CONTAINER_PROVIDER} cp "${STEP_CA_CONTAINER_NAME}:/tmp/dex-cert.pem" "${DEX_CERT_TMPDIR}/dex-cert.pem"
${CONTAINER_PROVIDER} cp "${STEP_CA_CONTAINER_NAME}:/tmp/dex-key.pem" "${DEX_CERT_TMPDIR}/dex-key.pem"
sudo cp "${DEX_CERT_TMPDIR}/dex-cert.pem" "${DEX_TLS_DIR}/dex.crt"
sudo cp "${DEX_CERT_TMPDIR}/dex-key.pem" "${DEX_TLS_DIR}/dex.key"
rm -rf "${DEX_CERT_TMPDIR}"

# Build the CA chain: step-ca intermediate + step-ca root
# (Dex's leaf cert is signed by step-ca intermediate, so clients need the
# intermediate + root to verify the full chain)
sudo cat "${STEP_CA_PKI_DIR}/intermediate_ca.crt" "${STEP_CA_PKI_DIR}/root_ca.crt" \
    | sudo tee "${DEX_TLS_DIR}/ca-chain.pem" > /dev/null
sudo cat "${STEP_CA_PKI_DIR}/intermediate_ca.crt" "${STEP_CA_PKI_DIR}/root_ca.crt" \
    | sudo tee "${DEX_TLS_DIR}/ca.crt" > /dev/null
# Append CA chain to the leaf cert for full chain verification
sudo bash -c "cat '${STEP_CA_PKI_DIR}/intermediate_ca.crt' '${STEP_CA_PKI_DIR}/root_ca.crt' >> '${DEX_TLS_DIR}/dex.crt'"

# Clean up intermediate CA key and cert files from step-ca container
${CONTAINER_PROVIDER} exec "${STEP_CA_CONTAINER_NAME}" rm -f /tmp/intermediate_ca.crt /tmp/intermediate_ca_key /tmp/dex-cert.pem /tmp/dex-key.pem

sudo chmod 644 "${DEX_TLS_DIR}/dex.crt" "${DEX_TLS_DIR}/ca.crt" "${DEX_TLS_DIR}/ca-chain.pem"
sudo chmod 640 "${DEX_TLS_DIR}/dex.key"

# Generate Dex config from template
echo "📝 Generating Dex config..."
DEX_HOST="${DEX_HOST}" VAULT_HOST="${VAULT_HOST}" \
DEX_PORT="${DEX_PORT}" VAULT_PORT="${VAULT_PORT}" \
DEX_OIDC_CLIENT_ID="${DEX_OIDC_CLIENT_ID}" DEX_OIDC_CLIENT_SECRET="${DEX_OIDC_CLIENT_SECRET}" \
DEX_STATIC_PASSWORD_HASH="${DEX_STATIC_PASSWORD_HASH}" \
DEX_RBR_ADMIN_PASSWORD_HASH="${DEX_RBR_ADMIN_PASSWORD_HASH}" \
DEX_RBR_VER_ADMIN_PASSWORD_HASH="${DEX_RBR_VER_ADMIN_PASSWORD_HASH}" \
DEX_UNRELATED_PASSWORD_HASH="${DEX_UNRELATED_PASSWORD_HASH}" \
DEX_GRAFANA_RBR_VER_CLIENT_SECRET="${DEX_GRAFANA_RBR_VER_CLIENT_SECRET}" \
envsubst '${DEX_HOST} ${VAULT_HOST} ${DEX_PORT} ${VAULT_PORT} ${DEX_OIDC_CLIENT_ID} ${DEX_OIDC_CLIENT_SECRET} ${DEX_STATIC_PASSWORD_HASH} ${DEX_RBR_ADMIN_PASSWORD_HASH} ${DEX_RBR_VER_ADMIN_PASSWORD_HASH} ${DEX_UNRELATED_PASSWORD_HASH} ${DEX_GRAFANA_RBR_VER_CLIENT_SECRET}' \
    < "${DEX_CONFIG_DIR}/dex-config.yaml.tpl" \
    | sudo tee "${DEX_CONFIG_DIR}/dex-config.yaml" > /dev/null

SECURITY_OPTS=""
[ "$CONTAINER_PROVIDER" = "podman" ] && SECURITY_OPTS="--security-opt label=disable"

echo "🚀 Starting Dex container..."
${CONTAINER_PROVIDER} run -d \
    --name "${DEX_CONTAINER_NAME}" \
    --network bridge \
    ${SECURITY_OPTS} \
    -p "${DEX_PORT}:${DEX_PORT}" \
    -v "${DEX_CONFIG_DIR}/dex-config.yaml:/etc/dex/config.yaml" \
    -v "${DEX_TLS_DIR}:/etc/dex/tls" \
    "${DEX_IMAGE}" dex serve /etc/dex/config.yaml

# Poll OIDC discovery endpoint for readiness
echo "⏳ Waiting for Dex OIDC endpoint..."
DISCOVERY_URL="https://${DEX_HOST}:${DEX_PORT}/dex/.well-known/openid-configuration"
MAX_RETRIES=30; COUNT=0
while [ $COUNT -lt $MAX_RETRIES ]; do
    if curl -sf --cacert "${DEX_TLS_DIR}/ca-chain.pem" "${DISCOVERY_URL}" > /dev/null 2>&1; then
        echo "✅ Dex is ready at https://${DEX_HOST}:${DEX_PORT}/dex"
        break
    fi
    sleep 5
    COUNT=$((COUNT + 1))
done
if [ $COUNT -eq $MAX_RETRIES ]; then
    echo "❌ Dex did not become ready."
    exit 1
fi