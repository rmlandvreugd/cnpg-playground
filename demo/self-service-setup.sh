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

# Postgres TCP traffic uses a separate MetalLB IP (traefik-postgres svc, :5432),
# NOT the web LB (traefik svc, :80/:443). See docs/architecture-overview.md.
get_traefik_postgres_ip() {
    kubectl get svc traefik-postgres -n traefik --context "${LOCAL_CONTEXT}" \
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

    # --- Preflight: platform + monitoring must already exist ---
    # The platform (Capsule, ArgoCD, …) is installed by scripts/setup.sh; the
    # tenant's Grafana hard-requires the monitoring stack (monitoring/setup.sh).
    echo "🔎 Preflight: verifying platform + monitoring are present..."
    if ! kubectl get crd tenants.capsule.clastix.io --context "${LOCAL_CONTEXT}" &>/dev/null \
       || ! kubectl get namespace argocd --context "${LOCAL_CONTEXT}" &>/dev/null; then
        echo "❌ Platform not found (Capsule CRD / argocd namespace missing)."
        echo "   Run the cluster + platform first:  scripts/setup.sh local"
        exit 1
    fi
    if ! kubectl get namespace grafana --context "${LOCAL_CONTEXT}" &>/dev/null \
       || ! kubectl get crd grafanas.grafana.integreatly.org --context "${LOCAL_CONTEXT}" &>/dev/null; then
        echo "❌ Monitoring stack not found (grafana namespace / Grafana operator CRD missing)."
        echo "   The tenant Grafana hard-requires it. Run:  monitoring/setup.sh local"
        exit 1
    fi
    echo "✅ Platform + monitoring present"

    TRAEFIK_IP=$(get_traefik_ip)
    TRAEFIK_IP_DASHED=$(ip_to_dashed "${TRAEFIK_IP}")
    echo "ℹ️  Traefik IP: ${TRAEFIK_IP} (dashed: ${TRAEFIK_IP_DASHED})"

    POSTGRES_IP=$(get_traefik_postgres_ip)
    POSTGRES_IP_DASHED=$(ip_to_dashed "${POSTGRES_IP}")
    echo "ℹ️  Traefik Postgres IP: ${POSTGRES_IP} (dashed: ${POSTGRES_IP_DASHED})"

    # --- Vault policies ---
    echo "📋 Writing Vault policies..."
    cat <<'EOF' | _vcmd_stdin policy write eso-rbr-ver -
path "cnpg/data/rbr/ver/*"       { capabilities = ["read"] }
path "cnpg/metadata/rbr/ver/*"   { capabilities = ["read", "list"] }
path "database/static-creds/app" { capabilities = ["read"] }
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

    echo "📋 Applying ClusterSecretStore vault-approle-rbr-db (database secrets engine)..."
    kubectl apply --context "${LOCAL_CONTEXT}" -f - <<EOF
apiVersion: external-secrets.io/v1
kind: ClusterSecretStore
metadata:
  name: vault-approle-rbr-db
spec:
  provider:
    vault:
      server: "http://vault.vault.svc.cluster.local:${VAULT_HTTP_PORT}"
      path: "database"
      version: "v1"
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
    echo "✅ ClusterSecretStore vault-approle-rbr-db ready"

    # --- Seed KV credentials ---
    echo "📝 Seeding Vault KV at cnpg/rbr/ver/..."
    _vcmd kv put cnpg/rbr/ver/superuser username=postgres  password="$(random_password)"
    _vcmd kv put cnpg/rbr/ver/app        username=app      password="$(random_password)"
    _vcmd kv put cnpg/rbr/ver/readonly   username=readonly password="$(random_password)"
    echo "✅ KV credentials seeded"

    # --- Capsule Tenant + tenant-owned namespaces ---
    # The Tenant must exist before its namespaces are created, and the
    # capsule.clastix.io/tenant label must be present at namespace CREATE time:
    # Capsule's namespaces.validating.projectcapsule.dev webhook denies patching the
    # tenant label onto an already-existing namespace ("namespace can not be patched
    # into a tenant" — CVE-2024-39690 hardening). We apply the Tenant directly here;
    # ArgoCD's tenant-rbr app (prune=false) adopts the same Tenant object on first sync.
    echo "🏛️  Pre-seeding Capsule Tenant 'rbr' (ArgoCD adopts it on sync)..."
    kubectl apply --context "${LOCAL_CONTEXT}" \
        -f "${GIT_REPO_ROOT}/manifests/capsule-tenant-rbr.yaml"
    kubectl wait tenant/rbr --context "${LOCAL_CONTEXT}" \
        --for=jsonpath='{.status.state}'=Active --timeout=60s || true

    # Capsule only lets a *tenant owner* create a tenant-owned namespace (the webhook
    # rejects both a plain cluster-admin create and a forged ownerReference: "only
    # tenant owners can create tenant-owned namespaces"). We run as cluster-admin, so
    # we impersonate the rbr tenant owner group (oidc:rbr-db-admin) — which Capsule
    # binds to the capsule-namespace-provisioner ClusterRole (create/patch namespaces).
    # Capsule's mutating webhook then injects the Tenant ownerReference automatically.
    # Use `create` not `apply`: the provisioner role lacks `get`, which apply needs.
    echo "🏗️  Creating tenant namespaces as tenant owner (Capsule injects ownerReference)..."
    for ns in rbr-ver rbr-ver-db; do
        if kubectl get namespace "${ns}" --context "${LOCAL_CONTEXT}" &>/dev/null; then
            echo "   namespace ${ns} already exists, skipping"
            continue
        fi
        kubectl --context "${LOCAL_CONTEXT}" \
            --as=capsule-bot --as-group=oidc:rbr-db-admin --as-group=system:authenticated \
            create -f - <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: ${ns}
  labels:
    capsule.clastix.io/tenant: rbr
    cnpg.io/driver-group: ver
EOF
    done
    echo "✅ Tenant namespaces ready"

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

    echo "📊 Applying custom monitoring ConfigMap (must exist before Cluster CR)..."
    kubectl apply --context "${LOCAL_CONTEXT}" \
        -f "${SELF_SERVICE_YAML}/rbr-ver-db/cnpg-custom-monitoring-rbr-ver.yaml"

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
    POSTGRES_IP_DASHED="${POSTGRES_IP_DASHED}" \
    envsubst '${POSTGRES_IP_DASHED}' \
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

    echo "🔑 Creating Vault DB config PostgreSQL role (rbr_ver_vde_config)..."
    VDE_CONFIG_PASS=$(openssl rand -hex 32)
    psql_primary "
        CREATE ROLE rbr_ver_vde_config WITH LOGIN CREATEROLE PASSWORD '${VDE_CONFIG_PASS}';
        GRANT CONNECT ON DATABASE max TO rbr_ver_vde_config;
        GRANT rbr_ver_ddl_owner  TO rbr_ver_vde_config WITH ADMIN OPTION;
        GRANT rbr_ver_ddl_admin  TO rbr_ver_vde_config WITH ADMIN OPTION;
        GRANT rbr_ver_ddl_reader TO rbr_ver_vde_config WITH ADMIN OPTION;
        -- PostgreSQL 16+ (this cluster is PG 18): a CREATEROLE role may only
        -- ALTER roles it holds ADMIN OPTION on. The 'app'/'readonly' login roles
        -- are created by CNPG (superuser), so without these grants Vault's static
        -- role rotation ('ALTER ROLE \"app\" WITH PASSWORD ...') fails with
        -- 'permission denied to alter role' (SQLSTATE 42501). These run after the
        -- cluster is ready, so the managed roles already exist.
        GRANT \"app\"      TO rbr_ver_vde_config WITH ADMIN OPTION;
        GRANT \"readonly\" TO rbr_ver_vde_config WITH ADMIN OPTION;
    "
    echo "✅ Vault DB config role created (password will be rotated by Vault)"

    # --- Vault Database Secrets Engine ---
    echo "🗄️  Configuring Vault Database Secrets Engine..."
    _vcmd secrets enable database 2>/dev/null \
        || echo "  database engine already enabled, continuing"

    _vcmd write database/config/rbr-ver-max \
        plugin_name="postgresql-database-plugin" \
        connection_url="postgresql://{{username}}:{{password}}@verstappen-rbr-ver-db.${POSTGRES_IP_DASHED}.sslip.io:5432/max?sslmode=require" \
        allowed_roles="rbr-db-admin,rbr-ver-db-admin,rbr-ver-db-readonly" \
        username="rbr_ver_vde_config" \
        password="${VDE_CONFIG_PASS}"

    _vcmd write -f database/rotate-root/rbr-ver-max
    echo "✅ Root credential rotated — config password is now Vault-owned"

    # Add 'app' to allowed_roles so the static role can be created
    _vcmd write database/config/rbr-ver-max \
        allowed_roles="rbr-db-admin,rbr-ver-db-admin,rbr-ver-db-readonly,app"

    # Vault static role: Vault rotates the 'app' PG role password on a 24h schedule.
    # ESO reads database/static-creds/app → verstappen-app Secret in rbr-ver.
    # Reloader (reloader.stakater.com/auto annotation) bounces the pod on Secret change.
    _vcmd write database/static-roles/app \
        db_name="rbr-ver-max" \
        username="app" \
        rotation_period="24h" \
        rotation_statements="ALTER ROLE \"app\" WITH PASSWORD '{{password}}'"
    echo "✅ Vault static role 'app' configured (24h auto-rotation)"

    _vcmd write database/roles/rbr-db-admin \
        db_name="rbr-ver-max" \
        creation_statements="CREATE ROLE \"{{name}}\" WITH LOGIN PASSWORD '{{password}}' VALID UNTIL '{{expiration}}' IN ROLE rbr_ver_ddl_admin; GRANT \"{{name}}\" TO rbr_ver_vde_config;" \
        revocation_statements="REASSIGN OWNED BY \"{{name}}\" TO rbr_ver_ddl_owner; DROP OWNED BY \"{{name}}\"; DROP ROLE IF EXISTS \"{{name}}\";" \
        default_ttl="1h" \
        max_ttl="4h"

    _vcmd write database/roles/rbr-ver-db-admin \
        db_name="rbr-ver-max" \
        creation_statements="CREATE ROLE \"{{name}}\" WITH LOGIN PASSWORD '{{password}}' VALID UNTIL '{{expiration}}' IN ROLE rbr_ver_ddl_admin; GRANT \"{{name}}\" TO rbr_ver_vde_config;" \
        revocation_statements="REASSIGN OWNED BY \"{{name}}\" TO rbr_ver_ddl_owner; DROP OWNED BY \"{{name}}\"; DROP ROLE IF EXISTS \"{{name}}\";" \
        default_ttl="1h" \
        max_ttl="4h"

    _vcmd write database/roles/rbr-ver-db-readonly \
        db_name="rbr-ver-max" \
        creation_statements="CREATE ROLE \"{{name}}\" WITH LOGIN PASSWORD '{{password}}' VALID UNTIL '{{expiration}}' IN ROLE rbr_ver_ddl_reader; GRANT \"{{name}}\" TO rbr_ver_vde_config;" \
        revocation_statements="DROP ROLE IF EXISTS \"{{name}}\";" \
        default_ttl="1h" \
        max_ttl="4h"

    echo "✅ Vault Database Secrets Engine configured"

    # --- demo-app image + ArgoCD app-of-apps (GitOps) ---
    # Sequenced AFTER the verstappen DB and the Vault DB engine exist: the demo-app
    # ExternalSecret reads database/static-creds/app via the vault-approle-rbr-db store,
    # so the static role 'app' (above) and the store (earlier) must already be in place —
    # otherwise demo-app crash-loops. Build + load the image before ArgoCD syncs it.
    echo "🐳 Building demo-app image..."
    DEMO_APP_VERSION=$(grep '^appVersion:' "${GIT_REPO_ROOT}/app/helm/demo-app/Chart.yaml" | awk '{print $2}' | tr -d '"')
    docker build -t "demo-app:${DEMO_APP_VERSION}" "${GIT_REPO_ROOT}/app"
    kind load docker-image "demo-app:${DEMO_APP_VERSION}" \
        --name "$(get_cluster_name "${MODE}")"
    echo "✅ demo-app:${DEMO_APP_VERSION} loaded into Kind"

    echo "🚀 Applying ArgoCD root Application (app-of-apps)..."
    kubectl apply --context "${LOCAL_CONTEXT}" \
        -f "${GIT_REPO_ROOT}/manifests/argocd/root-app.yaml"

    echo "⏳ Waiting for rbr-root Application to sync (up to 5 min)..."
    kubectl wait application/rbr-root \
        -n argocd \
        --context "${LOCAL_CONTEXT}" \
        --for=jsonpath='{.status.sync.status}'=Synced \
        --timeout=300s || echo "⚠️  rbr-root sync timeout — check ArgoCD UI for details"

    # Inject Traefik IP into demo-app Application so the IngressRoute hostname resolves
    # (ignoreDifferences on root-app prevents selfHeal from reverting this override)
    kubectl patch application demo-app \
        -n argocd \
        --context "${LOCAL_CONTEXT}" \
        --type merge \
        -p "{\"spec\":{\"source\":{\"helm\":{\"parameters\":[{\"name\":\"global.traefikIpDashed\",\"value\":\"${TRAEFIK_IP_DASHED}\"}]}}}}"
    echo "✅ ArgoCD app-of-apps applied — demo-app deploys via GitOps"

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

    # cert-manager Certificate for the websecure route (vault-pki, ECDSA).
    # Traefik forces web->websecure, so the route must terminate TLS or the
    # redirected HTTPS request 404s.
    TRAEFIK_IP_DASHED="${TRAEFIK_IP_DASHED}" \
    envsubst '${TRAEFIK_IP_DASHED}' \
        < "${SELF_SERVICE_YAML}/pgadmin/certificate-pgadmin-rbr-ver.yaml.tpl" \
        | kubectl apply --context "${LOCAL_CONTEXT}" -f -

    TRAEFIK_IP_DASHED="${TRAEFIK_IP_DASHED}" \
    envsubst '${TRAEFIK_IP_DASHED}' \
        < "${SELF_SERVICE_YAML}/pgadmin/ingressroute-pgadmin-rbr-ver.yaml.tpl" \
        | kubectl apply --context "${LOCAL_CONTEXT}" -f -

    # --- Grafana + Authelia for rbr-ver ---
    echo "📊 Deploying grafana-rbr-ver with Authelia Generic OAuth..."

    HOST_IP=$(hostname -I | awk '{print $1}')
    HOST_IP_DASHED=$(echo "${HOST_IP}" | tr '.' '-')
    AUTHELIA_HOST="authelia.${HOST_IP_DASHED}.sslip.io"
    AUTHELIA_TLS_DIR="${GIT_REPO_ROOT}/authelia/tls"

    # K8s Secret for Grafana OAuth client secret
    GRAFANA_RBR_VER_CLIENT_SECRET="${AUTHELIA_GRAFANA_RBR_VER_CLIENT_SECRET}"
    GRAFANA_RBR_VER_CLIENT_SECRET="${GRAFANA_RBR_VER_CLIENT_SECRET}" \
    envsubst '${GRAFANA_RBR_VER_CLIENT_SECRET}' \
        < "${SELF_SERVICE_YAML}/grafana/secret-grafana-rbr-ver-oauth.yaml.tpl" \
        | kubectl apply --context "${LOCAL_CONTEXT}" -f -

    # Authelia CA ConfigMap for Grafana TLS trust
    echo "📜 Creating authelia-ca-cert ConfigMap in grafana namespace..."
    kubectl create configmap authelia-ca-cert \
        --namespace grafana \
        --context "${LOCAL_CONTEXT}" \
        --from-file=ca-chain.pem="${AUTHELIA_TLS_DIR}/ca-chain.pem" \
        --dry-run=client -o yaml \
        | kubectl apply --context "${LOCAL_CONTEXT}" -f -

    # TLS Certificate for Grafana
    echo "📜 Issuing TLS certificate for grafana-rbr-ver..."
    TRAEFIK_IP_DASHED="${TRAEFIK_IP_DASHED}" \
    envsubst '${TRAEFIK_IP_DASHED}' \
        < "${SELF_SERVICE_YAML}/grafana/certificate-grafana-rbr-ver.yaml.tpl" \
        | kubectl apply --context "${LOCAL_CONTEXT}" -f -
    kubectl wait --context "${LOCAL_CONTEXT}" --timeout=60s \
        --for=condition=Ready certificate/grafana-rbr-ver-cert -n grafana

    # Grafana CR
    AUTHELIA_HOST="${AUTHELIA_HOST}" AUTHELIA_PORT="${AUTHELIA_PORT}" TRAEFIK_IP_DASHED="${TRAEFIK_IP_DASHED}" \
    envsubst '${AUTHELIA_HOST} ${AUTHELIA_PORT} ${TRAEFIK_IP_DASHED}' \
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

    # Seed 'rbr' org: create org, copy datasources and dashboards from Main Org.
    echo "🏢 Seeding 'rbr' org in grafana-rbr-ver..."
    kubectl port-forward svc/grafana-rbr-ver-service 13000:3000 \
        -n grafana --context "${LOCAL_CONTEXT}" &
    PF_PID=$!
    sleep 4

    # Create org (idempotent — ignore conflict)
    curl -sf -u admin:admin http://localhost:13000/api/orgs \
        -X POST -H "Content-Type: application/json" \
        -d '{"name":"rbr"}' > /dev/null 2>&1 || true

    python3 - << 'PYEOF'
import json, urllib.request, urllib.error, sys

base  = "http://localhost:13000"
auth  = "Basic YWRtaW46YWRtaW4="   # admin:admin

def api(path, method="GET", data=None, org_id=None):
    hdrs = {"Authorization": auth, "Content-Type": "application/json"}
    if org_id:
        hdrs["X-Grafana-Org-Id"] = str(org_id)
    req = urllib.request.Request(
        base + path, data=data, headers=hdrs, method=method)
    try:
        return json.load(urllib.request.urlopen(req))
    except urllib.error.HTTPError as e:
        body = e.read().decode()
        if e.code == 409:   # already exists
            return None
        print(f"  HTTP {e.code} {path}: {body[:120]}", file=sys.stderr)
        return None

# Resolve org 2 id by name (in case id differs)
orgs = api("/api/orgs")
rbr_org = next((o for o in orgs if o["name"] == "rbr"), None)
if not rbr_org:
    print("  ✗ 'rbr' org not found; skipping datasource/dashboard seed", file=sys.stderr)
    sys.exit(0)
org2 = rbr_org["id"]

# Copy datasources
ds_list = api("/api/datasources") or []
for ds in ds_list:
    payload = json.dumps({
        "name": ds["name"], "type": ds["type"], "uid": ds["uid"],
        "url": ds["url"], "access": ds["access"],
        "jsonData": ds.get("jsonData", {}),
    }).encode()
    result = api("/api/datasources", method="POST", data=payload, org_id=org2)
    status = "ok" if result else "already exists"
    print(f"  datasource '{ds['name']}': {status}")

# Copy dashboards
boards = api("/api/search?type=dash-db") or []
for b in boards:
    detail = api(f"/api/dashboards/uid/{b['uid']}")
    if not detail:
        continue
    dash = detail["dashboard"]
    dash.pop("id", None)
    dash.pop("version", None)
    payload = json.dumps(
        {"dashboard": dash, "overwrite": True, "folderId": 0}
    ).encode()
    result = api("/api/dashboards/import", method="POST",
                 data=payload, org_id=org2)
    status = "ok" if result else "failed"
    print(f"  dashboard '{b['title']}': {status}")
PYEOF

    kill "${PF_PID}" 2>/dev/null || true
    echo "✅ Grafana rbr-ver ready"

    echo ""
    echo "======================================================"
    echo "✅ Setup complete"
    echo "   Cluster:     verstappen  Namespace: rbr-ver-db"
    echo "   External DB: verstappen-rbr-ver-db.${POSTGRES_IP_DASHED}.sslip.io:5432"
    echo "   sslmode:     require"
    echo ""
    echo "   pgAdmin:     http://pgadmin-rbr-ver.${TRAEFIK_IP_DASHED}.sslip.io"
    echo "   Email:       ${PGADMIN_RBR_VER_EMAIL}"
    echo "   Password:    ${PGADMIN_RBR_VER_PASSWORD}"
    echo ""
    echo "   Grafana:     https://grafana-rbr-ver.${TRAEFIK_IP_DASHED}.sslip.io"
    echo "   Authelia:    rbr-admin@example.com / rbr-ver-admin@example.com"
    echo "   (password:   see AUTHELIA_STATIC_PASSWORD_HASH in scripts/common.sh)"
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
    kubectl exec -n rbr-ver-db --context "${LOCAL_CONTEXT}" \
        "$(primary_pod)" -- \
        psql -U postgres -d max -c "SELECT current_user, version();"
    echo "✅ DB connectivity verified"

    echo "🔍 Verifying demo-app deployment in rbr-ver..."
    kubectl rollout status deployment/demo-app \
        -n rbr-ver --context "${LOCAL_CONTEXT}" --timeout=60s
    APP_PASS=$(kubectl get secret "verstappen-app" -n rbr-ver \
        --context "${LOCAL_CONTEXT}" -o jsonpath='{.data.password}' 2>/dev/null | base64 -d || echo "")
    if [[ -z "${APP_PASS}" ]]; then
        echo "⚠️  verstappen-app Secret not yet synced in rbr-ver (ESO/Vault static-role may still be syncing)"
    else
        echo "✅ verstappen-app Secret present in rbr-ver"
    fi
    echo "✅ demo-app Running in rbr-ver"

    TRAEFIK_IP=$(get_traefik_ip)
    TRAEFIK_IP_DASHED=$(ip_to_dashed "${TRAEFIK_IP}")
    echo ""
    echo "   demo-app URL: https://demo-rbr-ver.${TRAEFIK_IP_DASHED}.sslip.io"
    echo "   ArgoCD apps:  kubectl get applications -n argocd --context ${LOCAL_CONTEXT}"
    ;;

rotate)
    TARGET="${3:-}"
    case "${TARGET}" in
        app|readonly) ;;
        *) echo "❌ rotate target must be: app | readonly"; exit 1 ;;
    esac

    if [[ "${TARGET}" == "app" ]]; then
        echo "🔄 Rotating 'app' via Vault static-role (database/rotate-role/app)..."
        _vcmd write -f database/rotate-role/app

        echo "⚡ Forcing ESO sync for verstappen-app in rbr-ver..."
        kubectl annotate externalsecret "verstappen-app" \
            -n rbr-ver \
            --context "${LOCAL_CONTEXT}" \
            --overwrite \
            force-sync="$(date +%s)"

        echo "⏳ Waiting for verstappen-app Secret (rbr-ver) to update..."
        OLD_VER=$(kubectl get secret "verstappen-app" -n rbr-ver \
            --context "${LOCAL_CONTEXT}" -o jsonpath='{.metadata.resourceVersion}' 2>/dev/null || echo "0")
        MAX_WAIT=60; ELAPSED=0
        while [ "${ELAPSED}" -lt "${MAX_WAIT}" ]; do
            NEW_VER=$(kubectl get secret "verstappen-app" -n rbr-ver \
                --context "${LOCAL_CONTEXT}" -o jsonpath='{.metadata.resourceVersion}' 2>/dev/null || echo "0")
            [ "${NEW_VER}" != "${OLD_VER}" ] && break
            sleep 2; ((ELAPSED+=2))
        done
        [ "${ELAPSED}" -ge "${MAX_WAIT}" ] && { echo "❌ Secret did not update within ${MAX_WAIT}s"; exit 1; }
        echo "✅ Secret updated (resourceVersion ${OLD_VER} → ${NEW_VER})"

        echo "⏳ Waiting for demo-app pod restart via Reloader..."
        kubectl rollout status deployment/demo-app \
            -n rbr-ver --context "${LOCAL_CONTEXT}" --timeout=120s
        echo "✅ demo-app restarted with rotated credentials"

        echo "🔍 Verifying rotated credential via psql (internal)..."
        NEW_PASS=$(kubectl get secret "verstappen-app" -n rbr-ver \
            --context "${LOCAL_CONTEXT}" -o jsonpath='{.data.password}' | base64 -d)
        kubectl run psql-rotate-verify --restart=Never --rm --attach \
            --context "${LOCAL_CONTEXT}" \
            --image=postgres:18-alpine \
            -n rbr-ver \
            --env="PGPASSWORD=${NEW_PASS}" \
            -- psql -h verstappen-rw.rbr-ver-db -U "app" -d max -c "SELECT current_user;"
        echo "✅ Rotation verified"
    else
        # readonly still uses KV-backed ESO (Workstream E scope: app only)
        echo "🔄 Rotating '${TARGET}' in Vault KV..."
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
        echo "✅ Rotation complete"
    fi
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

    # Delete the ArgoCD app-of-apps FIRST so it stops reconciling/re-creating tenant
    # resources while we tear them down. Cascade-delete removes the child Applications
    # (demo-app, grafana-rbr-ver, kyverno-policies, tenant-rbr) and their managed objects.
    echo "🚢 Deleting ArgoCD app-of-apps (rbr-root) + AppProject rbr..."
    kubectl delete application rbr-root \
        -n argocd --context "${LOCAL_CONTEXT}" --ignore-not-found --wait
    kubectl delete appproject rbr \
        -n argocd --context "${LOCAL_CONTEXT}" --ignore-not-found

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

    kubectl delete clustersecretstore vault-approle-rbr vault-approle-rbr-db \
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
    kubectl delete configmap authelia-ca-cert \
        -n grafana --context "${LOCAL_CONTEXT}" --ignore-not-found

    # Delete the Capsule Tenant LAST — after all tenant-owned namespaces and resources
    # are gone — so Capsule's webhook never blocks namespace cleanup. Idempotent: the
    # tenant-rbr ArgoCD app may already have cascade-removed it above.
    echo "🏛️  Deleting Capsule Tenant rbr..."
    kubectl delete tenant rbr \
        --context "${LOCAL_CONTEXT}" --ignore-not-found

    echo "ℹ️  Vault VDE config, policies, and KV paths retained for post-demo inspection."
    echo "   Remove with: vault delete database/config/rbr-ver-max"
    echo "✅ Teardown complete"
    ;;

*)
    usage
    ;;
esac
