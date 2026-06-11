#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

VAULT_DIR="${GIT_REPO_ROOT}/vault"
AUTHELIA_DIR="${GIT_REPO_ROOT}/authelia"

echo "🔑 Configuring Vault OIDC auth with Authelia..."

HOST_IP=$(hostname -I | awk '{print $1}')
HOST_IP_DASHED=$(echo "$HOST_IP" | tr '.' '-')
AUTHELIA_HOST="authelia.${HOST_IP_DASHED}.sslip.io"
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

echo "🔓 Enabling OIDC auth method (idempotent)..."
_vcmd auth enable oidc 2>/dev/null || true

# Pass ca-chain.pem inline via stdin — avoids host-file-path issues with container exec
echo "📋 Configuring OIDC provider (Authelia)..."
sudo cat "${AUTHELIA_DIR}/tls/ca-chain.pem" \
    | ${CONTAINER_PROVIDER} exec -i \
        -e VAULT_ADDR="https://127.0.0.1:${VAULT_PORT}" \
        -e VAULT_CACERT=/vault/certs/vault-ca.pem \
        -e VAULT_TOKEN="${ADMIN_TOKEN}" \
        "${VAULT_CONTAINER_NAME}" \
        vault write auth/oidc/config \
        oidc_discovery_url="https://${AUTHELIA_HOST}:${AUTHELIA_PORT}" \
        oidc_discovery_ca_pem=- \
        oidc_client_id="vault" \
        oidc_client_secret="${AUTHELIA_VAULT_CLIENT_SECRET}" \
        default_role="oidc-user"

echo "📋 Creating oidc-policy (base read for all OIDC users)..."
cat <<'EOF' | _vcmd_stdin policy write oidc-policy -
path "secret/data/common/*" { capabilities = ["read","list"] }
EOF

echo "📋 Creating vault-admin policy (full superuser access)..."
cat <<'EOF' | _vcmd_stdin policy write vault-admin -
path "*" {
  capabilities = ["create", "read", "update", "delete", "list", "sudo"]
}
EOF

echo "📋 Creating oidc-user role (groups_claim enables group→policy mapping)..."
_vcmd write auth/oidc/role/oidc-user \
    bound_audiences="vault" \
    allowed_redirect_uris="https://127.0.0.1:${VAULT_PORT}/ui/vault/auth/oidc/oidc/callback" \
    allowed_redirect_uris="https://localhost:8250/oidc/callback" \
    allowed_redirect_uris="https://${VAULT_HOST}:${VAULT_PORT}/ui/vault/auth/oidc/oidc/callback" \
    user_claim="email" \
    groups_claim="groups" \
    oidc_scopes="openid,email,profile,groups" \
    token_policies="oidc-policy"

echo "📋 Creating vault-admin identity group (maps Authelia 'vault-admin' group → vault-admin policy)..."
GROUP_ID=$(_vcmd write -field=id identity/group \
    name="vault-admin" \
    type="external" \
    policies="vault-admin")

OIDC_ACCESSOR=$(_vcmd read -field=accessor sys/auth/oidc)

_vcmd write identity/group-alias \
    name="vault-admin" \
    mount_accessor="${OIDC_ACCESSOR}" \
    canonical_id="${GROUP_ID}"

echo "✅ OIDC integration complete."
echo "🌐 Login: https://${VAULT_HOST}:${VAULT_PORT}/ui → OIDC → admin@example.com / password"
echo "   Users in Authelia 'vault-admin' group get full Vault superuser access."
