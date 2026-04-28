#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

DEX_DIR="${GIT_REPO_ROOT}/dex"

echo "🔥 Tearing down Dex..."

if ${CONTAINER_PROVIDER} ps -a --format '{{.Names}}' | grep -q "^${DEX_CONTAINER_NAME}$"; then
    echo "🗑️ Removing Dex container '${DEX_CONTAINER_NAME}'..."
    ${CONTAINER_PROVIDER} rm -f "${DEX_CONTAINER_NAME}" > /dev/null
else
    echo "🔷 Dex container '${DEX_CONTAINER_NAME}' not found, skipping."
fi

echo "🧹 Cleaning up Dex runtime files (tls/, generated config)..."
sudo rm -rf "${DEX_DIR}/tls"
sudo rm -f  "${DEX_DIR}/config/dex-config.yaml"

echo "✅ Dex teardown complete!"
