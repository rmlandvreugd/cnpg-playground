#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GIT_REPO_ROOT=$(git rev-parse --show-toplevel)
source "${GIT_REPO_ROOT}/scripts/common.sh"

VAULT_DIR="${GIT_REPO_ROOT}/vault"
DEMO_YAML="${GIT_REPO_ROOT}/demo/yaml"

SUBCOMMAND="${1:-}"
MODE="${2:-}"

usage() {
    echo "Usage: $0 <setup|rotate|verify|teardown> local [target]"
    echo "  setup   local                          — seed Vault + deploy ESO-backed CNPG cluster"
    echo "  rotate  local <superuser|app|readonly> — rotate a credential in Vault + force ESO sync"
    echo "  verify  local <superuser|app|readonly> — test psql connectivity with current credentials"
    echo "  teardown local                         — remove demo-local-db ns + Vault KV paths"
    exit 1
}

[ -z "${SUBCOMMAND}" ] && usage
[ "${MODE}" != "local" ] && { echo "❌ Only 'local' mode is supported in this iteration."; exit 1; }

export KUBECONFIG="${GIT_REPO_ROOT}/k8s/kube-config.yaml"
LOCAL_CONTEXT=$(get_cluster_context "local")

ROOT_TOKEN=$(sudo cat "${VAULT_DIR}/.root_token")

_vcmd() {
    ${CONTAINER_PROVIDER} exec \
        -e VAULT_ADDR="https://127.0.0.1:${VAULT_PORT}" \
        -e VAULT_CACERT=/vault/certs/vault-ca.pem \
        -e VAULT_TOKEN="${ROOT_TOKEN}" \
        "${VAULT_CONTAINER_NAME}" \
        vault "$@"
}

# Waits up to <timeout>s for an ExternalSecret to reach Ready=True.
wait_for_external_secret() {
    local name="$1" ns="$2" timeout="${3:-120}" elapsed=0
    echo "⏳ Waiting for ExternalSecret ${name} to sync..."
    while [ "${elapsed}" -lt "${timeout}" ]; do
        status=$(kubectl get externalsecret "${name}" -n "${ns}" \
            -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' \
            --context "${LOCAL_CONTEXT}" 2>/dev/null || echo "")
        [ "${status}" = "True" ] && { echo "  ✅ ${name} synced"; return 0; }
        sleep 5; elapsed=$((elapsed + 5))
    done
    echo "❌ Timeout: ExternalSecret ${name} not ready after ${timeout}s"
    exit 1
}

# Runs a psql connectivity test for <target> using the current k8s Secret.
# Returns 0 on success, 1 on failure.
verify_connectivity() {
    local target="$1"
    local secret_name="pg-local-${target}"
    local svc="pg-local-rw"
    local db="app"
    [ "${target}" = "superuser" ] && db="postgres"

    echo "🔎 Verifying connectivity for '${target}'..."
    USERNAME=$(kubectl get secret "${secret_name}" \
        -n "${CNPG_DEMO_NAMESPACE}" \
        --context "${LOCAL_CONTEXT}" \
        -o jsonpath='{.data.username}' | base64 -d)
    PASSWORD=$(kubectl get secret "${secret_name}" \
        -n "${CNPG_DEMO_NAMESPACE}" \
        --context "${LOCAL_CONTEXT}" \
        -o jsonpath='{.data.password}' | base64 -d)

    if kubectl exec -n "${CNPG_DEMO_NAMESPACE}" pg-local-1 \
            --context "${LOCAL_CONTEXT}" -- \
            env PGPASSWORD="${PASSWORD}" \
            psql -h "${svc}" -U "${USERNAME}" -d "${db}" -c '\conninfo' \
            > /dev/null 2>&1; then
        echo "  ✅ Connected as ${USERNAME} to ${db} via ${svc}"
        return 0
    else
        echo "  ❌ Connection failed for ${USERNAME} to ${db}"
        return 1
    fi
}

# Generate a URL-safe random password (32 chars).
random_password() {
    openssl rand -base64 32 | tr -d '/+=' | head -c 32
}

case "${SUBCOMMAND}" in

setup)
    echo "=================================================="
    echo "🚀 ESO + Vault demo setup (local)"
    echo "=================================================="

    echo "📝 Writing seed credentials to Vault cnpg/ KV..."
    _vcmd kv put cnpg/pg-local/superuser \
        username=postgres \
        password="$(random_password)"
    _vcmd kv put cnpg/pg-local/app \
        username=app \
        password="$(random_password)"
    _vcmd kv put cnpg/pg-local/readonly \
        username=readonly \
        password="$(random_password)"
    echo "✅ Vault credentials written"

    echo "📁 Creating namespace ${CNPG_DEMO_NAMESPACE}..."
    kubectl create namespace "${CNPG_DEMO_NAMESPACE}" \
        --context "${LOCAL_CONTEXT}" \
        --dry-run=client -o yaml \
        | kubectl apply --context "${LOCAL_CONTEXT}" -f -

    echo "📋 Applying ExternalSecrets..."
    for es in superuser app readonly; do
        kubectl apply \
            --context "${LOCAL_CONTEXT}" \
            -f "${DEMO_YAML}/local/externalsecret-pg-local-${es}.yaml"
    done

    echo "⏳ Waiting for ExternalSecrets to sync..."
    for es in superuser app readonly; do
        wait_for_external_secret "pg-local-${es}" "${CNPG_DEMO_NAMESPACE}"
    done

    echo "🐘 Applying CNPG Cluster (pg-local-eso)..."
    CNPG_DEMO_NAMESPACE="${CNPG_DEMO_NAMESPACE}" \
    envsubst '${CNPG_DEMO_NAMESPACE}' \
        < "${DEMO_YAML}/local/pg-local-eso.yaml.tpl" \
        | kubectl apply --context "${LOCAL_CONTEXT}" -f -

    echo "⏳ Waiting for pg-local cluster to be Ready (up to 30m)..."
    kubectl wait \
        --context "${LOCAL_CONTEXT}" \
        --timeout 30m \
        --for=condition=Ready \
        cluster/pg-local \
        -n "${CNPG_DEMO_NAMESPACE}"

    echo ""
    echo "✅ ESO demo setup complete!"
    echo "   Cluster: pg-local  Namespace: ${CNPG_DEMO_NAMESPACE}"
    echo "   Credentials managed by Vault at cnpg/pg-local/{superuser,app,readonly}"
    ;;

rotate)
    TARGET="${3:-}"
    case "${TARGET}" in
        superuser|app|readonly) ;;
        *) echo "❌ target must be one of: superuser app readonly"; usage ;;
    esac

    echo "🔄 Rotating '${TARGET}' credential in Vault..."
    NEW_PASSWORD="$(random_password)"
    _vcmd kv patch "cnpg/pg-local/${TARGET}" password="${NEW_PASSWORD}"

    echo "⚡ Forcing immediate ESO sync for pg-local-${TARGET}..."
    kubectl annotate externalsecret "pg-local-${TARGET}" \
        -n "${CNPG_DEMO_NAMESPACE}" \
        --context "${LOCAL_CONTEXT}" \
        --overwrite \
        force-sync="$(date +%s)"

    echo "⏳ Waiting for k8s Secret to update..."
    OLD_VERSION=$(kubectl get secret "pg-local-${TARGET}" \
        -n "${CNPG_DEMO_NAMESPACE}" \
        --context "${LOCAL_CONTEXT}" \
        -o jsonpath='{.metadata.resourceVersion}')
    MAX_WAIT=60; ELAPSED=0
    while [ "${ELAPSED}" -lt "${MAX_WAIT}" ]; do
        NEW_VERSION=$(kubectl get secret "pg-local-${TARGET}" \
            -n "${CNPG_DEMO_NAMESPACE}" \
            --context "${LOCAL_CONTEXT}" \
            -o jsonpath='{.metadata.resourceVersion}' 2>/dev/null || echo "")
        [ "${NEW_VERSION}" != "${OLD_VERSION}" ] && break
        sleep 3; ELAPSED=$((ELAPSED + 3))
    done
    [ "${ELAPSED}" -ge "${MAX_WAIT}" ] && { echo "❌ Secret did not update within ${MAX_WAIT}s"; exit 1; }
    echo "  ✅ k8s Secret updated (resourceVersion: ${OLD_VERSION} → ${NEW_VERSION})"

    verify_connectivity "${TARGET}"
    ;;

verify)
    TARGET="${3:-}"
    case "${TARGET}" in
        superuser|app|readonly) ;;
        *) echo "❌ target must be one of: superuser app readonly"; usage ;;
    esac
    verify_connectivity "${TARGET}"
    ;;

teardown)
    echo "=================================================="
    echo "🔥 ESO demo teardown (local) — narrow scope"
    echo "=================================================="

    echo "🗑️ Deleting namespace ${CNPG_DEMO_NAMESPACE} (includes all CNPG + ESO resources)..."
    kubectl delete namespace "${CNPG_DEMO_NAMESPACE}" \
        --context "${LOCAL_CONTEXT}" \
        --ignore-not-found

    echo "🗑️ Deleting Vault KV paths for pg-local..."
    for cred in superuser app readonly; do
        _vcmd kv delete "cnpg/pg-local/${cred}" 2>/dev/null \
            || echo "  cnpg/pg-local/${cred} not found, skipping"
    done

    echo "✅ Demo teardown complete."
    echo "   ESO infra (ClusterSecretStore, AppRole, cnpg/ mount) retained."
    echo "   Run scripts/teardown.sh to remove the full environment."
    ;;

*)
    usage
    ;;
esac
