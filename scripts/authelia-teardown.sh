#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

AUTHELIA_DIR="${GIT_REPO_ROOT}/authelia"

echo "🔥 Tearing down Authelia..."

if ${CONTAINER_PROVIDER} ps -a --format '{{.Names}}' | grep -q "^${AUTHELIA_CONTAINER_NAME}$"; then
    echo "🗑️ Removing Authelia container '${AUTHELIA_CONTAINER_NAME}'..."
    ${CONTAINER_PROVIDER} rm -f "${AUTHELIA_CONTAINER_NAME}" > /dev/null
else
    echo "🔷 Authelia container '${AUTHELIA_CONTAINER_NAME}' not found, skipping."
fi

echo "🧹 Cleaning up Authelia runtime files (tls/, secrets/, generated configs)..."
sudo rm -rf "${AUTHELIA_DIR}/tls"
sudo rm -rf "${AUTHELIA_DIR}/secrets"
sudo rm -f  "${AUTHELIA_DIR}/config/configuration.yaml"
sudo rm -f  "${AUTHELIA_DIR}/config/users_database.yml"

echo "✅ Authelia teardown complete!"
