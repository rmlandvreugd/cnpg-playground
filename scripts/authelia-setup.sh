#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

AUTHELIA_DIR="${GIT_REPO_ROOT}/authelia"
AUTHELIA_CONFIG_DIR="${AUTHELIA_DIR}/config"
AUTHELIA_TLS_DIR="${AUTHELIA_DIR}/tls"
AUTHELIA_SECRETS_DIR="${AUTHELIA_DIR}/secrets"
STEP_CA_DIR="${GIT_REPO_ROOT}/step-ca"
STEP_CA_PKI_DIR="${STEP_CA_DIR}/pki"
STEP_CA_SECRETS_DIR="${STEP_CA_DIR}/secrets"

echo "🚀 Setting up Authelia OIDC container..."

HOST_IP=$(hostname -I | awk '{print $1}')
HOST_IP_DASHED=$(echo "$HOST_IP" | tr '.' '-')
AUTHELIA_HOST="authelia.${HOST_IP_DASHED}.sslip.io"
VAULT_HOST="vault.${HOST_IP_DASHED}.sslip.io"
STEP_CA_HOST="step-ca.${HOST_IP_DASHED}.sslip.io"
TRAEFIK_IP_DASHED="${TRAEFIK_IP_DASHED:-}"

# Remove existing container and stale certs
if ${CONTAINER_PROVIDER} ps -a --format '{{.Names}}' | grep -q "^${AUTHELIA_CONTAINER_NAME}$"; then
    echo "🗑️ Removing existing ${AUTHELIA_CONTAINER_NAME} container..."
    ${CONTAINER_PROVIDER} rm -f "${AUTHELIA_CONTAINER_NAME}" > /dev/null 2>&1
    sudo rm -rf "${AUTHELIA_TLS_DIR}"
fi

sudo mkdir -p "${AUTHELIA_TLS_DIR}" "${AUTHELIA_CONFIG_DIR}" "${AUTHELIA_SECRETS_DIR}"

# ACLs for Authelia container UID 1000
echo "🔐 Setting ACLs for Authelia container user (UID 1000)..."
if [ "$CONTAINER_PROVIDER" = "podman" ]; then
    sudo setfacl -R -b "${AUTHELIA_DIR}"
    SUBUID_START=$(grep "^$(id -un):" /etc/subuid | head -n1 | cut -d: -f2)
    AUTHELIA_HOST_UID=$((SUBUID_START + 999))
    sudo setfacl -R -m  "u:${AUTHELIA_HOST_UID}:rwx" "${AUTHELIA_DIR}"
    sudo setfacl -R -d -m "u:${AUTHELIA_HOST_UID}:rwx" "${AUTHELIA_DIR}"
else
    sudo setfacl -R -m  u:1000:rwx "${AUTHELIA_DIR}"
    sudo setfacl -R -d -m u:1000:rwx "${AUTHELIA_DIR}"
fi

# Issue TLS cert for Authelia from step-ca intermediate via X5C provisioner.
# Authelia is an external service (host container), so its cert is signed by the
# step-ca intermediate CA rather than Vault PKI (which is for in-cluster workloads).
echo "📜 Issuing Authelia TLS certificate from step-ca (X5C provisioner)..."

${CONTAINER_PROVIDER} cp "${STEP_CA_PKI_DIR}/intermediate_ca.crt" "${STEP_CA_CONTAINER_NAME}:/tmp/intermediate_ca.crt"
${CONTAINER_PROVIDER} cp "${STEP_CA_SECRETS_DIR}/intermediate_ca_key" "${STEP_CA_CONTAINER_NAME}:/tmp/intermediate_ca_key"

${CONTAINER_PROVIDER} exec \
    -e STEPPATH=/home/step \
    "${STEP_CA_CONTAINER_NAME}" \
    step ca certificate "${AUTHELIA_HOST}" /tmp/authelia-cert.pem /tmp/authelia-key.pem \
    --provisioner x5c-provisioner \
    --x5c-cert /tmp/intermediate_ca.crt \
    --x5c-key /tmp/intermediate_ca_key \
    --x5c-chain /tmp/intermediate_ca.crt \
    --password-file /home/step/secrets/password \
    --ca-url "https://${STEP_CA_HOST}:${STEP_CA_PORT}" \
    --root /home/step/certs/root_ca.crt \
    --san "${AUTHELIA_HOST}" --san "authelia" --san "localhost" \
    --san "${HOST_IP}" --san "127.0.0.1" \
    --not-after 720h --force

AUTHELIA_CERT_TMPDIR=$(mktemp -d)
${CONTAINER_PROVIDER} cp "${STEP_CA_CONTAINER_NAME}:/tmp/authelia-cert.pem" "${AUTHELIA_CERT_TMPDIR}/authelia-cert.pem"
${CONTAINER_PROVIDER} cp "${STEP_CA_CONTAINER_NAME}:/tmp/authelia-key.pem" "${AUTHELIA_CERT_TMPDIR}/authelia-key.pem"
sudo cp "${AUTHELIA_CERT_TMPDIR}/authelia-cert.pem" "${AUTHELIA_TLS_DIR}/authelia.crt"
sudo cp "${AUTHELIA_CERT_TMPDIR}/authelia-key.pem" "${AUTHELIA_TLS_DIR}/authelia.key"
rm -rf "${AUTHELIA_CERT_TMPDIR}"

sudo cat "${STEP_CA_PKI_DIR}/intermediate_ca.crt" "${STEP_CA_PKI_DIR}/root_ca.crt" \
    | sudo tee "${AUTHELIA_TLS_DIR}/ca-chain.pem" > /dev/null
sudo cat "${STEP_CA_PKI_DIR}/intermediate_ca.crt" "${STEP_CA_PKI_DIR}/root_ca.crt" \
    | sudo tee "${AUTHELIA_TLS_DIR}/ca.crt" > /dev/null
sudo bash -c "cat '${STEP_CA_PKI_DIR}/intermediate_ca.crt' '${STEP_CA_PKI_DIR}/root_ca.crt' >> '${AUTHELIA_TLS_DIR}/authelia.crt'"

${CONTAINER_PROVIDER} exec "${STEP_CA_CONTAINER_NAME}" rm -f \
    /tmp/intermediate_ca.crt /tmp/intermediate_ca_key \
    /tmp/authelia-cert.pem /tmp/authelia-key.pem

sudo chmod 644 "${AUTHELIA_TLS_DIR}/authelia.crt" "${AUTHELIA_TLS_DIR}/ca.crt" "${AUTHELIA_TLS_DIR}/ca-chain.pem"
sudo chmod 640 "${AUTHELIA_TLS_DIR}/authelia.key"

# Generate JWKS RSA keypair for Authelia OIDC signing
echo "🔑 Generating JWKS RSA keypair..."
if [ ! -f "${AUTHELIA_SECRETS_DIR}/jwks_rsa_private.pem" ]; then
    openssl genrsa -out /tmp/jwks_rsa_private.pem 4096 2>/dev/null
    sudo cp /tmp/jwks_rsa_private.pem "${AUTHELIA_SECRETS_DIR}/jwks_rsa_private.pem"
    rm -f /tmp/jwks_rsa_private.pem
fi
sudo chmod 600 "${AUTHELIA_SECRETS_DIR}/jwks_rsa_private.pem"

# Hash OIDC client secrets using Authelia's PBKDF2 scheme
echo "🔒 Hashing OIDC client secrets..."
_hash_secret() {
    ${CONTAINER_PROVIDER} run --rm "${AUTHELIA_IMAGE}" \
        authelia crypto hash generate pbkdf2 --variant sha512 --password "$1" \
        | grep "Digest:" | awk '{print $2}'
}
AUTHELIA_VAULT_CLIENT_SECRET_HASH=$(_hash_secret "${AUTHELIA_VAULT_CLIENT_SECRET}")
AUTHELIA_STEP_CA_CLIENT_SECRET_HASH=$(_hash_secret "${AUTHELIA_STEP_CA_CLIENT_SECRET}")
AUTHELIA_GRAFANA_RBR_VER_CLIENT_SECRET_HASH=$(_hash_secret "${AUTHELIA_GRAFANA_RBR_VER_CLIENT_SECRET}")
AUTHELIA_GRAFANA_MONITORING_CLIENT_SECRET_HASH=$(_hash_secret "${AUTHELIA_GRAFANA_MONITORING_CLIENT_SECRET}")

# If TRAEFIK_IP_DASHED is not set, derive it from the host IP
if [ -z "${TRAEFIK_IP_DASHED}" ]; then
    TRAEFIK_IP_DASHED="${HOST_IP_DASHED}"
fi

# Select config template: two-domain when Traefik has a distinct IP from the host
if [ -n "${TRAEFIK_IP_DASHED}" ] && [ "${TRAEFIK_IP_DASHED}" != "${HOST_IP_DASHED}" ]; then
    CONFIG_TEMPLATE="${AUTHELIA_CONFIG_DIR}/configuration-two-domains.yaml.tpl"
    echo "📝 Generating Authelia config (two-domain: host + Traefik)..."
else
    CONFIG_TEMPLATE="${AUTHELIA_CONFIG_DIR}/configuration.yaml.tpl"
    echo "📝 Generating Authelia config (single-domain: host only)..."
fi
AUTHELIA_HOST="${AUTHELIA_HOST}" \
AUTHELIA_PORT="${AUTHELIA_PORT}" \
HOST_IP_DASHED="${HOST_IP_DASHED}" \
AUTHELIA_JWT_SECRET="${AUTHELIA_JWT_SECRET}" \
AUTHELIA_SESSION_SECRET="${AUTHELIA_SESSION_SECRET}" \
AUTHELIA_STORAGE_ENCRYPTION_KEY="${AUTHELIA_STORAGE_ENCRYPTION_KEY}" \
AUTHELIA_OIDC_HMAC_SECRET="${AUTHELIA_OIDC_HMAC_SECRET}" \
VAULT_HOST="${VAULT_HOST}" \
VAULT_PORT="${VAULT_PORT}" \
STEP_CA_HOST="${STEP_CA_HOST}" \
STEP_CA_PORT="${STEP_CA_PORT}" \
TRAEFIK_IP_DASHED="${TRAEFIK_IP_DASHED}" \
AUTHELIA_VAULT_CLIENT_SECRET_HASH="${AUTHELIA_VAULT_CLIENT_SECRET_HASH}" \
AUTHELIA_STEP_CA_CLIENT_SECRET_HASH="${AUTHELIA_STEP_CA_CLIENT_SECRET_HASH}" \
AUTHELIA_GRAFANA_RBR_VER_CLIENT_SECRET_HASH="${AUTHELIA_GRAFANA_RBR_VER_CLIENT_SECRET_HASH}" \
AUTHELIA_GRAFANA_MONITORING_CLIENT_SECRET_HASH="${AUTHELIA_GRAFANA_MONITORING_CLIENT_SECRET_HASH}" \
envsubst '${AUTHELIA_HOST} ${AUTHELIA_PORT} ${HOST_IP_DASHED} ${AUTHELIA_JWT_SECRET} ${AUTHELIA_SESSION_SECRET} ${AUTHELIA_STORAGE_ENCRYPTION_KEY} ${AUTHELIA_OIDC_HMAC_SECRET} ${VAULT_HOST} ${VAULT_PORT} ${STEP_CA_HOST} ${STEP_CA_PORT} ${TRAEFIK_IP_DASHED} ${AUTHELIA_VAULT_CLIENT_SECRET_HASH} ${AUTHELIA_STEP_CA_CLIENT_SECRET_HASH} ${AUTHELIA_GRAFANA_RBR_VER_CLIENT_SECRET_HASH} ${AUTHELIA_GRAFANA_MONITORING_CLIENT_SECRET_HASH}' \
    < "${CONFIG_TEMPLATE}" \
    | sudo tee "${AUTHELIA_CONFIG_DIR}/configuration.yaml" > /dev/null

AUTHELIA_STATIC_PASSWORD_HASH="${AUTHELIA_STATIC_PASSWORD_HASH}" \
AUTHELIA_RBR_ADMIN_PASSWORD_HASH="${AUTHELIA_RBR_ADMIN_PASSWORD_HASH}" \
AUTHELIA_RBR_VER_ADMIN_PASSWORD_HASH="${AUTHELIA_RBR_VER_ADMIN_PASSWORD_HASH}" \
AUTHELIA_UNRELATED_PASSWORD_HASH="${AUTHELIA_UNRELATED_PASSWORD_HASH}" \
envsubst '${AUTHELIA_STATIC_PASSWORD_HASH} ${AUTHELIA_RBR_ADMIN_PASSWORD_HASH} ${AUTHELIA_RBR_VER_ADMIN_PASSWORD_HASH} ${AUTHELIA_UNRELATED_PASSWORD_HASH}' \
    < "${AUTHELIA_CONFIG_DIR}/users_database.yml.tpl" \
    | sudo tee "${AUTHELIA_CONFIG_DIR}/users_database.yml" > /dev/null

SECURITY_OPTS=""
[ "$CONTAINER_PROVIDER" = "podman" ] && SECURITY_OPTS="--security-opt label=disable"

echo "🚀 Starting Authelia container..."
${CONTAINER_PROVIDER} run -d \
    --name "${AUTHELIA_CONTAINER_NAME}" \
    --network bridge \
    ${SECURITY_OPTS} \
    -e X_AUTHELIA_CONFIG_FILTERS=template \
    -p "${AUTHELIA_PORT}:${AUTHELIA_PORT}" \
    -v "${AUTHELIA_CONFIG_DIR}/configuration.yaml:/config/configuration.yml:ro" \
    -v "${AUTHELIA_CONFIG_DIR}/users_database.yml:/config/users_database.yml:ro" \
    -v "${AUTHELIA_TLS_DIR}:/config/tls:ro" \
    -v "${AUTHELIA_SECRETS_DIR}:/config/secrets:ro" \
    "${AUTHELIA_IMAGE}"

# Poll OIDC discovery endpoint for readiness
echo "⏳ Waiting for Authelia OIDC endpoint..."
DISCOVERY_URL="https://${AUTHELIA_HOST}:${AUTHELIA_PORT}/.well-known/openid-configuration"
MAX_RETRIES=30; COUNT=0
while [ $COUNT -lt $MAX_RETRIES ]; do
    if curl -sf --cacert "${AUTHELIA_TLS_DIR}/ca-chain.pem" "${DISCOVERY_URL}" > /dev/null 2>&1; then
        echo "✅ Authelia is ready at https://${AUTHELIA_HOST}:${AUTHELIA_PORT}"
        break
    fi
    sleep 5
    COUNT=$((COUNT + 1))
done
if [ $COUNT -eq $MAX_RETRIES ]; then
    echo "❌ Authelia did not become ready."
    exit 1
fi
