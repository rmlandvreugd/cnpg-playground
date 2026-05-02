#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

# REGION and CONTEXT_NAME are passed in from setup.sh's region loop via
# the calling scope (setup.sh sources common.sh and sets these before calling us).
# Callers must export REGION and CONTEXT_NAME before invoking this script.
: "${REGION:?REGION must be set}"
: "${CONTEXT_NAME:?CONTEXT_NAME must be set}"

VAULT_DIR="${GIT_REPO_ROOT}/vault"

echo "🔌 Setting up ESO for region '${REGION}' (context: ${CONTEXT_NAME})..."

ROOT_TOKEN=$(sudo cat "${VAULT_DIR}/.root_token")

_vcmd() {
    ${CONTAINER_PROVIDER} exec \
        -e VAULT_ADDR="https://127.0.0.1:${VAULT_PORT}" \
        -e VAULT_CACERT=/vault/certs/vault-ca.pem \
        -e VAULT_TOKEN="${ROOT_TOKEN}" \
        "${VAULT_CONTAINER_NAME}" \
        vault "$@"
}

# --- Vault: AppRole role for this cluster ---
echo "🔑 Creating Vault AppRole role 'eso-${REGION}'..."
_vcmd write "auth/approle/role/eso-${REGION}" \
    token_policies=eso-cnpg \
    secret_id_ttl=0 \
    token_ttl=1h \
    token_max_ttl=4h

ROLE_ID=$(_vcmd read -field=role_id "auth/approle/role/eso-${REGION}/role-id")
SECRET_ID=$(_vcmd write -field=secret_id -f "auth/approle/role/eso-${REGION}/secret-id")

echo "${ROLE_ID}"   | sudo tee "${VAULT_DIR}/.eso_${REGION}_role_id"   > /dev/null
echo "${SECRET_ID}" | sudo tee "${VAULT_DIR}/.eso_${REGION}_secret_id" > /dev/null
sudo chmod 640 "${VAULT_DIR}/.eso_${REGION}_role_id" \
               "${VAULT_DIR}/.eso_${REGION}_secret_id"

echo "✅ AppRole eso-${REGION} created (role_id: ${ROLE_ID})"

# --- Install ESO via Helm (only method that supports a custom namespace) ---
echo "📦 Installing ESO ${ESO_VERSION} in '${CONTEXT_NAME}' (namespace: ${ESO_NAMESPACE})..."
helm_upgrade_install external-secrets external-secrets \
    "${ESO_NAMESPACE}" "${CONTEXT_NAME}" "${ESO_CHART_VERSION}" \
    --repo-url https://charts.external-secrets.io

echo "⏳ Waiting for ESO CRDs to be established..."
kubectl wait --for=condition=Established \
    crd/clustersecretstores.external-secrets.io \
    crd/externalsecrets.external-secrets.io \
    --timeout=60s \
    --context "${CONTEXT_NAME}"

# --- K8s secret for ClusterSecretStore AppRole credentials ---
echo "🔑 Creating vault-approle-creds Secret in ${ESO_NAMESPACE}..."
kubectl create secret generic vault-approle-creds \
    --namespace "${ESO_NAMESPACE}" \
    --context "${CONTEXT_NAME}" \
    --from-literal=roleId="${ROLE_ID}" \
    --from-literal=secretId="${SECRET_ID}" \
    --dry-run=client -o yaml \
    | kubectl apply --context "${CONTEXT_NAME}" -f -

# --- ClusterSecretStore ---
echo "📋 Applying ClusterSecretStore (vault-approle)..."
ESO_NAMESPACE="${ESO_NAMESPACE}" \
VAULT_HTTP_PORT="${VAULT_HTTP_PORT}" \
envsubst '${ESO_NAMESPACE} ${VAULT_HTTP_PORT}' \
    < "${GIT_REPO_ROOT}/vault/eso/clustersecretstore.yaml.tpl" \
    | kubectl --context "${CONTEXT_NAME}" apply -f -

echo "✅ ESO setup complete for region '${REGION}'"
