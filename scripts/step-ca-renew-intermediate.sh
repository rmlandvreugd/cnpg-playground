#!/usr/bin/env bash
#
# Renew step-ca's intermediate CA certificate.
# The intermediate CA cert is signed by the root CA; this script generates
# a new CSR from the existing intermediate key, signs it with the root CA,
# and replaces the certificate in-place. step-ca is then reloaded.
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

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

STEP_CA_DIR="${GIT_REPO_ROOT}/step-ca"
STEP_CA_PKI_DIR="${STEP_CA_DIR}/pki"
STEP_CA_SECRETS_DIR="${STEP_CA_DIR}/secrets"

echo "🔄 Renewing step-ca intermediate CA certificate..."

# --- Pre-flight checks ---
if ! ${CONTAINER_PROVIDER} ps --format '{{.Names}}' | grep -q "^${STEP_CA_CONTAINER_NAME}$"; then
    echo "❌ Error: step-ca container '${STEP_CA_CONTAINER_NAME}' is not running."
    exit 1
fi

if [ ! -f "${STEP_CA_PKI_DIR}/intermediate_ca.crt" ]; then
    echo "❌ Error: Intermediate CA certificate not found at ${STEP_CA_PKI_DIR}/intermediate_ca.crt"
    exit 1
fi

# --- Show current certificate info ---
echo "📋 Current intermediate CA certificate:"
openssl x509 -in "${STEP_CA_PKI_DIR}/intermediate_ca.crt" -noout -subject -dates -issuer 2>/dev/null || \
    ${CONTAINER_PROVIDER} exec "${STEP_CA_CONTAINER_NAME}" \
        step certificate inspect /home/step/certs/intermediate_ca.crt --format json 2>/dev/null | \
        jq -r '.subject.common_name, .validity.start, .validity.end'

# --- Generate a new CSR from the existing intermediate key ---
# (step certificate create needs a TTY, so we use openssl on the host)
echo "📜 Generating new CSR from existing intermediate key..."
STEP_CA_PASSWORD=$(${CONTAINER_PROVIDER} exec "${STEP_CA_CONTAINER_NAME}" cat /home/step/secrets/password)

INT_KEY_TMPFILE=$(mktemp)
${CONTAINER_PROVIDER} cp "${STEP_CA_CONTAINER_NAME}:/home/step/secrets/intermediate_ca_key" "${INT_KEY_TMPFILE}"

CSR_TMPFILE=$(mktemp)
openssl req -new \
    -key "${INT_KEY_TMPFILE}" \
    -passin "pass:${STEP_CA_PASSWORD}" \
    -subj "/O=CloudNativePG Playground CA/CN=CloudNativePG Playground CA Intermediate CA" \
    -out "${CSR_TMPFILE}"

# --- Sign the new CSR with the root CA ---
echo "📜 Signing new intermediate certificate with root CA..."

# Copy root CA cert and key to temp files for openssl
ROOT_CERT_TMPFILE=$(mktemp)
ROOT_KEY_TMPFILE=$(mktemp)
${CONTAINER_PROVIDER} exec "${STEP_CA_CONTAINER_NAME}" cat /home/step/certs/root_ca.crt > "${ROOT_CERT_TMPFILE}"
${CONTAINER_PROVIDER} cp "${STEP_CA_CONTAINER_NAME}:/home/step/secrets/root_ca_key" "${ROOT_KEY_TMPFILE}"

# Sign with openssl (5 years = 1825 days)
SIGNED_TMPFILE=$(mktemp)
EXT_TMPFILE=$(mktemp)
printf "basicConstraints=critical,CA:TRUE,pathlen:0\nkeyUsage=critical,digitalSignature,keyCertSign,cRLSign" > "${EXT_TMPFILE}"

openssl x509 -req -in "${CSR_TMPFILE}" \
    -CA "${ROOT_CERT_TMPFILE}" \
    -CAkey "${ROOT_KEY_TMPFILE}" \
    -CAcreateserial \
    -days 1825 \
    -passin "pass:${STEP_CA_PASSWORD}" \
    -extfile "${EXT_TMPFILE}" \
    -out "${SIGNED_TMPFILE}" 2>&1

# --- Backup the old certificate ---
BACKUP_DIR="${STEP_CA_PKI_DIR}/backups"
sudo mkdir -p "${BACKUP_DIR}"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
sudo cp "${STEP_CA_PKI_DIR}/intermediate_ca.crt" "${BACKUP_DIR}/intermediate_ca.crt.${TIMESTAMP}"
echo "📋 Backed up old certificate to ${BACKUP_DIR}/intermediate_ca.crt.${TIMESTAMP}"

# --- Replace the certificate ---
echo "🔄 Replacing intermediate CA certificate..."

# Copy the new cert into the container's certs directory via temp file
NEW_CERT_TMPFILE=$(mktemp)
cp "${SIGNED_TMPFILE}" "${NEW_CERT_TMPFILE}"
sudo cp "${SIGNED_TMPFILE}" "${STEP_CA_PKI_DIR}/intermediate_ca.crt"
sudo chmod 644 "${STEP_CA_PKI_DIR}/intermediate_ca.crt"

# Also update inside the container
${CONTAINER_PROVIDER} cp "${SIGNED_TMPFILE}" "${STEP_CA_CONTAINER_NAME}:/home/step/certs/intermediate_ca.crt"

# --- Reload step-ca ---
echo "🔄 Reloading step-ca to pick up the new certificate..."
${CONTAINER_PROVIDER} exec "${STEP_CA_CONTAINER_NAME}" kill -HUP 1

# --- Verify ---
echo "⏳ Waiting for step-ca to reload..."
sleep 2

MAX_RETRIES=15
COUNT=0
while [ $COUNT -lt $MAX_RETRIES ]; do
    if ${CONTAINER_PROVIDER} exec \
        -e STEPPATH=/home/step \
        "${STEP_CA_CONTAINER_NAME}" \
        step ca health --ca-url "https://localhost:${STEP_CA_PORT}" \
        --root /home/step/certs/root_ca.crt 2>/dev/null; then
        echo "✅ step-ca is healthy after renewal"
        break
    fi
    sleep 2
    COUNT=$((COUNT + 1))
done

if [ $COUNT -eq $MAX_RETRIES ]; then
    echo "❌ Error: step-ca did not become healthy after certificate renewal."
    exit 1
fi

# --- Show new certificate info ---
echo "📋 New intermediate CA certificate:"
openssl x509 -in "${STEP_CA_PKI_DIR}/intermediate_ca.crt" -noout -subject -dates -issuer 2>/dev/null || \
    ${CONTAINER_PROVIDER} exec "${STEP_CA_CONTAINER_NAME}" \
        step certificate inspect /home/step/certs/intermediate_ca.crt --format json 2>/dev/null | \
        jq -r '.subject.common_name, .validity.start, .validity.end'

# --- Cleanup ---
rm -f "${CSR_TMPFILE}" "${INT_KEY_TMPFILE}" "${ROOT_CERT_TMPFILE}" "${ROOT_KEY_TMPFILE}" "${SIGNED_TMPFILE}" "${EXT_TMPFILE}"

echo "✅ step-ca intermediate CA certificate renewed successfully!"