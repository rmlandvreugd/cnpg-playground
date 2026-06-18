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
    echo "Usage: $0 <setup|rotate|verify|connect|connect-mtls|teardown> local [target]"
    echo "  setup   local                          — seed Vault + deploy ESO-backed CNPG cluster"
    echo "  rotate  local <superuser|app> — rotate a credential in Vault + force ESO sync"
    echo "  verify  local <superuser|app> — test psql connectivity with current credentials"
    echo "  connect      local <superuser|app> — print external psql for the -t (TLS-term, password) endpoint"
    echo "  connect-mtls local <superuser|app> — print external psql for the -p (passthrough, cert-auth) endpoint"
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

# Recompute the dashed sslip.io host octet for the Postgres endpoints, independent of
# the setup case: Traefik LB IP, 4th octet +10, dotted → dashed (matches setup, ~L133-135).
traefik_pg_host_dashed() {
    local ip pg_ip
    ip=$(get_traefik_lb_ip "${LOCAL_CONTEXT}") \
        || { echo "❌ Could not resolve Traefik LoadBalancer IP" >&2; exit 1; }
    pg_ip=$(echo "${ip}" | awk -F. '{OFS="."; $4=$4+10; print}')
    ip_to_dashed "${pg_ip}"
}

# Stage a client cert + CA into a fresh temp dir for an external psql; print the dir.
# Usage: stage_secret_certs <cert-secret> <ca-secret>  (cert provides tls.crt/tls.key,
# ca provides ca.crt). The private key is chmod 600 so libpq accepts it.
stage_secret_certs() {
    local cert_secret="$1" ca_secret="$2" dir
    dir=$(mktemp -d "${TMPDIR:-/tmp}/eso-vault-connect.XXXXXX")
    kubectl get secret "${ca_secret}" -n "${CNPG_DEMO_NAMESPACE}" --context "${LOCAL_CONTEXT}" \
        -o jsonpath='{.data.ca\.crt}' | base64 -d > "${dir}/ca.crt"
    kubectl get secret "${cert_secret}" -n "${CNPG_DEMO_NAMESPACE}" --context "${LOCAL_CONTEXT}" \
        -o jsonpath='{.data.tls\.crt}' | base64 -d > "${dir}/tls.crt"
    kubectl get secret "${cert_secret}" -n "${CNPG_DEMO_NAMESPACE}" --context "${LOCAL_CONTEXT}" \
        -o jsonpath='{.data.tls\.key}' | base64 -d > "${dir}/tls.key"
    chmod 600 "${dir}/tls.key"
    echo "${dir}"
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
    echo "✅ Vault credentials written"

    echo "📁 Creating namespace ${CNPG_DEMO_NAMESPACE}..."
    kubectl create namespace "${CNPG_DEMO_NAMESPACE}" \
        --context "${LOCAL_CONTEXT}" \
        --dry-run=client -o yaml \
        | kubectl apply --context "${LOCAL_CONTEXT}" -f -

    echo "📋 Applying ExternalSecrets..."
    for es in superuser app; do
        kubectl apply \
            --context "${LOCAL_CONTEXT}" \
            -f "${DEMO_YAML}/local/externalsecret-pg-local-${es}.yaml"
    done

    echo "⏳ Waiting for ExternalSecrets to sync..."
    for es in superuser app; do
        wait_for_external_secret "pg-local-${es}" "${CNPG_DEMO_NAMESPACE}"
    done

    # --- mTLS / IngressRouteTCP setup ---
    echo "🔐 Setting up mTLS certificates and Traefik routes..."

    # Compute Traefik postgres IP (main LB IP + 10 on last octet)
    TRAEFIK_IP=$(get_traefik_lb_ip "${LOCAL_CONTEXT}")
    TRAEFIK_POSTGRES_IP=$(echo "${TRAEFIK_IP}" | awk -F. '{OFS="."; $4=$4+10; print}')
    TRAEFIK_POSTGRES_IP_DASHED=$(ip_to_dashed "${TRAEFIK_POSTGRES_IP}")

    # Phase 2: Certificate infrastructure
    echo "📜 Issuing mTLS certificates (cert-manager)..."
    for cert in server replication tls-term-server pooler-client pooler-server; do
        CNPG_DEMO_NAMESPACE="${CNPG_DEMO_NAMESPACE}" \
        TRAEFIK_POSTGRES_IP_DASHED="${TRAEFIK_POSTGRES_IP_DASHED}" \
        envsubst '${CNPG_DEMO_NAMESPACE} ${TRAEFIK_POSTGRES_IP_DASHED}' \
            < "${DEMO_YAML}/local/mtls/certificate-${cert}.yaml.tpl" \
            | kubectl apply --context "${LOCAL_CONTEXT}" -f -
    done

    echo "⏳ Waiting for certificates to be Ready..."
    for cert in pg-local-server-tls pg-local-replication-tls pg-local-tls-term-server pg-local-pooler-client-tls pg-local-pooler-server-tls; do
        kubectl wait --for=condition=Ready certificate/"${cert}" \
            -n "${CNPG_DEMO_NAMESPACE}" --timeout=120s --context "${LOCAL_CONTEXT}"
    done

    # PgBouncer auth secret (required when using custom TLS secrets)
    echo "🔑 Creating PgBouncer auth secret..."
    POOLER_PASSWORD=$(openssl rand -base64 32 | tr -d '/+=' | head -c 32)
    kubectl create secret generic pg-local-pooler-auth \
        --namespace="${CNPG_DEMO_NAMESPACE}" \
        --context="${LOCAL_CONTEXT}" \
        --from-literal=username=cnpg_pooler_pgbouncer \
        --from-literal=password="${POOLER_PASSWORD}" \
        --dry-run=client -o yaml | kubectl apply --context "${LOCAL_CONTEXT}" -f -

    # Phase 3: Traefik configuration
    echo "🔒 Applying TLSOption (mtls-verify)..."
    kubectl apply --context "${LOCAL_CONTEXT}" \
        -f "${DEMO_YAML}/local/mtls/tlsoption-mtls-verify.yaml"

    echo "🌐 Applying IngressRouteTCP routes..."
    CNPG_DEMO_NAMESPACE="${CNPG_DEMO_NAMESPACE}" \
    TRAEFIK_POSTGRES_IP_DASHED="${TRAEFIK_POSTGRES_IP_DASHED}" \
    envsubst '${CNPG_DEMO_NAMESPACE} ${TRAEFIK_POSTGRES_IP_DASHED}' \
        < "${DEMO_YAML}/local/mtls/ingressroute-tcp-tls-term.yaml.tpl" \
        | kubectl apply --context "${LOCAL_CONTEXT}" -f -

    CNPG_DEMO_NAMESPACE="${CNPG_DEMO_NAMESPACE}" \
    TRAEFIK_POSTGRES_IP_DASHED="${TRAEFIK_POSTGRES_IP_DASHED}" \
    envsubst '${CNPG_DEMO_NAMESPACE} ${TRAEFIK_POSTGRES_IP_DASHED}' \
        < "${DEMO_YAML}/local/mtls/ingressroute-tcp-tls-passthrough.yaml.tpl" \
        | kubectl apply --context "${LOCAL_CONTEXT}" -f -

    echo "✅ mTLS infrastructure ready"
    echo "   TLS-termination endpoint: pg-local-${CNPG_DEMO_NAMESPACE}-t.${TRAEFIK_POSTGRES_IP_DASHED}.sslip.io"
    echo "   TLS-passthrough endpoint:  pg-local-${CNPG_DEMO_NAMESPACE}-p.${TRAEFIK_POSTGRES_IP_DASHED}.sslip.io"

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
    echo "   Credentials managed by Vault at cnpg/pg-local/{superuser,app}"
    ;;

rotate)
    TARGET="${3:-}"
    case "${TARGET}" in
        superuser|app) ;;
        *) echo "❌ target must be one of: superuser app"; usage ;;
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
        superuser|app) ;;
        *) echo "❌ target must be one of: superuser app"; usage ;;
    esac
    verify_connectivity "${TARGET}"
    ;;

teardown)
    echo "=================================================="
    echo "🔥 ESO demo teardown (local) — narrow scope"
    echo "=================================================="

    echo "🗑️ Deleting IngressRouteTCP routes..."
    kubectl delete --context "${LOCAL_CONTEXT}" \
        -n "${CNPG_DEMO_NAMESPACE}" \
        ingressroutetcp/pg-local-tls-term \
        --ignore-not-found
    kubectl delete --context "${LOCAL_CONTEXT}" \
        -n "${CNPG_DEMO_NAMESPACE}" \
        ingressroutetcp/pg-local-tls-passthrough \
        --ignore-not-found

    echo "🗑️ Deleting TLSOption (mtls-verify) from traefik namespace..."
    kubectl delete --context "${LOCAL_CONTEXT}" \
        -n traefik \
        tlsoption/mtls-verify \
        --ignore-not-found

    echo "🗑️ Deleting namespace ${CNPG_DEMO_NAMESPACE} (includes all CNPG + ESO + cert resources)..."
    kubectl delete namespace "${CNPG_DEMO_NAMESPACE}" \
        --context "${LOCAL_CONTEXT}" \
        --ignore-not-found

    echo "🗑️ Deleting Vault KV paths for pg-local..."
    for cred in superuser app; do
        _vcmd kv delete "cnpg/pg-local/${cred}" 2>/dev/null \
            || echo "  cnpg/pg-local/${cred} not found, skipping"
    done

    echo "✅ Demo teardown complete."
    echo "   ESO infra (ClusterSecretStore, AppRole, cnpg/ mount) retained."
    echo "   Run scripts/teardown.sh to remove the full environment."
    ;;

connect)
    TARGET="${3:-}"
    case "${TARGET}" in
        superuser|app) ;;
        *) echo "❌ target must be one of: superuser app"; usage ;;
    esac
    DB="app"; [ "${TARGET}" = "superuser" ] && DB="postgres"

    DASHED=$(traefik_pg_host_dashed)
    HOST="pg-local-${CNPG_DEMO_NAMESPACE}-t.${DASHED}.sslip.io"

    USERNAME=$(kubectl get secret "pg-local-${TARGET}" -n "${CNPG_DEMO_NAMESPACE}" \
        --context "${LOCAL_CONTEXT}" -o jsonpath='{.data.username}' | base64 -d)
    PASSWORD=$(kubectl get secret "pg-local-${TARGET}" -n "${CNPG_DEMO_NAMESPACE}" \
        --context "${LOCAL_CONTEXT}" -o jsonpath='{.data.password}' | base64 -d)

    # The -t endpoint terminates TLS at Traefik (edge mTLS: RequireAndVerifyClientCert),
    # then connects plaintext to Postgres → `host all all all scram-sha-256` → password auth.
    # The reused pooler-client cert only satisfies the Traefik edge (its CN is irrelevant here).
    CERTDIR=$(stage_secret_certs "pg-local-pooler-client-tls" "vault-pki-bundle")

    echo "🔌 Connect to '${TARGET}' via the TLS-termination endpoint (password auth):"
    echo ""
    echo "PGPASSWORD='${PASSWORD}' psql \"host=${HOST} port=5432 dbname=${DB} user=${USERNAME} sslmode=verify-full sslrootcert=${CERTDIR}/ca.crt sslcert=${CERTDIR}/tls.crt sslkey=${CERTDIR}/tls.key\""
    ;;

connect-mtls)
    TARGET="${3:-}"
    case "${TARGET}" in
        superuser|app) ;;
        *) echo "❌ target must be one of: superuser app"; usage ;;
    esac
    DB="app"; [ "${TARGET}" = "superuser" ] && DB="postgres"
    ROLE="${TARGET}"; [ "${TARGET}" = "superuser" ] && ROLE="postgres"

    DASHED=$(traefik_pg_host_dashed)
    HOST="pg-local-${CNPG_DEMO_NAMESPACE}-p.${DASHED}.sslip.io"

    CERT_NAME="pg-local-connect-${TARGET}"
    CERT_SECRET="${CERT_NAME}-tls"

    # The -p endpoint passes TLS straight to Postgres → `hostssl all all all cert` → client-cert
    # auth where the cert CN must equal the role. Issue a short-lived (1h) client cert on demand;
    # it lives in the demo namespace, so `teardown` removes it with the namespace.
    echo "📜 Issuing 1h client certificate (CN=${ROLE}) for '${TARGET}'..."
    kubectl apply --context "${LOCAL_CONTEXT}" -f - <<EOF
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: ${CERT_NAME}
  namespace: ${CNPG_DEMO_NAMESPACE}
spec:
  commonName: ${ROLE}
  dnsNames:
    - ${ROLE}
  secretName: ${CERT_SECRET}
  duration: 1h
  renewBefore: 5m
  issuerRef:
    kind: ClusterIssuer
    name: vault-pki
  privateKey:
    algorithm: ECDSA
    size: 256
EOF

    kubectl wait --for=condition=Ready "certificate/${CERT_NAME}" \
        -n "${CNPG_DEMO_NAMESPACE}" --context "${LOCAL_CONTEXT}" --timeout=120s

    CERTDIR=$(stage_secret_certs "${CERT_SECRET}" "vault-pki-bundle")

    echo "🔐 Connect to '${TARGET}' via the TLS-passthrough endpoint (mTLS cert auth, no password):"
    echo ""
    echo "psql \"host=${HOST} port=5432 dbname=${DB} user=${ROLE} sslmode=verify-full sslrootcert=${CERTDIR}/ca.crt sslcert=${CERTDIR}/tls.crt sslkey=${CERTDIR}/tls.key\""
    ;;

*)
    usage
    ;;
esac
