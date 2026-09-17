#!/usr/bin/env bash
#
# Sets up zot as an on-demand pull-through registry cache + push target,
# fronted by the external edge Traefik. Blobs live in SeaweedFS S3; local
# boltdb (in the zot-meta volume) holds only the dedupe cache + metadata DB.
# See docs/zot-registry-stacker-plan.md (Design A).
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

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

ZOT_DIR="${GIT_REPO_ROOT}/zot"

echo "🚀 Setting up zot registry..."

sudo mkdir -p "${ZOT_DIR}"

# htpasswd (bcrypt) for the 'ci' push user. Generated via a throwaway httpd
# container so the host doesn't need the apache2-utils/httpd package.
echo "🔒 Generating zot htpasswd for '${ZOT_CI_USER}'..."
${CONTAINER_PROVIDER} run --rm httpd:2.4-alpine \
    htpasswd -Bbn "${ZOT_CI_USER}" "${ZOT_CI_PASSWORD}" \
    | sudo tee "${ZOT_DIR}/htpasswd" > /dev/null

echo "📝 Rendering zot config..."
SEAWEEDFS_ZOT_BUCKET="${SEAWEEDFS_ZOT_BUCKET}" \
SEAWEEDFS_ZOT_ACCESS_KEY="${SEAWEEDFS_ZOT_ACCESS_KEY}" \
SEAWEEDFS_ZOT_SECRET_KEY="${SEAWEEDFS_ZOT_SECRET_KEY}" \
ZOT_PORT="${ZOT_PORT}" \
ZOT_HOST="${ZOT_HOST}" \
ZOT_CI_USER="${ZOT_CI_USER}" \
envsubst '${SEAWEEDFS_ZOT_BUCKET} ${SEAWEEDFS_ZOT_ACCESS_KEY} ${SEAWEEDFS_ZOT_SECRET_KEY} ${ZOT_PORT} ${ZOT_HOST} ${ZOT_CI_USER}' \
    < "${ZOT_DIR}/config.json.tpl" \
    | sudo tee "${ZOT_DIR}/config.json" > /dev/null

echo "🔄 Starting zot registry (${ZOT_CONTAINER_NAME} @ ${ZOT_IP})..."
${CONTAINER_PROVIDER} volume create zot-meta > /dev/null
${CONTAINER_PROVIDER} stop "${ZOT_CONTAINER_NAME}" 2>/dev/null || true
${CONTAINER_PROVIDER} rm   "${ZOT_CONTAINER_NAME}" 2>/dev/null || true
${CONTAINER_PROVIDER} run -d --name "${ZOT_CONTAINER_NAME}" \
    --network kind --ip "${ZOT_IP}" \
    -v "${ZOT_DIR}/config.json:/etc/zot/config.json:ro" \
    -v "${ZOT_DIR}/htpasswd:/etc/zot/htpasswd:ro" \
    -v zot-meta:/var/lib/zot \
    --restart unless-stopped \
    "${ZOT_IMAGE}"

echo "✅ zot: https://${ZOT_HOST} (anonymous read, '${ZOT_CI_USER}' push on apps/**)"
