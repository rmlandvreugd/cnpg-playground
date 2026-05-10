#!/usr/bin/env bash
set -euo pipefail

# Self-service demo: Vault + ESO + CNPG (rbr/ver/verstappen)
# Usage: self-service-setup.sh <setup|verify|rotate|backup|creds|teardown> local [args]

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GIT_REPO_ROOT=$(git rev-parse --show-toplevel)
source "${GIT_REPO_ROOT}/scripts/common.sh"

VAULT_DIR="${GIT_REPO_ROOT}/vault"
SELF_SERVICE_YAML="${GIT_REPO_ROOT}/demo/yaml/self-service"

SUBCOMMAND="${1:-}"
MODE="${2:-}"

usage() {
    cat <<'USAGE'
Usage: self-service-setup.sh <subcommand> local [args]
  setup   local                      — full stack: Vault + ESO + CNPG + Traefik + pgAdmin + Grafana
  verify  local                      — test superuser connectivity
  rotate  local <app|readonly>       — rotate ESO-managed credential
  backup  local                      — trigger on-demand backup
  creds   local <tenant-admin|group-admin|readonly>  — print dynamic DB credentials
  teardown local                     — remove rbr-ver-db/rbr-ver namespaces + ESO store
USAGE
    exit 1
}

[ -z "${SUBCOMMAND}" ] && usage
[ "${MODE}" != "local" ] && { echo "❌ Only 'local' mode supported"; exit 1; }

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

_vcmd_stdin() {
    ${CONTAINER_PROVIDER} exec -i \
        -e VAULT_ADDR="https://127.0.0.1:${VAULT_PORT}" \
        -e VAULT_CACERT=/vault/certs/vault-ca.pem \
        -e VAULT_TOKEN="${ROOT_TOKEN}" \
        "${VAULT_CONTAINER_NAME}" \
        vault "$@"
}

random_password() {
    openssl rand -base64 32 | tr -d '/+=' | head -c 32
}

get_traefik_ip() {
    kubectl get svc traefik -n traefik --context "${LOCAL_CONTEXT}" \
        -o jsonpath='{.status.loadBalancer.ingress[0].ip}'
}

primary_pod() {
    kubectl get pod -n rbr-ver-db --context "${LOCAL_CONTEXT}" \
        -l cnpg.io/cluster=verstappen,role=primary -o name | head -1
}

psql_primary() {
    kubectl exec -n rbr-ver-db --context "${LOCAL_CONTEXT}" \
        "$(primary_pod)" -- psql -U postgres -d max -c "$1"
}

wait_for_external_secret() {
    local name="$1" namespace="$2" max_wait="${3:-120}" elapsed=0
    echo "  ⏳ Waiting for ExternalSecret/${name} in ${namespace}..."
    while [ "${elapsed}" -lt "${max_wait}" ]; do
        status=$(kubectl get externalsecret "${name}" -n "${namespace}" \
            --context "${LOCAL_CONTEXT}" \
            -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)
        [ "${status}" = "True" ] && { echo "  ✅ ${name} ready"; return 0; }
        sleep 3; ((elapsed+=3))
    done
    echo "❌ ExternalSecret/${name} not ready after ${max_wait}s"
    exit 1
}

case "${SUBCOMMAND}" in

setup)
    echo "=========================================="
    echo "🚀 Self-service setup: rbr/ver/verstappen"
    echo "=========================================="

    TRAEFIK_IP=$(get_traefik_ip)
    TRAEFIK_IP_DASHED=$(ip_to_dashed "${TRAEFIK_IP}")
    echo "ℹ️  Traefik IP: ${TRAEFIK_IP} (dashed: ${TRAEFIK_IP_DASHED})"

    # --- Traefik: add postgres entrypoint ---
    echo "🔧 Upgrading Traefik with postgres entrypoint (port 5432)..."
    helm_upgrade_install traefik \
        oci://ghcr.io/traefik/helm/traefik \
        traefik "${LOCAL_CONTEXT}" "${TRAEFIK_CHART_VERSION}" \
        --values "${GIT_REPO_ROOT}/traefik/values.yaml" \
        --force-conflicts
    echo "✅ Traefik upgraded"

    # --- Vault policies ---
    echo "📋 Writing Vault policies..."
    cat <<'EOF' | _vcmd_stdin policy write eso-rbr-ver -
path "cnpg/data/rbr/ver/*"     { capabilities = ["read"] }
path "cnpg/metadata/rbr/ver/*" { capabilities = ["read", "list"] }
EOF
    cat <<'EOF' | _vcmd_stdin policy write rbr-db-admin -
path "database/creds/rbr-db-admin"     { capabilities = ["read"] }
path "database/creds/rbr-ver-db-admin" { capabilities = ["read"] }
EOF
    cat <<'EOF' | _vcmd_stdin policy write rbr-ver-db-admin -
path "database/creds/rbr-ver-db-admin" { capabilities = ["read"] }
EOF
    cat <<'EOF' | _vcmd_stdin policy write rbr-ver-db-readonly -
path "database/creds/rbr-ver-db-readonly" { capabilities = ["read"] }
EOF
    echo "✅ Vault policies written"

    # --- ESO AppRole + ClusterSecretStore ---
    echo "🔑 Creating Vault AppRole 'eso-rbr-local'..."
    _vcmd write "auth/approle/role/eso-rbr-local" \
        token_policies=eso-rbr-ver \
        secret_id_ttl=0 \
        token_ttl=1h \
        token_max_ttl=4h

    ESO_ROLE_ID=$(_vcmd read -field=role_id "auth/approle/role/eso-rbr-local/role-id")
    ESO_SECRET_ID=$(_vcmd write -field=secret_id -f "auth/approle/role/eso-rbr-local/secret-id")
    sudo tee "${VAULT_DIR}/.eso_rbr_role_id"   <<< "${ESO_ROLE_ID}"   > /dev/null
    sudo tee "${VAULT_DIR}/.eso_rbr_secret_id" <<< "${ESO_SECRET_ID}" > /dev/null
    sudo chmod 640 "${VAULT_DIR}/.eso_rbr_role_id" "${VAULT_DIR}/.eso_rbr_secret_id"
    echo "✅ AppRole eso-rbr-local created (role_id: ${ESO_ROLE_ID})"

    echo "🔑 Creating K8s Secret vault-approle-rbr-creds in ${ESO_NAMESPACE}..."
    kubectl create secret generic vault-approle-rbr-creds \
        --namespace "${ESO_NAMESPACE}" \
        --context "${LOCAL_CONTEXT}" \
        --from-literal=roleId="${ESO_ROLE_ID}" \
        --from-literal=secretId="${ESO_SECRET_ID}" \
        --dry-run=client -o yaml \
        | kubectl apply --context "${LOCAL_CONTEXT}" -f -

    echo "📋 Applying ClusterSecretStore vault-approle-rbr..."
    kubectl apply --context "${LOCAL_CONTEXT}" -f - <<EOF
apiVersion: external-secrets.io/v1
kind: ClusterSecretStore
metadata:
  name: vault-approle-rbr
spec:
  provider:
    vault:
      server: "http://vault.vault.svc.cluster.local:${VAULT_HTTP_PORT}"
      path: "cnpg"
      version: "v2"
      auth:
        appRole:
          path: "approle"
          roleRef:
            name: vault-approle-rbr-creds
            namespace: ${ESO_NAMESPACE}
            key: roleId
          secretRef:
            name: vault-approle-rbr-creds
            namespace: ${ESO_NAMESPACE}
            key: secretId
EOF
    echo "✅ ClusterSecretStore vault-approle-rbr ready"

    # --- Seed KV credentials ---
    echo "📝 Seeding Vault KV at cnpg/rbr/ver/..."
    _vcmd kv put cnpg/rbr/ver/superuser username=postgres  password="$(random_password)"
    _vcmd kv put cnpg/rbr/ver/app        username=app      password="$(random_password)"
    _vcmd kv put cnpg/rbr/ver/readonly   username=readonly password="$(random_password)"
    echo "✅ KV credentials seeded"

    # --- Namespaces ---
    echo "📁 Applying namespaces..."
    kubectl apply --context "${LOCAL_CONTEXT}" \
        -f "${SELF_SERVICE_YAML}/rbr-ver-db/namespace.yaml" \
        -f "${SELF_SERVICE_YAML}/rbr-ver/namespace.yaml"

    # --- ExternalSecrets ---
    echo "📋 Applying ExternalSecrets..."
    for es in superuser app readonly; do
        kubectl apply --context "${LOCAL_CONTEXT}" \
            -f "${SELF_SERVICE_YAML}/rbr-ver-db/externalsecret-verstappen-${es}.yaml"
    done
    for es in superuser app readonly; do
        wait_for_external_secret "verstappen-${es}" "rbr-ver-db"
    done

    # --- Wire objectstore-local into rbr-ver-db ---
    echo "🔧 Wiring objectstore-local Service+Endpoints in rbr-ver-db..."
    OBJECTSTORE_IP=$(${CONTAINER_PROVIDER} inspect "${RUSTFS_BASE_NAME}-local" \
        --format '{{.NetworkSettings.Networks.kind.IPAddress}}')
    kubectl apply --context "${LOCAL_CONTEXT}" -f - <<EOF
apiVersion: v1
kind: Service
metadata:
  name: objectstore-local
  namespace: rbr-ver-db
spec:
  ports:
    - name: s3
      port: 9000
      targetPort: 9000
---
apiVersion: v1
kind: Endpoints
metadata:
  name: objectstore-local
  namespace: rbr-ver-db
subsets:
  - addresses:
      - ip: ${OBJECTSTORE_IP}
    ports:
      - name: s3
        port: 9000
EOF

    echo "🔑 Creating objectstore-local credentials Secret in rbr-ver-db..."
    kubectl create secret generic objectstore-local \
        --namespace rbr-ver-db \
        --context "${LOCAL_CONTEXT}" \
        --from-literal=ACCESS_KEY_ID="${RUSTFS_ROOT_USER}" \
        --from-literal=ACCESS_SECRET_KEY="${RUSTFS_ROOT_PASSWORD}" \
        --dry-run=client -o yaml \
        | kubectl apply --context "${LOCAL_CONTEXT}" -f -
    echo "✅ Objectstore wired (IP: ${OBJECTSTORE_IP}; bucket verstappen-backups/ auto-created on first WAL)"

    # --- ObjectStore CR + CNPG Cluster ---
    echo "🐘 Applying ObjectStore CR..."
    kubectl apply --context "${LOCAL_CONTEXT}" \
        -f "${SELF_SERVICE_YAML}/rbr-ver-db/objectstore-rbr-ver.yaml"

    echo "🐘 Applying CNPG Cluster, Pooler, and ScheduledBackup..."
    TRAEFIK_IP_DASHED="${TRAEFIK_IP_DASHED}" \
    envsubst '${TRAEFIK_IP_DASHED}' \
        < "${SELF_SERVICE_YAML}/rbr-ver-db/cluster-verstappen.yaml.tpl" \
        | kubectl apply --context "${LOCAL_CONTEXT}" -f -

    echo "⏳ Waiting for verstappen cluster to be Ready (up to 30m)..."
    kubectl wait \
        --context "${LOCAL_CONTEXT}" \
        --timeout 30m \
        --for=condition=Ready \
        cluster/verstappen \
        -n rbr-ver-db

    # --- Traefik IngressRouteTCP ---
    echo "🌐 Applying Traefik TCP IngressRoute..."
    TRAEFIK_IP_DASHED="${TRAEFIK_IP_DASHED}" \
    envsubst '${TRAEFIK_IP_DASHED}' \
        < "${SELF_SERVICE_YAML}/traefik/ingressroute-tcp-postgres-rbr-ver.yaml.tpl" \
        | kubectl apply --context "${LOCAL_CONTEXT}" -f -

    # --- Stable PostgreSQL roles ---
    echo "🗄️  Creating stable PostgreSQL roles..."
    psql_primary "
        CREATE ROLE rbr_ver_ddl_owner  NOLOGIN;
        CREATE ROLE rbr_ver_ddl_admin  NOLOGIN;
        CREATE ROLE rbr_ver_ddl_reader NOLOGIN;
        GRANT CONNECT ON DATABASE max TO rbr_ver_ddl_admin;
        GRANT USAGE, CREATE ON SCHEMA public TO rbr_ver_ddl_admin;
        GRANT USAGE, CREATE ON SCHEMA public TO rbr_ver_ddl_owner;
        GRANT rbr_ver_ddl_owner TO rbr_ver_ddl_admin;
        GRANT CONNECT ON DATABASE max TO rbr_ver_ddl_reader;
        GRANT USAGE ON SCHEMA public TO rbr_ver_ddl_reader;
        GRANT SELECT ON ALL TABLES IN SCHEMA public TO rbr_ver_ddl_reader;
        ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT ON TABLES TO rbr_ver_ddl_reader;
    "
    echo "✅ Stable roles created"

    # --- VDE admin role ---
    echo "🔑 Creating VDE admin PostgreSQL role (rbr_ver_vde_admin)..."
    VDE_ADMIN_PASS=$(openssl rand -hex 32)
    psql_primary "
        CREATE ROLE rbr_ver_vde_admin WITH LOGIN CREATEROLE PASSWORD '${VDE_ADMIN_PASS}';
        GRANT CONNECT ON DATABASE max TO rbr_ver_vde_admin;
        GRANT rbr_ver_ddl_owner  TO rbr_ver_vde_admin WITH ADMIN OPTION;
        GRANT rbr_ver_ddl_admin  TO rbr_ver_vde_admin WITH ADMIN OPTION;
        GRANT rbr_ver_ddl_reader TO rbr_ver_vde_admin WITH ADMIN OPTION;
    "
    _vcmd kv put cnpg/rbr/ver/vde-admin \
        username=rbr_ver_vde_admin \
        password="${VDE_ADMIN_PASS}"
    echo "✅ VDE admin role created; password stored at cnpg/rbr/ver/vde-admin"

    # --- Vault Database Secrets Engine ---
    echo "🗄️  Configuring Vault Database Secrets Engine..."
    _vcmd secrets enable database 2>/dev/null \
        || echo "  database engine already enabled, continuing"

    _vcmd write database/config/rbr-ver-max \
        plugin_name="postgresql-database-plugin" \
        connection_url="postgresql://{{username}}:{{password}}@verstappen-rbr-ver-db.${TRAEFIK_IP_DASHED}.sslip.io:5432/max?sslmode=require" \
        allowed_roles="rbr-db-admin,rbr-ver-db-admin,rbr-ver-db-readonly" \
        username="rbr_ver_vde_admin" \
        password="${VDE_ADMIN_PASS}"

    _vcmd write database/roles/rbr-db-admin \
        db_name="rbr-ver-max" \
        creation_statements="CREATE ROLE \"{{name}}\" WITH LOGIN PASSWORD '{{password}}' VALID UNTIL '{{expiration}}' IN ROLE rbr_ver_ddl_admin; GRANT \"{{name}}\" TO rbr_ver_vde_admin;" \
        revocation_statements="REASSIGN OWNED BY \"{{name}}\" TO rbr_ver_ddl_owner; DROP OWNED BY \"{{name}}\"; DROP ROLE IF EXISTS \"{{name}}\";" \
        default_ttl="1h" \
        max_ttl="4h"

    _vcmd write database/roles/rbr-ver-db-admin \
        db_name="rbr-ver-max" \
        creation_statements="CREATE ROLE \"{{name}}\" WITH LOGIN PASSWORD '{{password}}' VALID UNTIL '{{expiration}}' IN ROLE rbr_ver_ddl_admin; GRANT \"{{name}}\" TO rbr_ver_vde_admin;" \
        revocation_statements="REASSIGN OWNED BY \"{{name}}\" TO rbr_ver_ddl_owner; DROP OWNED BY \"{{name}}\"; DROP ROLE IF EXISTS \"{{name}}\";" \
        default_ttl="1h" \
        max_ttl="4h"

    _vcmd write database/roles/rbr-ver-db-readonly \
        db_name="rbr-ver-max" \
        creation_statements="CREATE ROLE \"{{name}}\" WITH LOGIN PASSWORD '{{password}}' VALID UNTIL '{{expiration}}' IN ROLE rbr_ver_ddl_reader; GRANT \"{{name}}\" TO rbr_ver_vde_admin;" \
        revocation_statements="DROP ROLE IF EXISTS \"{{name}}\";" \
        default_ttl="1h" \
        max_ttl="4h"

    echo "✅ Vault Database Secrets Engine configured"

    # --- pgAdmin (self-service) ---
    echo "🔧 Deploying pgAdmin for rbr-ver..."
    PGADMIN_RBR_VER_EMAIL="${PGADMIN_RBR_VER_EMAIL:-admin@example.com}"
    PGADMIN_RBR_VER_PASSWORD="$(openssl rand -base64 32 | tr -d '/+=' | head -c 32)"

    kubectl apply --context "${LOCAL_CONTEXT}" \
        -f "${GIT_REPO_ROOT}/pgadmin/namespace.yaml"

    PGADMIN_RBR_VER_EMAIL="${PGADMIN_RBR_VER_EMAIL}" \
    PGADMIN_RBR_VER_PASSWORD="${PGADMIN_RBR_VER_PASSWORD}" \
    envsubst '${PGADMIN_RBR_VER_EMAIL} ${PGADMIN_RBR_VER_PASSWORD}' \
        < "${SELF_SERVICE_YAML}/pgadmin/secret-pgadmin-rbr-ver.yaml.tpl" \
        | kubectl apply --context "${LOCAL_CONTEXT}" -f -

    TRAEFIK_IP_DASHED="${TRAEFIK_IP_DASHED}" \
    envsubst '${TRAEFIK_IP_DASHED}' \
        < "${SELF_SERVICE_YAML}/pgadmin/servers.json.tpl" \
        | kubectl apply --context "${LOCAL_CONTEXT}" -f -

    kubectl apply --context "${LOCAL_CONTEXT}" \
        -f "${SELF_SERVICE_YAML}/pgadmin/deployment-pgadmin-rbr-ver.yaml"

    echo "⏳ Waiting for pgadmin-rbr-ver rollout..."
    kubectl rollout status deployment/pgadmin-rbr-ver \
        -n pgadmin --context "${LOCAL_CONTEXT}" --timeout=120s

    TRAEFIK_IP_DASHED="${TRAEFIK_IP_DASHED}" \
    envsubst '${TRAEFIK_IP_DASHED}' \
        < "${SELF_SERVICE_YAML}/pgadmin/ingressroute-pgadmin-rbr-ver.yaml.tpl" \
        | kubectl apply --context "${LOCAL_CONTEXT}" -f -

    # --- Grafana + Dex for rbr-ver ---
    echo "📊 Deploying grafana-rbr-ver with Dex Generic OAuth..."

    HOST_IP=$(hostname -I | awk '{print $1}')
    HOST_IP_DASHED=$(echo "${HOST_IP}" | tr '.' '-')
    DEX_HOST="dex.${HOST_IP_DASHED}.sslip.io"
    VAULT_HOST="vault.${HOST_IP_DASHED}.sslip.io"

    # K8s Secret for Grafana OAuth client secret
    GRAFANA_RBR_VER_CLIENT_SECRET="${DEX_GRAFANA_RBR_VER_CLIENT_SECRET}"
    GRAFANA_RBR_VER_CLIENT_SECRET="${GRAFANA_RBR_VER_CLIENT_SECRET}" \
    envsubst '${GRAFANA_RBR_VER_CLIENT_SECRET}' \
        < "${SELF_SERVICE_YAML}/grafana/secret-grafana-rbr-ver-oauth.yaml.tpl" \
        | kubectl apply --context "${LOCAL_CONTEXT}" -f -

    # Re-render dex-config.yaml with full var set (incl. TRAEFIK_IP_DASHED) and restart Dex
    echo "🔄 Updating Dex config with grafana-rbr-ver client (TRAEFIK_IP_DASHED=${TRAEFIK_IP_DASHED})..."
    DEX_HOST="${DEX_HOST}" VAULT_HOST="${VAULT_HOST}" \
    DEX_PORT="${DEX_PORT}" VAULT_PORT="${VAULT_PORT}" \
    DEX_OIDC_CLIENT_ID="${DEX_OIDC_CLIENT_ID}" DEX_OIDC_CLIENT_SECRET="${DEX_OIDC_CLIENT_SECRET}" \
    DEX_STATIC_PASSWORD_HASH="${DEX_STATIC_PASSWORD_HASH}" \
    DEX_RBR_ADMIN_PASSWORD_HASH="${DEX_RBR_ADMIN_PASSWORD_HASH}" \
    DEX_RBR_VER_ADMIN_PASSWORD_HASH="${DEX_RBR_VER_ADMIN_PASSWORD_HASH}" \
    DEX_UNRELATED_PASSWORD_HASH="${DEX_UNRELATED_PASSWORD_HASH}" \
    DEX_GRAFANA_RBR_VER_CLIENT_SECRET="${DEX_GRAFANA_RBR_VER_CLIENT_SECRET}" \
    TRAEFIK_IP_DASHED="${TRAEFIK_IP_DASHED}" \
    envsubst '${DEX_HOST} ${VAULT_HOST} ${DEX_PORT} ${VAULT_PORT} ${DEX_OIDC_CLIENT_ID} ${DEX_OIDC_CLIENT_SECRET} ${DEX_STATIC_PASSWORD_HASH} ${DEX_RBR_ADMIN_PASSWORD_HASH} ${DEX_RBR_VER_ADMIN_PASSWORD_HASH} ${DEX_UNRELATED_PASSWORD_HASH} ${DEX_GRAFANA_RBR_VER_CLIENT_SECRET} ${TRAEFIK_IP_DASHED}' \
        < "${GIT_REPO_ROOT}/dex/config/dex-config.yaml.tpl" \
        | sudo tee "${GIT_REPO_ROOT}/dex/config/dex-config.yaml" > /dev/null

    ${CONTAINER_PROVIDER} restart "${DEX_CONTAINER_NAME}"
    echo "⏳ Waiting for Dex to restart..."
    DEX_TLS_DIR="${GIT_REPO_ROOT}/dex/tls"
    DISCOVERY_URL="https://${DEX_HOST}:${DEX_PORT}/dex/.well-known/openid-configuration"
    MAX_RETRIES=20; COUNT=0
    while [ "${COUNT}" -lt "${MAX_RETRIES}" ]; do
        if curl -sf --cacert "${DEX_TLS_DIR}/ca-chain.pem" "${DISCOVERY_URL}" > /dev/null 2>&1; then
            echo "✅ Dex ready"
            break
        fi
        sleep 3; COUNT=$((COUNT + 1))
    done
    [ "${COUNT}" -ge "${MAX_RETRIES}" ] && { echo "❌ Dex did not restart within 60s"; exit 1; }

    # TLS Certificate for Grafana
    echo "📜 Issuing TLS certificate for grafana-rbr-ver..."
    TRAEFIK_IP_DASHED="${TRAEFIK_IP_DASHED}" \
    envsubst '${TRAEFIK_IP_DASHED}' \
        < "${SELF_SERVICE_YAML}/grafana/certificate-grafana-rbr-ver.yaml.tpl" \
        | kubectl apply --context "${LOCAL_CONTEXT}" -f -
    kubectl wait --context "${LOCAL_CONTEXT}" --timeout=60s \
        --for=condition=Ready certificate/grafana-rbr-ver-cert -n grafana

    # Grafana CR
    DEX_HOST="${DEX_HOST}" DEX_PORT="${DEX_PORT}" TRAEFIK_IP_DASHED="${TRAEFIK_IP_DASHED}" \
    envsubst '${DEX_HOST} ${DEX_PORT} ${TRAEFIK_IP_DASHED}' \
        < "${SELF_SERVICE_YAML}/grafana/grafana-rbr-ver.yaml.tpl" \
        | kubectl apply --context "${LOCAL_CONTEXT}" -f -

    # GrafanaDatasources + dashboards
    kubectl apply --context "${LOCAL_CONTEXT}" \
        -f "${SELF_SERVICE_YAML}/grafana/grafanadatasource-prometheus-rbr-ver.yaml" \
        -f "${SELF_SERVICE_YAML}/grafana/grafanadatasource-loki-rbr-ver.yaml" \
        -f "${SELF_SERVICE_YAML}/grafana/grafanadatasource-tempo-rbr-ver.yaml" \
        -f "${SELF_SERVICE_YAML}/grafana/grafanadatasource-mimir-tempo-rbr-ver.yaml" \
        -f "${SELF_SERVICE_YAML}/grafana/grafanadashboard-pgaudit-rbr-ver.yaml" \
        -f "${SELF_SERVICE_YAML}/grafana/grafanadashboard-traefik-traces-rbr-ver.yaml" \
        -f "${SELF_SERVICE_YAML}/grafana/grafanadashboard-cnpg-custom-rbr-ver.yaml"

    # IngressRoute (HTTPS via cert-manager TLS)
    TRAEFIK_IP_DASHED="${TRAEFIK_IP_DASHED}" \
    envsubst '${TRAEFIK_IP_DASHED}' \
        < "${SELF_SERVICE_YAML}/grafana/ingressroute-grafana-rbr-ver.yaml.tpl" \
        | kubectl apply --context "${LOCAL_CONTEXT}" -f -

    # Wait for Grafana deployment
    echo "⏳ Waiting for grafana-rbr-ver deployment..."
    kubectl rollout status deployment/grafana-rbr-ver-deployment \
        -n grafana --context "${LOCAL_CONTEXT}" --timeout=180s

    # Pre-create 'rbr' org via Grafana API (port-forward)
    echo "🏢 Pre-creating 'rbr' org in grafana-rbr-ver..."
    kubectl port-forward svc/grafana-rbr-ver-service 13000:3000 \
        -n grafana --context "${LOCAL_CONTEXT}" &
    PF_PID=$!
    sleep 4
    curl -sf -u admin:admin http://localhost:13000/api/orgs \
        -X POST -H "Content-Type: application/json" \
        -d '{"name":"rbr"}' > /dev/null \
        || echo "  ℹ️  Org 'rbr' may already exist or grafana-rbr-ver not ready yet"
    kill "${PF_PID}" 2>/dev/null || true
    echo "✅ Grafana rbr-ver ready"

    echo ""
    echo "======================================================"
    echo "✅ Setup complete"
    echo "   Cluster:     verstappen  Namespace: rbr-ver-db"
    echo "   External DB: verstappen-rbr-ver-db.${TRAEFIK_IP_DASHED}.sslip.io:5432"
    echo "   sslmode:     require"
    echo ""
    echo "   pgAdmin:     http://pgadmin-rbr-ver.${TRAEFIK_IP_DASHED}.sslip.io"
    echo "   Email:       ${PGADMIN_RBR_VER_EMAIL}"
    echo "   Password:    ${PGADMIN_RBR_VER_PASSWORD}"
    echo ""
    echo "   Grafana:     https://grafana-rbr-ver.${TRAEFIK_IP_DASHED}.sslip.io"
    echo "   Dex users:   rbr-admin@example.com / rbr-ver-admin@example.com"
    echo "   (password:   same as dexuser — see DEX_STATIC_PASSWORD_HASH)"
    echo ""
    echo "   1. Open pgAdmin URL above"
    echo "   2. Run: $0 creds local group-admin"
    echo "   3. Paste credentials into pgAdmin Connect dialog"
    echo "   4. Before any DDL: SET ROLE rbr_ver_ddl_owner;"
    echo ""
    echo "   Tenant-admin creds:  $0 creds local tenant-admin"
    echo "   Group-admin creds:   $0 creds local group-admin"
    echo "   Readonly creds:      $0 creds local readonly"
    echo "======================================================"
    ;;

verify)
    echo "🔍 Verifying superuser connectivity via internal service..."
    SU_PASS=$(kubectl get secret verstappen-superuser -n rbr-ver-db \
        --context "${LOCAL_CONTEXT}" -o jsonpath='{.data.password}' | base64 -d)
    SU_USER=$(kubectl get secret verstappen-superuser -n rbr-ver-db \
        --context "${LOCAL_CONTEXT}" -o jsonpath='{.data.username}' | base64 -d)
    kubectl exec -n rbr-ver-db --context "${LOCAL_CONTEXT}" \
        "$(primary_pod)" -- \
        psql -U postgres -d max -c "SELECT current_user, version();"
    echo "✅ Connectivity verified"
    ;;

rotate)
    TARGET="${3:-}"
    case "${TARGET}" in
        app|readonly) ;;
        *) echo "❌ rotate target must be: app | readonly"; exit 1 ;;
    esac

    echo "🔄 Rotating '${TARGET}' in Vault..."
    _vcmd kv patch "cnpg/rbr/ver/${TARGET}" password="$(random_password)"

    echo "⚡ Forcing ESO sync for verstappen-${TARGET}..."
    kubectl annotate externalsecret "verstappen-${TARGET}" \
        -n rbr-ver-db \
        --context "${LOCAL_CONTEXT}" \
        --overwrite \
        force-sync="$(date +%s)"

    echo "⏳ Waiting for Secret resourceVersion to change..."
    OLD_VER=$(kubectl get secret "verstappen-${TARGET}" -n rbr-ver-db \
        --context "${LOCAL_CONTEXT}" -o jsonpath='{.metadata.resourceVersion}')
    MAX_WAIT=60; ELAPSED=0
    while [ "${ELAPSED}" -lt "${MAX_WAIT}" ]; do
        NEW_VER=$(kubectl get secret "verstappen-${TARGET}" -n rbr-ver-db \
            --context "${LOCAL_CONTEXT}" -o jsonpath='{.metadata.resourceVersion}')
        [ "${NEW_VER}" != "${OLD_VER}" ] && break
        sleep 2; ((ELAPSED+=2))
    done
    [ "${ELAPSED}" -ge "${MAX_WAIT}" ] && { echo "❌ Secret did not update within ${MAX_WAIT}s"; exit 1; }
    echo "✅ Secret updated (resourceVersion ${OLD_VER} → ${NEW_VER})"

    echo "🔍 Verifying rotated credential via psql (internal)..."
    NEW_PASS=$(kubectl get secret "verstappen-${TARGET}" -n rbr-ver-db \
        --context "${LOCAL_CONTEXT}" -o jsonpath='{.data.password}' | base64 -d)
    NEW_USER=$(kubectl get secret "verstappen-${TARGET}" -n rbr-ver-db \
        --context "${LOCAL_CONTEXT}" -o jsonpath='{.data.username}' | base64 -d)
    kubectl run psql-rotate-verify --restart=Never --rm --attach \
        --context "${LOCAL_CONTEXT}" \
        --image=postgres:18-alpine \
        -n rbr-ver \
        --env="PGPASSWORD=${NEW_PASS}" \
        -- psql -h verstappen-rw.rbr-ver-db -U "${NEW_USER}" -d max -c "SELECT current_user;"
    echo "✅ Rotation verified"
    ;;

backup)
    BACKUP_NAME="max-manual-$(date +%Y%m%d-%H%M%S)"
    echo "📸 Triggering on-demand backup: ${BACKUP_NAME}"
    kubectl apply --context "${LOCAL_CONTEXT}" -f - <<EOF
apiVersion: postgresql.cnpg.io/v1
kind: Backup
metadata:
  name: ${BACKUP_NAME}
  namespace: rbr-ver-db
spec:
  method: plugin
  pluginConfiguration:
    name: barman-cloud.cloudnative-pg.io
  cluster:
    name: verstappen
EOF
    echo "✅ Backup '${BACKUP_NAME}' triggered"
    echo "   kubectl get backup ${BACKUP_NAME} -n rbr-ver-db --context ${LOCAL_CONTEXT}"
    ;;

creds)
    PERSONA="${3:-}"
    case "${PERSONA}" in
        tenant-admin)
            echo "🔑 Tenant-admin credentials (Vault role: rbr-db-admin, TTL: 1h)"
            _vcmd read database/creds/rbr-db-admin
            echo ""
            echo "⚠️  Run SET ROLE rbr_ver_ddl_owner; before any DDL to ensure stable ownership"
            ;;
        group-admin)
            echo "🔑 Group-admin credentials (Vault role: rbr-ver-db-admin, TTL: 1h)"
            _vcmd read database/creds/rbr-ver-db-admin
            echo ""
            echo "⚠️  Run SET ROLE rbr_ver_ddl_owner; before any DDL to ensure stable ownership"
            ;;
        readonly)
            echo "🔑 Readonly credentials (Vault role: rbr-ver-db-readonly, TTL: 1h)"
            _vcmd read database/creds/rbr-ver-db-readonly
            ;;
        *) echo "❌ creds persona must be: tenant-admin | group-admin | readonly"; exit 1 ;;
    esac
    ;;

teardown)
    echo "🔥 Teardown: rbr-ver-db + rbr-ver (local)"

    # Delete CRs first so operators can process finalizers before namespace termination
    echo "🐘 Deleting CNPG Cluster and ObjectStore (waits for finalizer cleanup)..."
    kubectl delete cluster verstappen \
        -n rbr-ver-db --context "${LOCAL_CONTEXT}" --ignore-not-found --wait
    kubectl delete pooler pooler-verstappen-rw \
        -n rbr-ver-db --context "${LOCAL_CONTEXT}" --ignore-not-found --wait
    kubectl delete objectstore objectstore-rbr-ver \
        -n rbr-ver-db --context "${LOCAL_CONTEXT}" --ignore-not-found --wait
    kubectl delete externalsecret verstappen-superuser verstappen-app verstappen-readonly \
        -n rbr-ver-db --context "${LOCAL_CONTEXT}" --ignore-not-found --wait

    kubectl delete namespace rbr-ver-db rbr-ver \
        --context "${LOCAL_CONTEXT}" \
        --ignore-not-found

    kubectl delete clustersecretstore vault-approle-rbr \
        --context "${LOCAL_CONTEXT}" \
        --ignore-not-found

    kubectl delete secret vault-approle-rbr-creds \
        -n "${ESO_NAMESPACE}" \
        --context "${LOCAL_CONTEXT}" \
        --ignore-not-found

    kubectl delete ingressroutetcp postgres-rbr-ver \
        -n traefik \
        --context "${LOCAL_CONTEXT}" \
        --ignore-not-found

    echo "🔧 Removing pgAdmin rbr-ver resources..."
    for res in deployment/pgadmin-rbr-ver service/pgadmin-rbr-ver \
               configmap/pgadmin-rbr-ver-servers secret/pgadmin-rbr-ver-credentials; do
        kubectl delete "${res}" -n pgadmin \
            --context "${LOCAL_CONTEXT}" --ignore-not-found
    done
    kubectl delete ingressroute pgadmin-rbr-ver \
        -n pgadmin --context "${LOCAL_CONTEXT}" --ignore-not-found

    echo "📊 Removing Grafana rbr-ver resources..."
    kubectl delete ingressroute grafana-rbr-ver \
        -n grafana --context "${LOCAL_CONTEXT}" --ignore-not-found
    kubectl delete grafanadatasource prometheus-rbr-ver loki-rbr-ver \
        -n grafana --context "${LOCAL_CONTEXT}" --ignore-not-found
    kubectl delete grafanadashboard pgaudit-dashboard-rbr-ver \
        -n grafana --context "${LOCAL_CONTEXT}" --ignore-not-found
    kubectl delete grafana grafana-rbr-ver-deployment \
        -n grafana --context "${LOCAL_CONTEXT}" --ignore-not-found
    kubectl delete secret grafana-rbr-ver-oauth \
        -n grafana --context "${LOCAL_CONTEXT}" --ignore-not-found
    kubectl delete certificate grafana-rbr-ver-cert \
        -n grafana --context "${LOCAL_CONTEXT}" --ignore-not-found
    echo "ℹ️  Dex config NOT reverted — re-run scripts/dex-setup.sh to reset."

    echo "ℹ️  Vault VDE config, policies, and KV paths retained for post-demo inspection."
    echo "   Remove with: vault delete database/config/rbr-ver-max"
    echo "✅ Teardown complete"
    ;;

*)
    usage
    ;;
esac
