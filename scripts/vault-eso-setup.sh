#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

VAULT_DIR="${GIT_REPO_ROOT}/vault"

echo "🔐 Configuring Vault for ESO (cnpg/ KV mount + policy)..."

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

echo "📦 Enabling cnpg/ KV v2 mount..."
_vcmd secrets enable -path=cnpg kv-v2 2>/dev/null \
    || echo "  cnpg/ already enabled, continuing"

echo "📋 Writing eso-cnpg policy..."
cat <<'EOF' | _vcmd_stdin policy write eso-cnpg -
path "cnpg/data/*"     { capabilities = ["read"] }
path "cnpg/metadata/*" { capabilities = ["read", "list"] }
EOF

echo "✅ Vault ESO infra ready (cnpg/ KV + eso-cnpg policy)"
