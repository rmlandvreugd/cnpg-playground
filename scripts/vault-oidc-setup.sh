#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

VAULT_DIR="${GIT_REPO_ROOT}/vault"
DEX_DIR="${GIT_REPO_ROOT}/dex"

echo "🔑 Configuring Vault OIDC auth with Dex..."

HOST_IP=$(hostname -I | awk '{print $1}')
HOST_IP_DASHED=$(echo "$HOST_IP" | tr '.' '-')
DEX_HOST="dex.${HOST_IP_DASHED}.sslip.io"
VAULT_HOST="vault.${HOST_IP_DASHED}.sslip.io"

# Obtain admin token via userpass (demonstrates admin credentials, not root token)
echo "🔐 Logging in as ${VAULT_ADMIN_USER}..."
ADMIN_TOKEN=$(${CONTAINER_PROVIDER} exec \
    -e VAULT_ADDR="https://127.0.0.1:${VAULT_PORT}" \
    -e VAULT_CACERT=/vault/certs/vault-ca.pem \
    "${VAULT_CONTAINER_NAME}" \
    vault write -field=token \
    auth/userpass/login/"${VAULT_ADMIN_USER}" \
    password="${VAULT_ADMIN_PASSWORD}")

_vcmd() {
    ${CONTAINER_PROVIDER} exec \
        -e VAULT_ADDR="https://127.0.0.1:${VAULT_PORT}" \
        -e VAULT_CACERT=/vault/certs/vault-ca.pem \
        -e VAULT_TOKEN="${ADMIN_TOKEN}" \
        "${VAULT_CONTAINER_NAME}" \
        vault "$@"
}
_vcmd_stdin() {
    ${CONTAINER_PROVIDER} exec -i \
        -e VAULT_ADDR="https://127.0.0.1:${VAULT_PORT}" \
        -e VAULT_CACERT=/vault/certs/vault-ca.pem \
        -e VAULT_TOKEN="${ADMIN_TOKEN}" \
        "${VAULT_CONTAINER_NAME}" \
        vault "$@"
}

echo "🔓 Enabling OIDC auth method..."
_vcmd auth enable oidc

# Pass ca-chain.pem inline via stdin — avoids host-file-path issues with container exec
echo "📋 Configuring OIDC provider (Dex)..."
sudo cat "${DEX_DIR}/tls/ca-chain.pem" \
    | ${CONTAINER_PROVIDER} exec -i \
        -e VAULT_ADDR="https://127.0.0.1:${VAULT_PORT}" \
        -e VAULT_CACERT=/vault/certs/vault-ca.pem \
        -e VAULT_TOKEN="${ADMIN_TOKEN}" \
        "${VAULT_CONTAINER_NAME}" \
        vault write auth/oidc/config \
        oidc_discovery_url="https://${DEX_HOST}:${DEX_PORT}/dex" \
        oidc_discovery_ca_pem=@- \
        oidc_client_id="${DEX_OIDC_CLIENT_ID}" \
        oidc_client_secret="${DEX_OIDC_CLIENT_SECRET}" \
        default_role="oidc-user"

echo "📋 Creating oidc-policy..."
cat <<'EOF' | _vcmd_stdin policy write oidc-policy -
path "secret/data/common/*" { capabilities = ["read","list"] }
EOF

echo "📋 Creating oidc-user role..."
_vcmd write auth/oidc/role/oidc-user \
    bound_audiences="${DEX_OIDC_CLIENT_ID}" \
    allowed_redirect_uris="https://127.0.0.1:${VAULT_PORT}/ui/vault/auth/oidc/oidc/callback" \
    allowed_redirect_uris="https://localhost:8250/oidc/callback" \
    allowed_redirect_uris="https://${VAULT_HOST}:${VAULT_PORT}/ui/vault/auth/oidc/oidc/callback" \
    user_claim="sub" \
    token_policies="oidc-policy"

echo "✅ OIDC integration complete."
echo "🌐 Login: https://${VAULT_HOST}:${VAULT_PORT}/ui → OIDC → user@example.com / password"
