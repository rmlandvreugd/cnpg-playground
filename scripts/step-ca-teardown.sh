#!/usr/bin/env bash
#
# This script tears down the step-ca setup for the CloudNativePG playground.
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

echo "🔥 Tearing down step-ca..."

# Stop and remove the container
if ${CONTAINER_PROVIDER} ps -a --format '{{.Names}}' | grep -q "^${STEP_CA_CONTAINER_NAME}$"; then
    echo "🗑️ Removing step-ca container '${STEP_CA_CONTAINER_NAME}'..."
    ${CONTAINER_PROVIDER} rm -f "${STEP_CA_CONTAINER_NAME}" > /dev/null
else
    echo "🔷 step-ca container '${STEP_CA_CONTAINER_NAME}' not found, skipping."
fi

# Clean up directories (preserve .gitkeep files for git tracking)
echo "🧹 Cleaning up step-ca directories (pki, secrets, db)..."
sudo rm -rf "${STEP_CA_DIR}/pki"
sudo rm -rf "${STEP_CA_DIR}/secrets"
sudo rm -rf "${STEP_CA_DIR}/db"
mkdir -p "${STEP_CA_DIR}/pki" "${STEP_CA_DIR}/secrets"

# Clean up generated config files (keep templates)
sudo rm -f "${STEP_CA_DIR}/config/ca.json"
sudo rm -f "${STEP_CA_DIR}/config/defaults.json"
sudo rm -f "${STEP_CA_DIR}/config/ca.json.override"

echo "✅ step-ca teardown complete!"
