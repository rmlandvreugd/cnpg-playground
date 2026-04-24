#!/usr/bin/env bash
#
# This script tears down the Vault setup for the CloudNativePG playground.
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

# Use variables from common.sh or defaults
VAULT_CONTAINER_NAME="${VAULT_CONTAINER_NAME:-vault}"
VAULT_DIR="${GIT_REPO_ROOT}/vault"

echo "🔥 Tearing down Vault..."

# Stop and remove the container
if ${CONTAINER_PROVIDER} ps -a --format '{{.Names}}' | grep -q "^${VAULT_CONTAINER_NAME}$"; then
    echo "🗑️ Removing Vault container '${VAULT_CONTAINER_NAME}'..."
    ${CONTAINER_PROVIDER} rm -f "${VAULT_CONTAINER_NAME}" > /dev/null
else
    echo "🔷 Vault container '${VAULT_CONTAINER_NAME}' not found, skipping."
fi

# Clean up directories
echo "🧹 Cleaning up Vault directories (data, logs, certs)..."
sudo rm -rf "${VAULT_DIR}/data"
sudo rm -rf "${VAULT_DIR}/logs"
sudo rm -rf "${VAULT_DIR}/certs"

# Remove the unseal key file
if [ -f "${VAULT_DIR}/.unseal_key" ]; then
    echo "🧹 Removing .unseal_key file..."
    rm -f "${VAULT_DIR}/.unseal_key"
fi

# Remove the root token file
if [ -f "${VAULT_DIR}/.root_token" ]; then
    echo "🧹 Removing .root_token file..."
    rm -f "${VAULT_DIR}/.root_token"
fi

echo "✅ Vault teardown complete!"
