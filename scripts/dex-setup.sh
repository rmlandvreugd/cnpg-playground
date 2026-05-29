#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

VAULT_DIR="${GIT_REPO_ROOT}/vault"
DEX_DIR="${GIT_REPO_ROOT}/dex"
DEX_CONFIG_DIR="${DEX_DIR}/config"
DEX_TLS_DIR="${DEX_DIR}/tls"
STEP_CA_PKI_DIR="${GIT_REPO_ROOT}/step-ca/pki"

echo "🚀 Setting up Dex OIDC container..."

HOST_IP=$(hostname -I | awk '{print $1}')
HOST_IP_DASHED=$(echo "$HOST_IP" | tr '.' '-')
DEX_HOST="dex.${HOST_IP_DASHED}.sslip.io"
VAULT_HOST="vault.${HOST_IP_DASHED}.sslip.io"

ROOT_TOKEN=$(sudo cat "${VAULT_DIR}/.root_token")

_vcmd() {
    ${CONTAINER_PROVIDER} exec \
        -e VAULT_ADDR="https://127.0.0.1:${VAULT_PORT}" \
        -e VAULT_CACERT=/vault/certs/vault-ca.pem \
        -e VAULT_TOKEN="${ROOT_TOKEN}" \
        "${VAULT_CONTAINER_NAME}" \
        vault "$@"
}

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

# Issue TLS cert for Dex from Vault PKI (dex-server role)
echo "📜 Issuing Dex TLS certificate from Vault PKI..."
CERT_JSON=$(_vcmd write -format=json pki_int/issue/dex-server \
    common_name="${DEX_HOST}" \
    alt_names="dex,localhost" \
    ip_sans="${HOST_IP},127.0.0.1")

jq -r '.data.certificate'            <<< "${CERT_JSON}" | sudo tee "${DEX_TLS_DIR}/dex.crt"      > /dev/null
jq -r '.data.private_key'            <<< "${CERT_JSON}" | sudo tee "${DEX_TLS_DIR}/dex.key"      > /dev/null
jq -r '.data.issuing_ca'             <<< "${CERT_JSON}" | sudo tee "${DEX_TLS_DIR}/ca.crt"       > /dev/null
# Build the full CA chain: Vault intermediate + step-ca intermediate + step-ca root
# (Vault's ca_chain only includes the Vault intermediate; clients need the full chain)
jq -r '.data.ca_chain | join("\n")'  <<< "${CERT_JSON}" | sudo tee "${DEX_TLS_DIR}/ca-chain.pem" > /dev/null
sudo bash -c "cat '${STEP_CA_PKI_DIR}/intermediate_ca.crt' '${STEP_CA_PKI_DIR}/root_ca.crt' >> '${DEX_TLS_DIR}/ca-chain.pem'"
# Also append the step-ca chain to ca.crt for completeness
sudo bash -c "cat '${STEP_CA_PKI_DIR}/intermediate_ca.crt' '${STEP_CA_PKI_DIR}/root_ca.crt' >> '${DEX_TLS_DIR}/ca.crt'"
# Dex serves tlsCert as the server certificate; include the full chain so clients
# can verify the complete path: leaf → Vault intermediate → step-ca intermediate → step-ca root
sudo bash -c "cat '${STEP_CA_PKI_DIR}/intermediate_ca.crt' '${STEP_CA_PKI_DIR}/root_ca.crt' >> '${DEX_TLS_DIR}/dex.crt'"

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
