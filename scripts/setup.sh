#!/usr/bin/env bash
#
# This script sets up a simulated environment for deploying CloudNativePG
# across two regions: Europe and the USA. Each region includes its own
# Kubernetes cluster and a dedicated object storage system for backups,
# using an external RustFS instance in Docker to emulate an S3-compatible
# object store.
#
# The Kubernetes clusters in each region consist of multiple nodes, each with
# specialized roles—managing the control plane, handling infrastructure workloads,
# hosting applications, and running PostgreSQL databases.
#
# Note: This environment is for learning purposes only and should not be used
# in production.
#
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

# Source the common setup script
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"
acquire_lock

echo "✅ Prerequisites met. Using '$CONTAINER_PROVIDER' as the container provider."

# --- Pre-flight Check ---
echo "🔎 Verifying that no existing playground clusters are running..."
# The '|| true' prevents the script from exiting if grep finds no matches.
existing_count=$(kind get clusters | grep -c "^${K8S_BASE_NAME}" || true)

if [ "${existing_count}" -gt 0 ]; then
    echo "❌ Error: Found ${existing_count} existing playground cluster(s)."
    echo "Please run './scripts/teardown.sh' to remove the existing environment before running setup."
    echo
    echo "Found clusters:"
    kind get clusters | grep "^${K8S_BASE_NAME}"
    exit 1
fi

echo "✅ No existing clusters found. Proceeding with setup."
echo

# --- Script Setup ---
# Parse flags out of the positional args before region parsing.
#   --with-tenant : after the cluster + platform are up, chain monitoring and the
#                   self-service tenant onboarding (one-shot full demo). Default off,
#                   so a plain run yields a clean, tenant-free cluster.
WITH_TENANT=false
_args=()
for arg in "$@"; do
    case "${arg}" in
        --with-tenant) WITH_TENANT=true ;;
        *) _args+=("${arg}") ;;
    esac
done
set -- "${_args[@]+"${_args[@]}"}"

# Determine regions from arguments, or use defaults
set_regions "$@"
HUB_REGION="${REGIONS[0]}"

echo "=================================================="
echo "🔐 Phase 0: Bootstrapping external services"
echo "=================================================="
"${SCRIPT_DIR}/step-ca-setup.sh"
"${SCRIPT_DIR}/vault-setup.sh"
"${SCRIPT_DIR}/vault-pki-setup.sh"
"${SCRIPT_DIR}/vault-eso-setup.sh"
"${SCRIPT_DIR}/authelia-setup.sh"
echo

# Setup a single, shared Kubeconfig for all clusters
export KUBECONFIG="${KUBE_CONFIG_PATH}"
> "${KUBE_CONFIG_PATH}" # Create or clear the kubeconfig file
cd "${GIT_REPO_ROOT}"

kind_config_path="${GIT_REPO_ROOT}/k8s/kind-cluster.yaml"

# Generate secretbox encryption key and render kind cluster config
echo "🔑 Generating secretbox encryption key..."
mkdir -p "${GIT_REPO_ROOT}/k8s/encryption"
SECRETBOX_KEY=$(head -c 32 /dev/urandom | base64)
cat > "${GIT_REPO_ROOT}/k8s/encryption/secretbox.key" <<EOF
apiVersion: apiserver.config.k8s.io/v1
kind: EncryptionConfiguration
resources:
  - resources:
      - secrets
    providers:
      - secretbox:
          keys:
            - name: key1
              secret: ${SECRETBOX_KEY}
      - identity: {}
EOF
chmod 0600 "${GIT_REPO_ROOT}/k8s/encryption/secretbox.key"
GIT_REPO_ROOT="${GIT_REPO_ROOT}" envsubst '${GIT_REPO_ROOT}' \
    < "${GIT_REPO_ROOT}/k8s/kind-cluster.yaml.tpl" \
    > "${GIT_REPO_ROOT}/k8s/kind-cluster.yaml"

echo "📝 Rendering initial authn-config (will be updated post-MetalLB)..."
STEP_CA_CHAIN_PEM=$(sudo cat "${GIT_REPO_ROOT}/step-ca/pki/root_ca.crt" "${GIT_REPO_ROOT}/step-ca/pki/intermediate_ca.crt" | sed 's/^/        /')
# OIDC issuer is the hub in-cluster Authelia portal (fixed across all clusters,
# matches gangplank's login portal). HUB_TRAEFIK_IP_DASHED is deterministic.
HUB_TRAEFIK_IP_DASHED="${HUB_TRAEFIK_IP_DASHED}" \
STEP_CA_CHAIN_PEM="${STEP_CA_CHAIN_PEM}" \
envsubst '${HUB_TRAEFIK_IP_DASHED} ${STEP_CA_CHAIN_PEM}' \
    < "${GIT_REPO_ROOT}/k8s/authn-config.yaml.tpl" \
    > "${GIT_REPO_ROOT}/k8s/authn-config.yaml"

# --- Phase 1: Provision Clusters and RustFS Instances ---
let "current_objectstore_port = RUSTFS_BASE_PORT"
declare -A objectstore_ports
declare -a all_objectstore_names=()

for region in "${REGIONS[@]}"; do
    echo "--------------------------------------------------"
    echo "🚀 Provisioning resources for region: ${region}"
    echo "--------------------------------------------------"

    K8S_CLUSTER_NAME=$(get_cluster_name "${region}")
    CONTEXT_NAME=$(get_cluster_context "${region}")
    RUSTFS_CONTAINER_NAME="${RUSTFS_BASE_NAME}-${region}"

    echo "📦 Creating RustFS container '${RUSTFS_CONTAINER_NAME}' on host port ${current_objectstore_port}..."
    $CONTAINER_PROVIDER volume create "${RUSTFS_CONTAINER_NAME}" > /dev/null
    $CONTAINER_PROVIDER run \
        --name "${RUSTFS_CONTAINER_NAME}" -d \
        --network bridge \
        -p "${current_objectstore_port}:9001" \
        -v "${RUSTFS_CONTAINER_NAME}:/data" \
        -e "RUSTFS_ACCESS_KEY=${RUSTFS_ROOT_USER}" \
        -e "RUSTFS_SECRET_KEY=${RUSTFS_ROOT_PASSWORD}" \
        -e RUSTFS_CONSOLE_ENABLE=true \
        --restart unless-stopped \
        "${RUSTFS_IMAGE}" --console-enable /data

    # SeaweedFS: create container on bridge (hub region only); TLS added after kind IP is known
    if [[ "${region}" == "${HUB_REGION}" ]]; then
        echo "📦 Creating SeaweedFS container '${SEAWEEDFS_CONTAINER_NAME}'..."
        $CONTAINER_PROVIDER volume create "${SEAWEEDFS_CONTAINER_NAME}" > /dev/null
        $CONTAINER_PROVIDER run \
            --name "${SEAWEEDFS_CONTAINER_NAME}" -d \
            --network bridge \
            -p "${SEAWEEDFS_S3_PORT}:8333" \
            -p "${SEAWEEDFS_S3_HTTP_PORT}:${SEAWEEDFS_S3_HTTP_PORT}" \
            -p "${SEAWEEDFS_MASTER_PORT}:9333" \
            -p "${SEAWEEDFS_VOLUME_PORT}:9340" \
            -p "${SEAWEEDFS_FILER_PORT}:8889" \
            -v "${SEAWEEDFS_CONTAINER_NAME}:/data" \
            --restart unless-stopped \
            "${SEAWEEDFS_IMAGE}" \
            server -dir=/data \
                -filer \
                -s3 \
                -filer.port=8889 \
                -volume.port=9340 \
                -s3.port="${SEAWEEDFS_S3_HTTP_PORT}"
    fi

    echo "🏗️  Creating Kind cluster '${K8S_CLUSTER_NAME}'..."
    if [ "$CONTAINER_PROVIDER" == "podman" ]; then
        export KIND_EXPERIMENTAL_PROVIDER=podman
    fi
    kind create cluster --config "${kind_config_path}" --name "${K8S_CLUSTER_NAME}"

    echo "🏷️  Labeling nodes in '${K8S_CLUSTER_NAME}'..."
    kubectl label node -l postgres.node.kubernetes.io node-role.kubernetes.io/postgres= --context "$(get_cluster_context "${region}")"
    kubectl label node -l infra.node.kubernetes.io node-role.kubernetes.io/infra= --context "$(get_cluster_context "${region}")"
    kubectl label node -l app.node.kubernetes.io node-role.kubernetes.io/app= --context "$(get_cluster_context "${region}")"

    echo "🛠️  Installing Calico CNI (tigera-operator ${TIGERA_OPERATOR_CHART_VERSION} with v1 CRDs) in '${K8S_CLUSTER_NAME}'..."
    kubectl create namespace tigera-operator --context "$(get_cluster_context "${region}")"
    # helm template calico-crds projectcalico.org.v3 --version ${TIGERA_OPERATOR_CHART_VERSION} --repo https://docs.tigera.io/calico/charts | kubectl apply --context "$(get_cluster_context "${region}")" --server-side -f -
    helm template calico-crds crd.projectcalico.org.v1 --version ${TIGERA_OPERATOR_CHART_VERSION} --repo https://docs.tigera.io/calico/charts | kubectl apply --context "$(get_cluster_context "${region}")" --server-side -f -
    helm_upgrade_install tigera-operator tigera-operator tigera-operator "$(get_cluster_context "${region}")" \
        "${TIGERA_OPERATOR_CHART_VERSION}" \
        --repo-url https://docs.tigera.io/calico/charts \
        -f "${GIT_REPO_ROOT}/k8s/calico/tigera-operator-values.yaml"
    kubectl apply -f "${GIT_REPO_ROOT}/k8s/calico/installation.yaml" --context "$(get_cluster_context "${region}")"
    echo "⏳ Waiting for calico-node DaemonSet to appear..."
    until kubectl get daemonset calico-node -n calico-system \
        --context "$(get_cluster_context "${region}")" &>/dev/null; do
        sleep 3
    done
    kubectl rollout status daemonset/calico-node -n calico-system \
        --timeout=900s --context "$(get_cluster_context "${region}")"
    kubectl rollout status deployment/calico-kube-controllers -n calico-system \
        --timeout=900s --context "$(get_cluster_context "${region}")"
    # Wait for the full Calico v3 control plane (apiserver/webhooks/goldmane/whisker) to
    # be Available before proceeding. The aggregated v3.projectcalico.org APIService can
    # stall cluster-wide discovery/list/apply calls while it converges, which otherwise
    # makes downstream helm installs (and monitoring/setup.sh) race an unready Calico.
    # retry guards the brief window before the TigeraStatus objects exist.
    retry 30 10 kubectl wait --for=condition=Available tigerastatus --all \
        --timeout=900s --context "$(get_cluster_context "${region}")"

    # Auto-approve the kubernetes.io/kubelet-serving CSRs created by serverTLSBootstrap
    # (see k8s/kind-cluster.yaml.tpl). The in-tree approver never approves serving CSRs,
    # so without this metrics-server cannot verify kubelet TLS. kubelet-csr-approver only
    # approves — the cluster CA signer still issues the cert. Installed after Calico so
    # its pods can schedule, and before metrics-server which depends on the result.
    echo "🔏 Installing kubelet-csr-approver ${KUBELET_CSR_APPROVER_CHART_VERSION} in '${K8S_CLUSTER_NAME}'..."
    KIND_NODE_SUBNET=$(get_kind_ipv4_subnet kind)
    helm_upgrade_install kubelet-csr-approver \
        kubelet-csr-approver \
        kube-system "${CONTEXT_NAME}" "${KUBELET_CSR_APPROVER_CHART_VERSION}" \
        --repo-url https://postfinance.github.io/kubelet-csr-approver \
        --set "providerRegex=^${K8S_CLUSTER_NAME}-[a-z0-9-]+\$" \
        --set "bypassDnsResolution=true" \
        --set-string "providerIpPrefixes=${KIND_NODE_SUBNET}" \
        --set "maxExpirationSeconds=2592000"
    kubectl --context "${CONTEXT_NAME}" -n kube-system rollout status \
        deploy/kubelet-csr-approver --timeout=120s

    echo "🛠️  Installing MetalLB ${METALLB_CHART_VERSION} (chart) in '${K8S_CLUSTER_NAME}'..."
    # Enable strict ARP for kube-proxy
    kubectl get configmap kube-proxy -n kube-system -o yaml --context "$(get_cluster_context "${region}")" | \
    sed -e "s/strictARP: false/strictARP: true/" | \
    kubectl replace -f - --context "$(get_cluster_context "${region}")"
    helm_upgrade_install metallb metallb metallb-system "$(get_cluster_context "${region}")" \
        "${METALLB_CHART_VERSION}" \
        --repo-url https://metallb.github.io/metallb

    # Determine the IP range for MetalLB based on the region index
    # to avoid conflicts on the shared 'kind' network.
    # We specifically look for the IPv4 subnet.
    KIND_NET_SUBNET=$(get_kind_ipv4_subnet kind)
    SUBNET_IP=$(echo $KIND_NET_SUBNET | cut -d/ -f1)
    SUBNET_MASK=$(echo $KIND_NET_SUBNET | cut -d/ -f2)

    # Find the index of the current region in the REGIONS array
    region_index=0
    for i in "${!REGIONS[@]}"; do
       if [[ "${REGIONS[$i]}" == "${region}" ]]; then
           region_index=$i
           break
       fi
    done

    if [ "$SUBNET_MASK" -ge 24 ]; then
        # For /24 or smaller, use the first 3 octets and partition the 4th
        SUBNET_PREFIX=$(echo $SUBNET_IP | cut -d. -f1,2,3)
        START_IP=$((200 + region_index * 25))
        END_IP=$((START_IP + 24))
        IP_RANGE="${SUBNET_PREFIX}.${START_IP}-${SUBNET_PREFIX}.${END_IP}"
    else
        # For /16, use the first 2 octets and vary the 3rd octet
        SUBNET_PREFIX=$(echo $SUBNET_IP | cut -d. -f1,2)
        THIRD_OCTET=$((255 - region_index))
        IP_RANGE="${SUBNET_PREFIX}.${THIRD_OCTET}.200-${SUBNET_PREFIX}.${THIRD_OCTET}.250"
    fi

    echo "🌐 Configuring MetalLB in '${K8S_CLUSTER_NAME}' with IP range: ${IP_RANGE}"
    cat <<EOF | kubectl apply --context "$(get_cluster_context "${region}")" -f -
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: kind-pool
  namespace: metallb-system
spec:
  addresses:
  - ${IP_RANGE}
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: kind-advertisement
  namespace: metallb-system
spec:
  ipAddressPools:
  - kind-pool
EOF

    echo "🌐 Connecting containers to the Kind network..."
    $CONTAINER_PROVIDER network connect kind "${RUSTFS_CONTAINER_NAME}"
    if [[ "${region}" == "${HUB_REGION}" ]]; then
        $CONTAINER_PROVIDER network connect kind "${SEAWEEDFS_CONTAINER_NAME}"
    fi

    # Provision TLS cert for RustFS and restart with TLS enabled
    echo "🔒 Provisioning TLS cert for '${RUSTFS_CONTAINER_NAME}'..."
    OBJECTSTORE_IP=$(${CONTAINER_PROVIDER} inspect "${RUSTFS_CONTAINER_NAME}" \
        --format '{{.NetworkSettings.Networks.kind.IPAddress}}')

    RUSTFS_TLS_DIR="${GIT_REPO_ROOT}/rustfs/${region}/tls"
    sudo mkdir -p "${RUSTFS_TLS_DIR}"
    # UID 10001 is the unprivileged user RustFS runs as inside the container
    sudo setfacl -R -b "${RUSTFS_TLS_DIR}"
    sudo setfacl -R -m "u:10001:rwx" "${RUSTFS_TLS_DIR}"
    sudo setfacl -R -d -m "u:10001:rwx" "${RUSTFS_TLS_DIR}"

    STEP_CA_INT_CERT_TMP=$(mktemp)
    STEP_CA_INT_KEY_TMP=$(mktemp)
    ${CONTAINER_PROVIDER} exec "${STEP_CA_CONTAINER_NAME}" \
        cat /home/step/certs/intermediate_ca.crt > "${STEP_CA_INT_CERT_TMP}"
    ${CONTAINER_PROVIDER} cp \
        "${STEP_CA_CONTAINER_NAME}:/home/step/secrets/intermediate_ca_key" \
        "${STEP_CA_INT_KEY_TMP}"
    STEP_CA_PASSWORD=$(${CONTAINER_PROVIDER} exec "${STEP_CA_CONTAINER_NAME}" \
        cat /home/step/secrets/password)

    RUSTFS_EXT_TMP=$(mktemp)
    cat > "${RUSTFS_EXT_TMP}" <<EOF
basicConstraints=CA:FALSE
keyUsage=critical,digitalSignature,keyEncipherment
extendedKeyUsage=serverAuth,clientAuth
subjectAltName=DNS:${RUSTFS_CONTAINER_NAME},DNS:${RUSTFS_CONTAINER_NAME}.cnpg-system.svc.cluster.local,DNS:${RUSTFS_CONTAINER_NAME}.mimir.svc.cluster.local,DNS:${RUSTFS_CONTAINER_NAME}.tempo.svc.cluster.local,IP:${OBJECTSTORE_IP}
EOF

    RUSTFS_CSR_TMP=$(mktemp)
    RUSTFS_KEY_TMP=$(mktemp)
    RUSTFS_CERT_TMP=$(mktemp)
    openssl req -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes \
        -keyout "${RUSTFS_KEY_TMP}" \
        -out "${RUSTFS_CSR_TMP}" \
        -subj "/CN=${RUSTFS_CONTAINER_NAME}" 2>&1
    openssl x509 -req \
        -in "${RUSTFS_CSR_TMP}" \
        -CA "${STEP_CA_INT_CERT_TMP}" \
        -CAkey "${STEP_CA_INT_KEY_TMP}" \
        -CAcreateserial \
        -days 365 \
        -passin "pass:${STEP_CA_PASSWORD}" \
        -extfile "${RUSTFS_EXT_TMP}" \
        -out "${RUSTFS_CERT_TMP}" 2>&1

    sudo cp "${RUSTFS_CERT_TMP}" "${RUSTFS_TLS_DIR}/rustfs_cert.pem"
    sudo cp "${RUSTFS_KEY_TMP}"  "${RUSTFS_TLS_DIR}/rustfs_key.pem"
    sudo chmod 644 "${RUSTFS_TLS_DIR}/rustfs_cert.pem"
    sudo chmod 600 "${RUSTFS_TLS_DIR}/rustfs_key.pem"
    sudo setfacl -m "u:10001:r" "${RUSTFS_TLS_DIR}/rustfs_cert.pem"
    sudo setfacl -m "u:10001:r" "${RUSTFS_TLS_DIR}/rustfs_key.pem"
    rm -f "${STEP_CA_INT_CERT_TMP}" "${STEP_CA_INT_KEY_TMP}" "${RUSTFS_EXT_TMP}" \
          "${RUSTFS_CSR_TMP}" "${RUSTFS_KEY_TMP}" "${RUSTFS_CERT_TMP}"

    echo "🔒 Restarting '${RUSTFS_CONTAINER_NAME}' with TLS enabled..."
    ${CONTAINER_PROVIDER} stop "${RUSTFS_CONTAINER_NAME}"
    ${CONTAINER_PROVIDER} rm   "${RUSTFS_CONTAINER_NAME}"
    ${CONTAINER_PROVIDER} run \
        --name "${RUSTFS_CONTAINER_NAME}" -d \
        --network bridge \
        -p "${current_objectstore_port}:9001" \
        -v "${RUSTFS_CONTAINER_NAME}:/data" \
        -v "${RUSTFS_TLS_DIR}:/opt/tls:ro" \
        -e "RUSTFS_ACCESS_KEY=${RUSTFS_ROOT_USER}" \
        -e "RUSTFS_SECRET_KEY=${RUSTFS_ROOT_PASSWORD}" \
        -e "RUSTFS_TLS_PATH=/opt/tls" \
        -e RUSTFS_CONSOLE_ENABLE=true \
        --restart unless-stopped \
        "${RUSTFS_IMAGE}" --console-enable /data
    ${CONTAINER_PROVIDER} network connect kind --ip "${OBJECTSTORE_IP}" "${RUSTFS_CONTAINER_NAME}"

    # Provision TLS cert for SeaweedFS and restart with TLS enabled (hub region only)
    if [[ "${region}" == "${HUB_REGION}" ]]; then
        echo "🔒 Provisioning TLS cert for '${SEAWEEDFS_CONTAINER_NAME}'..."
        SEAWEEDFS_IP=$(${CONTAINER_PROVIDER} inspect "${SEAWEEDFS_CONTAINER_NAME}" \
            --format '{{.NetworkSettings.Networks.kind.IPAddress}}')

        SEAWEEDFS_TLS_DIR="${GIT_REPO_ROOT}/seaweedfs/tls"
        SEAWEEDFS_CFG_DIR="${GIT_REPO_ROOT}/seaweedfs/config"
        sudo mkdir -p "${SEAWEEDFS_TLS_DIR}" "${SEAWEEDFS_CFG_DIR}"

        SW_INT_CERT_TMP=$(mktemp)
        SW_INT_KEY_TMP=$(mktemp)
        ${CONTAINER_PROVIDER} exec "${STEP_CA_CONTAINER_NAME}" \
            cat /home/step/certs/intermediate_ca.crt > "${SW_INT_CERT_TMP}"
        ${CONTAINER_PROVIDER} cp \
            "${STEP_CA_CONTAINER_NAME}:/home/step/secrets/intermediate_ca_key" \
            "${SW_INT_KEY_TMP}"
        SW_CA_PASSWORD=$(${CONTAINER_PROVIDER} exec "${STEP_CA_CONTAINER_NAME}" \
            cat /home/step/secrets/password)

        SW_EXT_TMP=$(mktemp)
        cat > "${SW_EXT_TMP}" <<EOF
basicConstraints=CA:FALSE
keyUsage=critical,digitalSignature,keyEncipherment
extendedKeyUsage=serverAuth,clientAuth
subjectAltName=DNS:${SEAWEEDFS_CONTAINER_NAME},DNS:seaweedfs.grafana.svc.cluster.local,DNS:localhost,IP:${SEAWEEDFS_IP},IP:127.0.0.1
EOF
        SW_CSR_TMP=$(mktemp)
        SW_KEY_TMP=$(mktemp)
        SW_CERT_TMP=$(mktemp)
        openssl req -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes \
            -keyout "${SW_KEY_TMP}" \
            -out "${SW_CSR_TMP}" \
            -subj "/CN=${SEAWEEDFS_CONTAINER_NAME}" 2>&1
        openssl x509 -req \
            -in "${SW_CSR_TMP}" \
            -CA "${SW_INT_CERT_TMP}" \
            -CAkey "${SW_INT_KEY_TMP}" \
            -CAcreateserial \
            -days 365 \
            -passin "pass:${SW_CA_PASSWORD}" \
            -extfile "${SW_EXT_TMP}" \
            -out "${SW_CERT_TMP}" 2>&1

        sudo cp "${SW_CERT_TMP}" "${SEAWEEDFS_TLS_DIR}/seaweedfs_cert.pem"
        sudo cp "${SW_KEY_TMP}"  "${SEAWEEDFS_TLS_DIR}/seaweedfs_key.pem"
        sudo chmod 644 "${SEAWEEDFS_TLS_DIR}/seaweedfs_cert.pem"
        sudo chmod 600 "${SEAWEEDFS_TLS_DIR}/seaweedfs_key.pem"
        # UID 1000 is the seaweed user inside chrislusf/seaweedfs container
        sudo setfacl -m "u:1000:rx" "${SEAWEEDFS_TLS_DIR}"
        sudo setfacl -d -m "u:1000:rx" "${SEAWEEDFS_TLS_DIR}"
        sudo setfacl -m "u:1000:r" "${SEAWEEDFS_TLS_DIR}/seaweedfs_cert.pem"
        sudo setfacl -m "u:1000:r" "${SEAWEEDFS_TLS_DIR}/seaweedfs_key.pem"
        rm -f "${SW_INT_CERT_TMP}" "${SW_INT_KEY_TMP}" "${SW_EXT_TMP}" \
              "${SW_CSR_TMP}" "${SW_KEY_TMP}" "${SW_CERT_TMP}"

        # Static S3 identities (-s3.config). Machine creds only; humans use OIDC/STS (-s3.iam.config, wired post-Traefik).
        #   admin  — full Admin, used only to bootstrap buckets during setup (not handed to any workload)
        #   loki   — RW on the 'loki' bucket only (blanket Admin removed)
        #   barman — RW/List on the backup buckets (CNPG/Barman, migrated off RustFS)
        sudo tee "${SEAWEEDFS_CFG_DIR}/identities.json" > /dev/null <<JSON
{
  "identities": [
    {
      "name": "admin",
      "credentials": [{"accessKey": "${SEAWEEDFS_ADMIN_ACCESS_KEY}", "secretKey": "${SEAWEEDFS_ADMIN_SECRET_KEY}"}],
      "actions": ["Admin"]
    },
    {
      "name": "loki",
      "credentials": [{"accessKey": "${SEAWEEDFS_ACCESS_KEY}", "secretKey": "${SEAWEEDFS_SECRET_KEY}"}],
      "actions": ["Read:loki", "Write:loki", "List:loki", "Tagging:loki"]
    },
    {
      "name": "barman",
      "credentials": [{"accessKey": "${SEAWEEDFS_BARMAN_ACCESS_KEY}", "secretKey": "${SEAWEEDFS_BARMAN_SECRET_KEY}"}],
      "actions": [
        "Read:${SEAWEEDFS_BACKUP_BUCKET}", "Write:${SEAWEEDFS_BACKUP_BUCKET}", "List:${SEAWEEDFS_BACKUP_BUCKET}", "Tagging:${SEAWEEDFS_BACKUP_BUCKET}",
        "Read:${SEAWEEDFS_VER_BACKUP_BUCKET}", "Write:${SEAWEEDFS_VER_BACKUP_BUCKET}", "List:${SEAWEEDFS_VER_BACKUP_BUCKET}", "Tagging:${SEAWEEDFS_VER_BACKUP_BUCKET}"
      ]
    }
  ]
}
JSON

        echo "🔒 Restarting '${SEAWEEDFS_CONTAINER_NAME}' with TLS enabled..."
        ${CONTAINER_PROVIDER} stop "${SEAWEEDFS_CONTAINER_NAME}"
        ${CONTAINER_PROVIDER} rm   "${SEAWEEDFS_CONTAINER_NAME}"
        ${CONTAINER_PROVIDER} run \
            --name "${SEAWEEDFS_CONTAINER_NAME}" -d \
            --network bridge \
            -p "${SEAWEEDFS_S3_PORT}:8333" \
            -p "${SEAWEEDFS_S3_HTTP_PORT}:${SEAWEEDFS_S3_HTTP_PORT}" \
            -p "${SEAWEEDFS_MASTER_PORT}:9333" \
            -p "${SEAWEEDFS_VOLUME_PORT}:9340" \
            -p "${SEAWEEDFS_FILER_PORT}:8889" \
            -v "${SEAWEEDFS_CONTAINER_NAME}:/data" \
            -v "${SEAWEEDFS_TLS_DIR}:/etc/seaweedfs/tls:ro" \
            -v "${SEAWEEDFS_CFG_DIR}/identities.json:/etc/seaweedfs/identities.json:ro" \
            --restart unless-stopped \
            "${SEAWEEDFS_IMAGE}" \
            server -dir=/data \
                -ip.bind=0.0.0.0 \
                -filer \
                -s3 \
                -filer.port=8889 \
                -volume.port=9340 \
                -s3.port="${SEAWEEDFS_S3_HTTP_PORT}" \
                -s3.port.https=8333 \
                -s3.cert.file=/etc/seaweedfs/tls/seaweedfs_cert.pem \
                -s3.key.file=/etc/seaweedfs/tls/seaweedfs_key.pem \
                -s3.config=/etc/seaweedfs/identities.json
        ${CONTAINER_PROVIDER} network connect kind "${SEAWEEDFS_CONTAINER_NAME}"

        # Pre-create Barman backup buckets (CNPG backups migrated off RustFS onto SeaweedFS).
        # Uses the bootstrap 'admin' identity (CreateBucket needs Admin); barman/loki stay least-privilege.
        echo "🪣 Creating SeaweedFS backup buckets (${SEAWEEDFS_BACKUP_BUCKET}, ${SEAWEEDFS_VER_BACKUP_BUCKET})..."
        # NB: minio/mc has ENTRYPOINT [mc], so override with --entrypoint sh to run a shell.
        retry 12 5 ${CONTAINER_PROVIDER} run --rm --network kind --entrypoint sh "${MC_IMAGE:-minio/mc:latest}" -c "
            mc --insecure alias set sw https://${SEAWEEDFS_IP}:8333 '${SEAWEEDFS_ADMIN_ACCESS_KEY}' '${SEAWEEDFS_ADMIN_SECRET_KEY}' \
            && mc --insecure mb --ignore-existing sw/${SEAWEEDFS_BACKUP_BUCKET} sw/${SEAWEEDFS_VER_BACKUP_BUCKET} \
            && echo '✅ SeaweedFS backup buckets ready'" \
            || echo "  ⚠️  Backup bucket init failed — verify SeaweedFS S3 gateway is up and 'admin' identity is valid"

        echo "🔒 Starting SeaweedFS admin UI with TLS..."
        sudo tee "${SEAWEEDFS_CFG_DIR}/security.toml" > /dev/null <<TOML
[https.admin]
cert = "/etc/seaweedfs/tls/seaweedfs_cert.pem"
key = "/etc/seaweedfs/tls/seaweedfs_key.pem"
TOML

        SEAWEEDFS_BRIDGE_IP=$(${CONTAINER_PROVIDER} inspect "${SEAWEEDFS_CONTAINER_NAME}" \
            --format '{{.NetworkSettings.Networks.bridge.IPAddress}}')
        ${CONTAINER_PROVIDER} stop  "${SEAWEEDFS_ADMIN_CONTAINER_NAME}" 2>/dev/null || true
        ${CONTAINER_PROVIDER} rm    "${SEAWEEDFS_ADMIN_CONTAINER_NAME}" 2>/dev/null || true
        ${CONTAINER_PROVIDER} run \
            --name "${SEAWEEDFS_ADMIN_CONTAINER_NAME}" -d \
            --network bridge \
            -p "${SEAWEEDFS_ADMIN_PORT}:23646" \
            -v "${SEAWEEDFS_TLS_DIR}:/etc/seaweedfs/tls:ro" \
            -v "${SEAWEEDFS_CFG_DIR}/security.toml:/etc/seaweedfs/security.toml:ro" \
            --restart unless-stopped \
            "${SEAWEEDFS_IMAGE}" \
            admin \
                -master="${SEAWEEDFS_BRIDGE_IP}:9333" \
                -port=23646 \
                -adminUser="${SEAWEEDFS_ADMIN_UI_USER}" \
                -adminPassword="${SEAWEEDFS_ADMIN_UI_PASSWORD}"

        echo "🔒 Starting SeaweedFS WebDAV with TLS..."
        ${CONTAINER_PROVIDER} stop  "${SEAWEEDFS_WEBDAV_CONTAINER_NAME}" 2>/dev/null || true
        ${CONTAINER_PROVIDER} rm    "${SEAWEEDFS_WEBDAV_CONTAINER_NAME}" 2>/dev/null || true
        ${CONTAINER_PROVIDER} run \
            --name "${SEAWEEDFS_WEBDAV_CONTAINER_NAME}" -d \
            --network bridge \
            -p "${SEAWEEDFS_WEBDAV_PORT}:7333" \
            -v "${SEAWEEDFS_TLS_DIR}:/etc/seaweedfs/tls:ro" \
            --restart unless-stopped \
            "${SEAWEEDFS_IMAGE}" \
            webdav \
                -port=7333 \
                -filer="${SEAWEEDFS_BRIDGE_IP}:8889" \
                -cert.file=/etc/seaweedfs/tls/seaweedfs_cert.pem \
                -key.file=/etc/seaweedfs/tls/seaweedfs_key.pem

        echo "🔧 Starting SeaweedFS maintenance worker..."
        SEAWEEDFS_ADMIN_BRIDGE_IP=$(${CONTAINER_PROVIDER} inspect "${SEAWEEDFS_ADMIN_CONTAINER_NAME}" \
            --format '{{.NetworkSettings.Networks.bridge.IPAddress}}')
        ${CONTAINER_PROVIDER} stop  "${SEAWEEDFS_WORKER_CONTAINER_NAME}" 2>/dev/null || true
        ${CONTAINER_PROVIDER} rm    "${SEAWEEDFS_WORKER_CONTAINER_NAME}" 2>/dev/null || true
        ${CONTAINER_PROVIDER} run \
            --name "${SEAWEEDFS_WORKER_CONTAINER_NAME}" -d \
            --network bridge \
            -p "${SEAWEEDFS_WORKER_METRICS_PORT}:9327" \
            --restart unless-stopped \
            "${SEAWEEDFS_IMAGE}" \
            worker \
                -admin="${SEAWEEDFS_ADMIN_BRIDGE_IP}:23646" \
                -jobType=all \
                -metricsPort=9327 \
                -workingDir=/tmp/seaweedfs-worker
    fi

    $CONTAINER_PROVIDER network connect kind "${STEP_CA_CONTAINER_NAME}" 2>/dev/null || true
    $CONTAINER_PROVIDER network connect kind "${VAULT_CONTAINER_NAME}" 2>/dev/null || true
    $CONTAINER_PROVIDER network connect kind "${AUTHELIA_CONTAINER_NAME}" 2>/dev/null || true
    $CONTAINER_PROVIDER network connect kind "${SEAWEEDFS_ADMIN_CONTAINER_NAME}" 2>/dev/null || true

    # Provision per-service TLS certs for the edge Traefik, then start the container.
    "${SCRIPT_DIR}/traefik-edge-setup.sh"

    echo "🔄 Starting external edge Traefik (${TRAEFIK_EDGE_CONTAINER_NAME} @ ${TRAEFIK_EDGE_IP})..."
    TRAEFIK_EDGE_DIR="${GIT_REPO_ROOT}/traefik-edge"
    TRAEFIK_EDGE_CERTS_DIR="${TRAEFIK_EDGE_DIR}/certs"
    $CONTAINER_PROVIDER stop  "${TRAEFIK_EDGE_CONTAINER_NAME}" 2>/dev/null || true
    $CONTAINER_PROVIDER rm    "${TRAEFIK_EDGE_CONTAINER_NAME}" 2>/dev/null || true
    $CONTAINER_PROVIDER run \
        --name "${TRAEFIK_EDGE_CONTAINER_NAME}" -d \
        --network kind --ip "${TRAEFIK_EDGE_IP}" \
        -p "${TRAEFIK_EDGE_HTTP_PORT}:80" \
        -p "${TRAEFIK_EDGE_HTTPS_PORT}:443" \
        -v "${TRAEFIK_EDGE_DIR}/traefik.yaml:/etc/traefik/traefik.yaml:ro" \
        -v "${TRAEFIK_EDGE_DIR}/dynamic:/etc/traefik/dynamic:ro" \
        -v "${TRAEFIK_EDGE_CERTS_DIR}:/etc/traefik/certs:ro" \
        --restart unless-stopped \
        "${TRAEFIK_EDGE_IMAGE}"
    echo "✅ Edge Traefik: https://*.${TRAEFIK_EDGE_IP_DASHED}.sslip.io"

    # Wire step-ca into K8s (namespace + headless Service/Endpoints)
    echo "🔧 Wiring step-ca into Kubernetes cluster '${K8S_CLUSTER_NAME}'..."
    kubectl --context "${CONTEXT_NAME}" create ns step-ca --dry-run=client -o yaml \
        | kubectl --context "${CONTEXT_NAME}" apply -f -
    STEP_CA_IP=$(${CONTAINER_PROVIDER} inspect "${STEP_CA_CONTAINER_NAME}" \
        --format '{{.NetworkSettings.Networks.kind.IPAddress}}')
    STEP_CA_IP="${STEP_CA_IP}" envsubst '${STEP_CA_IP}' \
        < "${GIT_REPO_ROOT}/step-ca/traefik/service.yaml.tpl" \
        | kubectl --context "${CONTEXT_NAME}" apply -f -

    # Wire Vault into K8s (namespace + headless Service/Endpoints)
    echo "🔧 Wiring Vault into Kubernetes cluster '${K8S_CLUSTER_NAME}'..."
    kubectl --context "${CONTEXT_NAME}" create ns vault --dry-run=client -o yaml \
        | kubectl --context "${CONTEXT_NAME}" apply -f -
    VAULT_IP=$(${CONTAINER_PROVIDER} inspect "${VAULT_CONTAINER_NAME}" \
        --format '{{.NetworkSettings.Networks.kind.IPAddress}}')
    VAULT_IP="${VAULT_IP}" envsubst '${VAULT_IP}' \
        < "${GIT_REPO_ROOT}/vault/traefik/service.yaml.tpl" \
        | kubectl --context "${CONTEXT_NAME}" apply -f -

    # cert-manager
    echo "🔧 Installing cert-manager ${CERT_MANAGER_CHART_VERSION} in '${K8S_CLUSTER_NAME}'..."
    # --no-wait: `helm --wait` stalls on cert-manager even when all pods are Ready;
    # the explicit `kubectl wait` below is the real readiness gate.
    helm_upgrade_install cert-manager \
        oci://quay.io/jetstack/charts/cert-manager \
        cert-manager "${CONTEXT_NAME}" "${CERT_MANAGER_CHART_VERSION}" \
        --no-wait \
        --set crds.enabled=true

    # Wait for cert-manager to be ready before creating Issuers/ClusterIssuers
    echo "⏳ Waiting for cert-manager webhook to be ready..."
    kubectl --context "${CONTEXT_NAME}" wait --for=condition=Available deployment/cert-manager-webhook -n cert-manager --timeout=120s

    # trust-manager (distributes CA bundles to all namespaces as ConfigMaps and Secrets)
    echo "🔧 Installing trust-manager ${TRUST_MANAGER_CHART_VERSION} in '${K8S_CLUSTER_NAME}'..."
    helm_upgrade_install trust-manager \
        oci://quay.io/jetstack/charts/trust-manager \
        cert-manager "${CONTEXT_NAME}" "${TRUST_MANAGER_CHART_VERSION}" \
        --no-wait \
        --set app.webhook.tls.helmCert.enabled=true \
        --set secretTargets.enabled=true \
        --set "secretTargets.authorizedSecrets[0]=vault-pki-bundle" \
        --set "secretTargets.authorizedSecrets[1]=step-ca-bundle" \
        --set "secretTargets.authorizedSecrets[2]=step-ca-external-bundle"

    # Wait for trust-manager webhook to be ready before creating Bundle resources
    echo "⏳ Waiting for trust-manager webhook to be ready..."
    kubectl --context "${CONTEXT_NAME}" wait --for=condition=Available deployment/trust-manager -n cert-manager --timeout=120s

    # Create ConfigMap with step-ca root + intermediate CA bundle
    echo "📜 Creating step-ca root CA ConfigMap for trust-manager..."
    STEP_CA_ROOT_CERT=$(sudo cat "${GIT_REPO_ROOT}/step-ca/pki/root_ca.crt")
    STEP_CA_INT_CERT=$(sudo cat "${GIT_REPO_ROOT}/step-ca/pki/intermediate_ca.crt")
    kubectl create configmap step-ca-roots \
        --namespace cert-manager --context "${CONTEXT_NAME}" \
        --from-literal=ca-certificates.crt="${STEP_CA_ROOT_CERT}
${STEP_CA_INT_CERT}" \
        --dry-run=client -o yaml | kubectl apply --context "${CONTEXT_NAME}" -f -

    # Apply trust-manager Bundle resources. Retry: the trust-manager webhook
    # Service endpoint may not be programmed yet right after the Deployment goes
    # Available (kube-proxy lag -> "connection refused"). Render to a file first
    # so the apply is re-runnable across retries.
    echo "📋 Applying step-ca trust-manager Bundle..."
    TRUST_BUNDLE_TMPFILE=$(mktemp)
    envsubst < "${GIT_REPO_ROOT}/step-ca/trust-manager/bundle.yaml.tpl" > "${TRUST_BUNDLE_TMPFILE}"
    retry 12 5 kubectl --context "${CONTEXT_NAME}" -n cert-manager apply -f "${TRUST_BUNDLE_TMPFILE}"
    rm -f "${TRUST_BUNDLE_TMPFILE}"

    # Create vault-pki-int-ca Secret (Vault PKI Intermediate CA 2)
    # This is the signing CA used by Vault's pki_int engine, chained to step-ca.
    # Extract just the first certificate from the chain file (the intermediate CA).
    echo "🔑 Creating vault-pki-int-ca Secret for trust-manager..."
    VAULT_PKI_INT_CA_TMPFILE=$(mktemp)
    awk '/-----BEGIN CERTIFICATE-----/{n++; if(n==1) found=1} found{print} /-----END CERTIFICATE-----/{if(found){found=0}}' \
        < "${GIT_REPO_ROOT}/vault/pki/intermediate.crt" \
        | sudo tee "${VAULT_PKI_INT_CA_TMPFILE}" > /dev/null
    kubectl create secret generic vault-pki-int-ca \
        --namespace cert-manager --context "${CONTEXT_NAME}" \
        --from-file=ca.crt="${VAULT_PKI_INT_CA_TMPFILE}" \
        --dry-run=client -o yaml | kubectl apply --context "${CONTEXT_NAME}" -f -
    rm -f "${VAULT_PKI_INT_CA_TMPFILE}"

    # Apply vault-pki trust-manager Bundle (full chain: step-ca root + int + vault pki int)
    echo "📋 Applying vault-pki trust-manager Bundle..."
    envsubst < "${GIT_REPO_ROOT}/vault/trust-manager/bundle.yaml.tpl" \
        | kubectl --context "${CONTEXT_NAME}" -n cert-manager apply -f -

    # Wait for Bundles to sync
    echo "⏳ Waiting for trust-manager Bundles to sync..."
    kubectl --context "${CONTEXT_NAME}" wait --for=condition=Synced bundle/step-ca-bundle --timeout=120s
    kubectl --context "${CONTEXT_NAME}" wait --for=condition=Synced bundle/vault-pki-bundle --timeout=120s

    # Apply step-ca-external-bundle for verifying external service certs
    # (signed by step-ca intermediate, not Vault PKI)
    echo "📋 Applying step-ca-external trust-manager Bundle..."
    kubectl apply --context "${CONTEXT_NAME}" -f \
        "${GIT_REPO_ROOT}/step-ca/trust-manager/bundle-external.yaml"
    kubectl --context "${CONTEXT_NAME}" wait --for=condition=Synced bundle/step-ca-external-bundle --timeout=60s

    # Secrets in cert-manager namespace
    echo "🔑 Creating cert-manager secrets for Vault PKI..."
    APPROLE_ROLE_ID=$(sudo cat "${GIT_REPO_ROOT}/vault/.approle_role_id")
    APPROLE_SECRET_ID=$(sudo cat "${GIT_REPO_ROOT}/vault/.approle_secret_id")
    kubectl create secret generic vault-approle \
        --namespace cert-manager --context "${CONTEXT_NAME}" \
        --from-literal=secretId="${APPROLE_SECRET_ID}" \
        --dry-run=client -o yaml | kubectl apply --context "${CONTEXT_NAME}" -f -
    kubectl create secret generic vault-tls-ca \
        --namespace cert-manager --context "${CONTEXT_NAME}" \
        --from-file=ca.crt="${GIT_REPO_ROOT}/vault/certs/vault-ca.pem" \
        --dry-run=client -o yaml | kubectl apply --context "${CONTEXT_NAME}" -f -

    # ClusterIssuer
    echo "📋 Applying vault-pki ClusterIssuer..."
    VAULT_CA_BUNDLE=$(sudo cat "${GIT_REPO_ROOT}/vault/certs/vault-ca.pem" | base64 -w0)
    VAULT_PORT="${VAULT_PORT}" \
    VAULT_APPROLE_ROLE_ID="${APPROLE_ROLE_ID}" \
    VAULT_CA_BUNDLE="${VAULT_CA_BUNDLE}" \
    envsubst '${VAULT_PORT} ${VAULT_APPROLE_ROLE_ID} ${VAULT_CA_BUNDLE}' \
        < "${GIT_REPO_ROOT}/vault/cert-manager/clusterissuer.yaml.tpl" \
        | kubectl --context "${CONTEXT_NAME}" apply -f -

    # ESO install + ClusterSecretStore for this cluster
    echo "🔌 Setting up ESO in '${K8S_CLUSTER_NAME}'..."
    export REGION="${region}"
    export CONTEXT_NAME="${CONTEXT_NAME}"
    "${SCRIPT_DIR}/eso-setup.sh"

    TRAEFIK_IP=$(echo "$IP_RANGE" | cut -d- -f1)
    TRAEFIK_IP_DASHED=$(ip_to_dashed "${TRAEFIK_IP}")
    # Issuer is the fixed hub in-cluster portal (same for every cluster, matches
    # gangplank); only STEP_CA_CHAIN_PEM is refreshed here for the hot-reload.
    echo "🔄 Re-rendering authn-config (apiserver hot-reload)..."
    STEP_CA_CHAIN_PEM=$(sudo cat "${GIT_REPO_ROOT}/step-ca/pki/root_ca.crt" "${GIT_REPO_ROOT}/step-ca/pki/intermediate_ca.crt" | sed 's/^/        /')
    HUB_TRAEFIK_IP_DASHED="${HUB_TRAEFIK_IP_DASHED}" \
    STEP_CA_CHAIN_PEM="${STEP_CA_CHAIN_PEM}" \
    envsubst '${HUB_TRAEFIK_IP_DASHED} ${STEP_CA_CHAIN_PEM}' \
        < "${GIT_REPO_ROOT}/k8s/authn-config.yaml.tpl" \
        > "${GIT_REPO_ROOT}/k8s/authn-config.yaml"

    echo "🔧 Installing Traefik ${TRAEFIK_CHART_VERSION} (chart) in '${K8S_CLUSTER_NAME}'..."
    if [[ "${region}" == "${HUB_REGION}" ]]; then
        # Hub: wire gRPC tracing to in-cluster OTel Collector (may not exist yet; Traefik retries)
        TRACING_SET_ARGS=(
            --set "tracing.otlp.grpc.enabled=true"
            --set "tracing.otlp.grpc.endpoint=otel-collector-opentelemetry-collector.otel.svc.cluster.local:4317"
            --set "tracing.otlp.grpc.insecure=true"
        )
    else
        # Non-hub: install without tracing; monitoring/setup.sh upgrades after hub Tempo is live
        TRACING_SET_ARGS=()
    fi
    helm_upgrade_install traefik \
        oci://ghcr.io/traefik/helm/traefik \
        traefik "${CONTEXT_NAME}" "${TRAEFIK_CHART_VERSION}" \
        --values "${GIT_REPO_ROOT}/traefik/values.yaml" \
        --set "tracing.serviceName=traefik-${region}" \
        --set "tracing.resourceAttributes.cluster=${region}" \
        "${TRACING_SET_ARGS[@]}"

    # Traefik dashboard TLS certificate
    echo "📜 Issuing Traefik dashboard TLS certificate..."
    TRAEFIK_IP_DASHED="${TRAEFIK_IP_DASHED}" envsubst '${TRAEFIK_IP_DASHED}' \
        < "${GIT_REPO_ROOT}/traefik/certificate-dashboard.yaml.tpl" \
        | kubectl --context "${CONTEXT_NAME}" apply -f -
    kubectl wait --for=condition=Ready certificate/traefik-dashboard-cert \
        -n traefik --timeout=120s --context "${CONTEXT_NAME}"

    # Traefik dashboard HTTPS IngressRoute
    echo "🌐 Applying Traefik dashboard IngressRoute (HTTPS)..."
    TRAEFIK_IP_DASHED="${TRAEFIK_IP_DASHED}" envsubst '${TRAEFIK_IP_DASHED}' \
        < "${GIT_REPO_ROOT}/traefik/ingressroute-dashboard.yaml.tpl" \
        | kubectl --context "${CONTEXT_NAME}" apply -f -
    echo "✅ Traefik dashboard: https://traefik.${TRAEFIK_IP_DASHED}.sslip.io"

    # Install metrics server
    echo "🕸️  Installing metrics server on '${K8S_CLUSTER_NAME}'..."
    helm_upgrade_install metrics-server \
        metrics-server \
        metrics-server "${CONTEXT_NAME}" "${METRICS_SERVER_CHART_VERSION}" \
        --repo-url https://kubernetes-sigs.github.io/metrics-server/ \
        --values "${GIT_REPO_ROOT}/k8s/metrics-server/values.yaml"

    kubectl --context "${CONTEXT_NAME}" wait --for=condition=Available deployment/metrics-server -n metrics-server --timeout=300s

    # Traefik postgres LoadBalancer Service (separate IP from HTTP/HTTPS)
    # The postgres entrypoint is not exposed on the main Traefik LB (expose.default: false),
    # so we create a dedicated LB service for postgres traffic.
    # TRAEFIK_POSTGRES_IP = TRAEFIK_IP with last octet +10
    TRAEFIK_POSTGRES_IP=$(echo "${TRAEFIK_IP}" | awk -F. '{OFS="."; $4=$4+10; print}')
    TRAEFIK_POSTGRES_IP_DASHED=$(ip_to_dashed "${TRAEFIK_POSTGRES_IP}")
    echo "🔧 Creating Traefik postgres LoadBalancer Service (${TRAEFIK_POSTGRES_IP})..."
    TRAEFIK_POSTGRES_IP="${TRAEFIK_POSTGRES_IP}" envsubst '${TRAEFIK_POSTGRES_IP}' \
        < "${GIT_REPO_ROOT}/traefik/service-postgres.yaml.tpl" \
        | kubectl --context "${CONTEXT_NAME}" apply -f -

    echo "🔧 Installing CNPG operator and Barman Cloud Plugin in '${K8S_CLUSTER_NAME}'..."
    install_cnpg_operator "${CONTEXT_NAME}"
    install_barman_plugin "${CONTEXT_NAME}"

    echo "🏛️  Installing Capsule ${CAPSULE_CHART_VERSION} in '${K8S_CLUSTER_NAME}'..."
    helm_upgrade_install capsule \
        oci://ghcr.io/projectcapsule/charts/capsule \
        capsule-system "${CONTEXT_NAME}" "${CAPSULE_CHART_VERSION}" \
        --values "${GIT_REPO_ROOT}/capsule/values.yaml" \
        --no-wait
    kubectl --context "${CONTEXT_NAME}" wait --for=condition=Available deployment/capsule-controller-manager -n capsule-system --timeout=300s

    echo "🔗 Installing capsule-proxy ${CAPSULE_PROXY_CHART_VERSION} in '${K8S_CLUSTER_NAME}'..."
    helm_upgrade_install capsule-proxy \
        oci://ghcr.io/projectcapsule/charts/capsule-proxy \
        capsule-system "${CONTEXT_NAME}" "${CAPSULE_PROXY_CHART_VERSION}" \
        --set "options.enableSSL=true" \
        --set "certManager.generateCertificates=true" \
        --set "certManager.issuer.name=vault-pki" \
        --set "certManager.issuer.kind=ClusterIssuer" \
        --set "certManager.certificate.fields.privateKey.algorithm=ECDSA" \
        --set "certManager.certificate.fields.privateKey.size=256" \
        --no-wait

    kubectl --context "${CONTEXT_NAME}" wait --for=condition=Available deployment/capsule-proxy -n capsule-system --timeout=300s

    # Expose capsule-proxy externally so the kubeconfig gangplank dispenses
    # (config.apiServerURL=https://capsule-proxy.<ip>.sslip.io) is reachable from a
    # tenant's kubectl. Traefik terminates TLS with a vault-pki cert whose SAN is the
    # external host, then re-encrypts to capsule-proxy:9001 (HTTPS, enableSSL=true) via
    # the insecureSkipVerify ServersTransport. Tenant auth (OIDC bearer token) is
    # preserved end to end, so no TCP passthrough is needed.
    echo "📜 Issuing capsule-proxy ingress TLS certificate in '${K8S_CLUSTER_NAME}'..."
    TRAEFIK_IP_DASHED="${TRAEFIK_IP_DASHED}" envsubst '${TRAEFIK_IP_DASHED}' \
        < "${GIT_REPO_ROOT}/capsule-proxy/certificate.yaml.tpl" \
        | kubectl --context "${CONTEXT_NAME}" apply -f -
    kubectl --context "${CONTEXT_NAME}" wait --for=condition=Ready \
        certificate/capsule-proxy-ingress-tls-cert -n capsule-system --timeout=120s

    echo "🌐 Applying capsule-proxy IngressRoute (HTTPS re-encrypt) in '${K8S_CLUSTER_NAME}'..."
    kubectl --context "${CONTEXT_NAME}" apply \
        -f "${GIT_REPO_ROOT}/capsule-proxy/serverstransport.yaml"
    TRAEFIK_IP_DASHED="${TRAEFIK_IP_DASHED}" envsubst '${TRAEFIK_IP_DASHED}' \
        < "${GIT_REPO_ROOT}/capsule-proxy/ingressroute.yaml.tpl" \
        | kubectl --context "${CONTEXT_NAME}" apply -f -
    echo "✅ capsule-proxy: https://capsule-proxy.${TRAEFIK_IP_DASHED}.sslip.io"

    echo "🏳️  Installing Kyverno ${KYVERNO_CHART_VERSION} in '${K8S_CLUSTER_NAME}'..."
    helm_upgrade_install kyverno \
        oci://ghcr.io/kyverno/charts/kyverno \
        kyverno "${CONTEXT_NAME}" "${KYVERNO_CHART_VERSION}"

    # The chart's default background-controller RBAC lacks get/list/watch on
    # rolebindings/roles (+ bind on admin/edit), which the synchronize=true
    # generate-tenant-rolebindings policy needs. Without this the policy is
    # rejected by the kyverno webhook and the argocd kyverno-policies app stays
    # OutOfSync. Aggregated ClusterRole, applied here (idempotent) rather than
    # via the rbr AppProject (which is tenant-scoped, no ClusterRole whitelist).
    echo "🔑 Granting kyverno background-controller read/bind on RoleBindings..."
    kubectl --context "${CONTEXT_NAME}" apply \
        -f "${GIT_REPO_ROOT}/kyverno/background-controller-rbac.yaml"

    # Upstream Pod Security Standards (baseline, Audit) bundle. Delivered here
    # imperatively rather than via ArgoCD because the rbr AppProject restricts
    # sourceRepos to this git repo (no external helm-repo sources), and it is
    # platform infra like the engine above. Namespace scoping (exclude platform
    # namespaces) lives in policies-values.yaml via per-policy `policyExclude`
    # (engine resourceFilters only gate admission, not background reporting).
    echo "🛡️  Installing kyverno-policies ${KYVERNO_POLICIES_CHART_VERSION} (PSS baseline, Audit)..."
    helm_upgrade_install kyverno-policies \
        kyverno-policies \
        kyverno "${CONTEXT_NAME}" "${KYVERNO_POLICIES_CHART_VERSION}" \
        --repo-url https://kyverno.github.io/kyverno/ \
        -f "${GIT_REPO_ROOT}/kyverno/policies-values.yaml"

    echo "🚀 Installing ArgoCD ${ARGOCD_CHART_VERSION} in '${K8S_CLUSTER_NAME}'..."
    helm_upgrade_install argocd \
        oci://ghcr.io/argoproj/argo-helm/argo-cd \
        argocd "${CONTEXT_NAME}" "${ARGOCD_CHART_VERSION}" \
        --values "${GIT_REPO_ROOT}/argocd/values.yaml" \
        --no-wait

    kubectl --context "${CONTEXT_NAME}" wait --for=condition=Available deployment/argocd-server -n argocd --timeout=300s
    kubectl --context "${CONTEXT_NAME}" rollout status statefulset/argocd-application-controller -n argocd --timeout=300s
    kubectl --context "${CONTEXT_NAME}" wait --for=condition=Available deployment/argocd-applicationset-controller -n argocd --timeout=300s

    echo "✅ Resource provisioning for '${region}' complete."

    # Store details for the next phase
    objectstore_ports["${region}"]="${current_objectstore_port}"
    all_objectstore_names+=("${RUSTFS_CONTAINER_NAME}")
    ((current_objectstore_port++))
done

echo "=================================================="
echo "🔑 Configuring Vault OIDC auth (once, post-loop)..."
echo "=================================================="
"${SCRIPT_DIR}/vault-oidc-setup.sh"
echo

# --- Phase 2: Distribute RustFS Secrets to all Clusters ---
echo
echo "--------------------------------------------------"
echo "🔑 Distributing RustFS secrets to all clusters"
echo "--------------------------------------------------"
for target_region in "${REGIONS[@]}"; do
    target_cluster_context=$(get_cluster_context "${target_region}")
    echo "   -> Configuring secrets in cluster: ${target_cluster_context}"

    for source_objectstore_name in "${all_objectstore_names[@]}"; do
        echo "      - Creating secret for ${source_objectstore_name}"
        kubectl create secret generic "${source_objectstore_name}" \
            --context "${target_cluster_context}" \
            --from-literal=ACCESS_KEY_ID="$RUSTFS_ROOT_USER" \
            --from-literal=ACCESS_SECRET_KEY="$RUSTFS_ROOT_PASSWORD"
    done
done

# --- Revocation Exporter (host container, --network host) ---
echo
echo "=================================================="
echo "🔍 Building + starting revocation exporter..."
echo "=================================================="
${CONTAINER_PROVIDER} build \
    -t "${REVOCATION_EXPORTER_IMAGE}" \
    "${GIT_REPO_ROOT}/revocation-exporter/"

# Build comma-separated ENDPOINTS: step-ca, vault, seaweedfs, one rustfs per region
REVOC_ENDPOINTS="step-ca:localhost:${STEP_CA_PORT},vault:localhost:${VAULT_PORT},seaweedfs:localhost:${SEAWEEDFS_S3_PORT},authelia:localhost:${AUTHELIA_PORT}"
for region in "${REGIONS[@]}"; do
    port="${objectstore_ports[${region}]}"
    REVOC_ENDPOINTS="${REVOC_ENDPOINTS},rustfs-${region}:localhost:${port}"
done

# Stop any previous instance before starting a fresh one
${CONTAINER_PROVIDER} rm -f "${REVOCATION_EXPORTER_CONTAINER_NAME}" > /dev/null 2>&1 || true

${CONTAINER_PROVIDER} run \
    --name "${REVOCATION_EXPORTER_CONTAINER_NAME}" -d \
    --network host \
    --restart unless-stopped \
    -v "${GIT_REPO_ROOT}/step-ca/pki/root_ca.crt:/etc/revocation-exporter/ca-bundle.crt:ro" \
    -e "ENDPOINTS=${REVOC_ENDPOINTS}" \
    -e "CA_BUNDLE=/etc/revocation-exporter/ca-bundle.crt" \
    -e "PORT=${REVOCATION_EXPORTER_PORT}" \
    -e "SCRAPE_INTERVAL=60" \
    "${REVOCATION_EXPORTER_IMAGE}"

echo "✅ Revocation exporter running on host:${REVOCATION_EXPORTER_PORT}"
echo "   Endpoints: ${REVOC_ENDPOINTS}"

HOST_IP_DASHED=$(hostname -I | awk '{print $1}' | tr '.' '-')
HUB_CONTEXT=$(get_cluster_context "${HUB_REGION}")
HUB_TRAEFIK_IP=$(kubectl get svc traefik -n traefik \
    -o jsonpath='{.status.loadBalancer.ingress[0].ip}' \
    --context "${HUB_CONTEXT}")
HUB_TRAEFIK_IP_DASHED=$(ip_to_dashed "${HUB_TRAEFIK_IP}")

echo "=================================================="
echo "🔐 Exposing Authelia via Traefik (hub cluster)..."
echo "=================================================="
# Authelia runs as a host container fronted by the external edge Traefik. Host
# containers (vault, seaweedfs-admin) use the edge portal authelia.${TRAEFIK_EDGE_IP_DASHED}
# directly. In-cluster clients (cookie domain ${HUB_TRAEFIK_IP_DASHED}) reach Authelia
# through an in-cluster portal: a hub IngressRoute for authelia.${HUB_TRAEFIK_IP_DASHED}
# that proxies to the edge, which routes that Host on to the Authelia container. This
# keeps each cookie's authelia_url a subdomain of its own domain (otherwise Authelia
# fatals with errFmtSessionDomainURLNotInCookieScope).

echo "🔄 Reconfiguring Authelia with two-domain session cookie..."
TRAEFIK_IP_DASHED="${HUB_TRAEFIK_IP_DASHED}" \
    "${SCRIPT_DIR}/authelia-setup.sh"

echo "🌐 Restoring in-cluster Authelia portal (proxied via edge Traefik)..."
kubectl create namespace authelia --context "${HUB_CONTEXT}" \
    --dry-run=client -o yaml | kubectl apply --context "${HUB_CONTEXT}" -f -

# Backend ExternalName -> edge Traefik (443); edge routes Host(authelia.${HUB_TRAEFIK_IP_DASHED})
TRAEFIK_EDGE_IP_DASHED="${TRAEFIK_EDGE_IP_DASHED}" envsubst '${TRAEFIK_EDGE_IP_DASHED}' \
    < "${GIT_REPO_ROOT}/authelia/backend-service.yaml.tpl" \
    | kubectl --context "${HUB_CONTEXT}" apply -f -

echo "📜 Issuing in-cluster Authelia portal TLS certificate..."
TRAEFIK_IP_DASHED="${HUB_TRAEFIK_IP_DASHED}" envsubst '${TRAEFIK_IP_DASHED}' \
    < "${GIT_REPO_ROOT}/authelia/certificate.yaml.tpl" \
    | kubectl --context "${HUB_CONTEXT}" apply -f -
kubectl wait --for=condition=Ready certificate/authelia-tls-cert \
    -n authelia --timeout=120s --context "${HUB_CONTEXT}"

TRAEFIK_IP_DASHED="${HUB_TRAEFIK_IP_DASHED}" envsubst '${TRAEFIK_IP_DASHED}' \
    < "${GIT_REPO_ROOT}/authelia/ingressroute.yaml.tpl" \
    | kubectl --context "${HUB_CONTEXT}" apply -f -
echo "✅ In-cluster Authelia portal at https://authelia.${HUB_TRAEFIK_IP_DASHED}.sslip.io (via edge)"

echo "=================================================="
echo "🔐 Wiring SeaweedFS S3 OIDC/STS (humans via Authelia)..."
echo "=================================================="
# Admin UI OIDC is NOT available in the OSS weed binary (admin UI = local password only),
# so this only covers the S3 API: humans call AssumeRoleWithWebIdentity with an Authelia JWT
# and get temporary S3 creds scoped by their 'groups' claim. Machine identities (loki, barman)
# keep using static keys via -s3.config. Both configs run together. See cnpg-playground-yt4
# for the deferred admin-UI access-control follow-up.
SEAWEEDFS_CFG_DIR="${GIT_REPO_ROOT}/seaweedfs/config"
SEAWEEDFS_TLS_DIR="${GIT_REPO_ROOT}/seaweedfs/tls"
SEAWEEDFS_IP=$(${CONTAINER_PROVIDER} inspect "${SEAWEEDFS_CONTAINER_NAME}" \
    --format '{{.NetworkSettings.Networks.kind.IPAddress}}')
AUTHELIA_ISSUER="https://authelia.${TRAEFIK_EDGE_IP_DASHED}.sslip.io"

# CA bundle so the S3 gateway can verify Authelia's step-ca-signed TLS cert.
# Authelia is now fronted by edge Traefik with a step-ca x5c cert (not vault PKI).
echo "📜 Building Authelia CA trust bundle for SeaweedFS..."
sudo bash -c "cat \
    '${GIT_REPO_ROOT}/step-ca/pki/intermediate_ca.crt' \
    '${GIT_REPO_ROOT}/step-ca/pki/root_ca.crt' \
    > '${SEAWEEDFS_CFG_DIR}/authelia-ca.pem'"

# IAM config (-s3.iam.config): STS + Authelia OIDC provider + role-per-group mapping.
#   group 'admin'            -> S3AdminRole    (full s3:*)
#   group 'rbr-ver-db-admin' -> S3BackupRWRole (RW on the tenant backup bucket)
#   group 'rbr-po'           -> S3BackupRORole (RO on the tenant backup bucket)
# No defaultRole: users in no mapped group cannot assume any role (deny by default).
# SECURITY: AssumeRoleWithWebIdentity lets the caller name the RoleArn directly, and the
# role trustPolicy — NOT the provider roleMapping — is the gate. So each trustPolicy must
# condition on BOTH oidc:iss AND oidc:groups (the required group); conditioning on issuer
# alone would let any Authelia user assume any role (e.g. rbr-po -> S3AdminRole). SeaweedFS
# evaluates StringEquals on an array claim as "any element matches".
echo "📝 Rendering SeaweedFS iam.json (issuer ${AUTHELIA_ISSUER})..."
sudo tee "${SEAWEEDFS_CFG_DIR}/iam.json" > /dev/null <<JSON
{
  "sts": {
    "tokenDuration": "1h",
    "maxSessionLength": "12h",
    "issuer": "seaweedfs-sts",
    "signingKey": "${SEAWEEDFS_STS_SIGNING_KEY}"
  },
  "providers": [
    {
      "name": "authelia",
      "type": "oidc",
      "enabled": true,
      "config": {
        "issuer": "${AUTHELIA_ISSUER}",
        "clientId": "seaweedfs-s3",
        "clientSecret": "${AUTHELIA_SEAWEEDFS_S3_CLIENT_SECRET}",
        "jwksUri": "${AUTHELIA_ISSUER}/jwks.json",
        "userInfoUri": "${AUTHELIA_ISSUER}/api/oidc/userinfo",
        "scopes": ["openid", "profile", "email", "groups"],
        "tlsCaCert": "/etc/seaweedfs/authelia-ca.pem",
        "roleMapping": {
          "rules": [
            { "claim": "groups", "value": "admin",            "role": "arn:aws:iam::role/S3AdminRole" },
            { "claim": "groups", "value": "rbr-ver-db-admin", "role": "arn:aws:iam::role/S3BackupRWRole" },
            { "claim": "groups", "value": "rbr-po",           "role": "arn:aws:iam::role/S3BackupRORole" }
          ]
        }
      }
    }
  ],
  "policies": [
    {
      "name": "S3AdminPolicy",
      "document": {
        "Version": "2012-10-17",
        "Statement": [
          { "Effect": "Allow", "Action": ["s3:*"], "Resource": ["*"] }
        ]
      }
    },
    {
      "name": "S3BackupRWPolicy",
      "document": {
        "Version": "2012-10-17",
        "Statement": [
          { "Effect": "Allow", "Action": ["s3:Get*", "s3:List*", "s3:Put*", "s3:DeleteObject"],
            "Resource": ["arn:aws:s3:::${SEAWEEDFS_VER_BACKUP_BUCKET}", "arn:aws:s3:::${SEAWEEDFS_VER_BACKUP_BUCKET}/*"] }
        ]
      }
    },
    {
      "name": "S3BackupROPolicy",
      "document": {
        "Version": "2012-10-17",
        "Statement": [
          { "Effect": "Allow", "Action": ["s3:Get*", "s3:List*"],
            "Resource": ["arn:aws:s3:::${SEAWEEDFS_VER_BACKUP_BUCKET}", "arn:aws:s3:::${SEAWEEDFS_VER_BACKUP_BUCKET}/*"] }
        ]
      }
    }
  ],
  "roles": [
    {
      "roleName": "S3AdminRole",
      "roleArn": "arn:aws:iam::role/S3AdminRole",
      "attachedPolicies": ["S3AdminPolicy"],
      "trustPolicy": {
        "Version": "2012-10-17",
        "Statement": [
          { "Effect": "Allow", "Principal": { "Federated": "*" }, "Action": ["sts:AssumeRoleWithWebIdentity"],
            "Condition": { "StringEquals": { "oidc:iss": "${AUTHELIA_ISSUER}", "oidc:groups": "admin" } } }
        ]
      }
    },
    {
      "roleName": "S3BackupRWRole",
      "roleArn": "arn:aws:iam::role/S3BackupRWRole",
      "attachedPolicies": ["S3BackupRWPolicy"],
      "trustPolicy": {
        "Version": "2012-10-17",
        "Statement": [
          { "Effect": "Allow", "Principal": { "Federated": "*" }, "Action": ["sts:AssumeRoleWithWebIdentity"],
            "Condition": { "StringEquals": { "oidc:iss": "${AUTHELIA_ISSUER}", "oidc:groups": "rbr-ver-db-admin" } } }
        ]
      }
    },
    {
      "roleName": "S3BackupRORole",
      "roleArn": "arn:aws:iam::role/S3BackupRORole",
      "attachedPolicies": ["S3BackupROPolicy"],
      "trustPolicy": {
        "Version": "2012-10-17",
        "Statement": [
          { "Effect": "Allow", "Principal": { "Federated": "*" }, "Action": ["sts:AssumeRoleWithWebIdentity"],
            "Condition": { "StringEquals": { "oidc:iss": "${AUTHELIA_ISSUER}", "oidc:groups": "rbr-po" } } }
        ]
      }
    }
  ]
}
JSON

echo "🔁 Restarting SeaweedFS S3 gateway with -s3.iam.config..."
${CONTAINER_PROVIDER} stop "${SEAWEEDFS_CONTAINER_NAME}"
${CONTAINER_PROVIDER} rm   "${SEAWEEDFS_CONTAINER_NAME}"
${CONTAINER_PROVIDER} run \
    --name "${SEAWEEDFS_CONTAINER_NAME}" -d \
    --network bridge \
    -p "${SEAWEEDFS_S3_PORT}:8333" \
    -p "${SEAWEEDFS_S3_HTTP_PORT}:${SEAWEEDFS_S3_HTTP_PORT}" \
    -p "${SEAWEEDFS_MASTER_PORT}:9333" \
    -p "${SEAWEEDFS_VOLUME_PORT}:9340" \
    -p "${SEAWEEDFS_FILER_PORT}:8889" \
    -v "${SEAWEEDFS_CONTAINER_NAME}:/data" \
    -v "${SEAWEEDFS_TLS_DIR}:/etc/seaweedfs/tls:ro" \
    -v "${SEAWEEDFS_CFG_DIR}/identities.json:/etc/seaweedfs/identities.json:ro" \
    -v "${SEAWEEDFS_CFG_DIR}/iam.json:/etc/seaweedfs/iam.json:ro" \
    -v "${SEAWEEDFS_CFG_DIR}/authelia-ca.pem:/etc/seaweedfs/authelia-ca.pem:ro" \
    --restart unless-stopped \
    "${SEAWEEDFS_IMAGE}" \
    server -dir=/data \
        -ip.bind=0.0.0.0 \
        -filer \
        -s3 \
        -filer.port=8889 \
        -volume.port=9340 \
        -s3.port="${SEAWEEDFS_S3_HTTP_PORT}" \
        -s3.port.https=8333 \
        -s3.cert.file=/etc/seaweedfs/tls/seaweedfs_cert.pem \
        -s3.key.file=/etc/seaweedfs/tls/seaweedfs_key.pem \
        -s3.config=/etc/seaweedfs/identities.json \
        -s3.iam.config=/etc/seaweedfs/iam.json
${CONTAINER_PROVIDER} network connect kind "${SEAWEEDFS_CONTAINER_NAME}"
echo "✅ SeaweedFS S3 OIDC/STS wired (clientId seaweedfs-s3, issuer ${AUTHELIA_ISSUER})"

echo "🔑 Installing gangplank (OIDC kubeconfig dispenser)..."
kubectl create namespace gangplank --context "${HUB_CONTEXT}" \
    --dry-run=client -o yaml | kubectl apply --context "${HUB_CONTEXT}" -f -

# Gangplank loads config.yaml then lets envconfig (prefix GANGPLANK_CONFIG_)
# override it. The chart injects this secret via envFrom, so the secret KEYS
# must be the exact env var names — not arbitrary clientID/clientSecret keys.
kubectl create secret generic gangplank-oidc \
    --namespace gangplank --context "${HUB_CONTEXT}" \
    --from-literal=GANGPLANK_CONFIG_CLIENT_ID=gangplank \
    --from-literal=GANGPLANK_CONFIG_CLIENT_SECRET="${AUTHELIA_GANGPLANK_CLIENT_SECRET}" \
    --dry-run=client -o yaml | kubectl apply --context "${HUB_CONTEXT}" -f -

helm_upgrade_install gangplank \
    gangplank \
    gangplank "${HUB_CONTEXT}" "${GANGPLANK_CHART_VERSION}" \
    --repo-url https://peak-scale.github.io/helm-charts \
    --set "config.clusterName=cnpg" \
    --set "config.apiServerURL=https://capsule-proxy.${HUB_TRAEFIK_IP_DASHED}.sslip.io" \
    --set "config.authorizeURL=https://authelia.${HUB_TRAEFIK_IP_DASHED}.sslip.io/api/oidc/authorization" \
    --set "config.tokenURL=https://authelia.${HUB_TRAEFIK_IP_DASHED}.sslip.io/api/oidc/token" \
    --set "config.redirectURL=https://gangplank.${HUB_TRAEFIK_IP_DASHED}.sslip.io/callback" \
    --set "config.usernameClaim=email" \
    --set "config.audience=gangplank" \
    --set-json 'config.scopes=["openid","email","profile","groups"]' \
    --set-json 'envFrom=[{"secretRef":{"name":"gangplank-oidc"}}]' \
    --set "config.clusterCAPath=/etc/step-ca/ca-certificates.crt" \
    --set "config.trustedCAPath=/etc/step-ca/ca-certificates.crt" \
    --set-json 'volumes=[{"name":"step-ca-bundle","configMap":{"name":"step-ca-bundle"}}]' \
    --set-json 'volumeMounts=[{"name":"step-ca-bundle","mountPath":"/etc/step-ca","readOnly":true}]'

# Issue gangplank's TLS cert and route it through Traefik (HTTP backend on :80,
# Traefik-terminated — same pattern as ArgoCD). The trust-manager-synced step-ca-bundle
# configMap (key ca-certificates.crt, present in every namespace) is mounted at
# /etc/step-ca: config.clusterCAPath points the dispensed kubeconfig's CA at it so kubectl
# trusts the capsule-proxy ingress cert, and config.trustedCAPath lets gangplank trust
# Authelia's step-ca-signed TLS during the server-side OIDC token exchange.
echo "📜 Issuing gangplank TLS certificate..."
TRAEFIK_IP_DASHED="${HUB_TRAEFIK_IP_DASHED}" envsubst '${TRAEFIK_IP_DASHED}' \
    < "${GIT_REPO_ROOT}/gangplank/certificate.yaml.tpl" \
    | kubectl --context "${HUB_CONTEXT}" apply -f -
kubectl --context "${HUB_CONTEXT}" wait --for=condition=Ready \
    certificate/gangplank-tls-cert -n gangplank --timeout=120s

echo "🌐 Applying gangplank IngressRoute (HTTPS)..."
TRAEFIK_IP_DASHED="${HUB_TRAEFIK_IP_DASHED}" envsubst '${TRAEFIK_IP_DASHED}' \
    < "${GIT_REPO_ROOT}/gangplank/ingressroute.yaml.tpl" \
    | kubectl --context "${HUB_CONTEXT}" apply -f -

echo "✅ gangplank: https://gangplank.${HUB_TRAEFIK_IP_DASHED}.sslip.io"

echo "=================================================="
echo "🔐 Configuring ArgoCD SSO + IngressRoute (hub cluster)..."
echo "=================================================="

# Seed OIDC client secret into argocd-secret (key referenced as $oidc.authelia.clientSecret in argocd-cm)
kubectl patch secret argocd-secret \
    --namespace argocd \
    --context "${HUB_CONTEXT}" \
    --type merge \
    -p "{\"stringData\":{\"oidc.authelia.clientSecret\":\"${AUTHELIA_ARGOCD_CLIENT_SECRET}\"}}"

# Patch argocd-cm with server URL + Authelia OIDC config.
# rootCA (indented 6 spaces to sit inside the oidc.config literal block) lets
# argocd-server verify Authelia's step-ca-signed TLS cert. $oidc.* stays literal
# because envsubst only substitutes the names in the allow-list below.
STEP_CA_CHAIN_PEM_ARGOCD=$(sudo cat "${GIT_REPO_ROOT}/step-ca/pki/root_ca.crt" \
    "${GIT_REPO_ROOT}/step-ca/pki/intermediate_ca.crt" | sed 's/^/      /')
_argocd_cm_patch=$(mktemp)
TRAEFIK_IP_DASHED="${HUB_TRAEFIK_IP_DASHED}" \
TRAEFIK_EDGE_IP_DASHED="${TRAEFIK_EDGE_IP_DASHED}" \
STEP_CA_CHAIN_PEM_ARGOCD="${STEP_CA_CHAIN_PEM_ARGOCD}" \
    envsubst '${TRAEFIK_IP_DASHED} ${TRAEFIK_EDGE_IP_DASHED} ${STEP_CA_CHAIN_PEM_ARGOCD}' \
    < "${GIT_REPO_ROOT}/argocd/argocd-cm-patch.yaml.tpl" \
    > "${_argocd_cm_patch}"
# Restore the ArgoCD secret reference that envsubst would otherwise mangle.
sed -i 's|__OIDC_CLIENT_SECRET_REF__|$oidc.authelia.clientSecret|' "${_argocd_cm_patch}"
kubectl patch configmap argocd-cm \
    --namespace argocd \
    --context "${HUB_CONTEXT}" \
    --type merge \
    --patch-file "${_argocd_cm_patch}"
rm -f "${_argocd_cm_patch}"

# Issue TLS certificate for ArgoCD
echo "📜 Issuing ArgoCD TLS certificate..."
TRAEFIK_IP_DASHED="${HUB_TRAEFIK_IP_DASHED}" envsubst '${TRAEFIK_IP_DASHED}' \
    < "${GIT_REPO_ROOT}/argocd/certificate.yaml.tpl" \
    | kubectl --context "${HUB_CONTEXT}" apply -f -
kubectl wait --for=condition=Ready certificate/argocd-tls-cert \
    -n argocd --timeout=120s --context "${HUB_CONTEXT}"

# Apply Traefik IngressRoute for ArgoCD
echo "🌐 Applying ArgoCD IngressRoute (HTTPS)..."
TRAEFIK_IP_DASHED="${HUB_TRAEFIK_IP_DASHED}" envsubst '${TRAEFIK_IP_DASHED}' \
    < "${GIT_REPO_ROOT}/argocd/ingressroute.yaml.tpl" \
    | kubectl --context "${HUB_CONTEXT}" apply -f -

# Restart argocd-server to pick up OIDC config changes
kubectl rollout restart deployment/argocd-server \
    -n argocd --context "${HUB_CONTEXT}"
kubectl rollout status deployment/argocd-server \
    -n argocd --context "${HUB_CONTEXT}" --timeout=120s

echo "✅ ArgoCD: https://argocd.${HUB_TRAEFIK_IP_DASHED}.sslip.io"

# NOTE: Tenant onboarding (Capsule Tenant 'rbr', tenant namespaces, demo-app image
# build, and the ArgoCD app-of-apps root) lives in demo/self-service-setup.sh so the
# cluster + platform come up clean and tenant-free. It is resequenced there to apply
# the app-of-apps AFTER the verstappen DB + verstappen-app secret exist (otherwise
# demo-app crash-loops). Run it via `demo/self-service-setup.sh setup local`, or use
# `scripts/setup.sh local --with-tenant` for the one-shot full demo (chained below).

echo "=================================================="
echo "🕸️  Installing Caretta network topology on hub cluster..."
echo "=================================================="

helm_upgrade_install caretta \
    caretta \
    caretta "${HUB_CONTEXT}" "${CARETTA_CHART_VERSION}" \
    --repo-url https://helm.groundcover.com \
    --values "${GIT_REPO_ROOT}/caretta/values.yaml"
echo "✅ Caretta: eBPF network topology active (metrics at http://caretta.caretta:7117)"

echo "=================================================="
echo "🔭 Installing Radar on hub cluster..."
echo "=================================================="

kubectl create namespace radar --context "${HUB_CONTEXT}" \
    --dry-run=client -o yaml | kubectl apply --context "${HUB_CONTEXT}" -f -

echo "📜 Issuing Radar TLS certificate..."
TRAEFIK_IP_DASHED="${HUB_TRAEFIK_IP_DASHED}" envsubst '${TRAEFIK_IP_DASHED}' \
    < "${GIT_REPO_ROOT}/radar/certificate.yaml.tpl" \
    | kubectl --context "${HUB_CONTEXT}" apply -f -
kubectl wait --for=condition=Ready certificate/radar-tls-cert \
    -n radar --timeout=120s --context "${HUB_CONTEXT}"

echo "🔭 Installing Radar ${RADAR_CHART_VERSION}..."
helm_upgrade_install radar \
    radar \
    radar "${HUB_CONTEXT}" "${RADAR_CHART_VERSION}" \
    --repo-url https://skyhook-io.github.io/helm-charts \
    --values "${GIT_REPO_ROOT}/radar/values.yaml"

echo "🌐 Applying Radar Middleware + IngressRoute (HTTPS)..."
# forwardAuth now targets the in-cluster Authelia portal (authelia.${HUB_TRAEFIK_IP_DASHED}).
TRAEFIK_IP_DASHED="${HUB_TRAEFIK_IP_DASHED}" envsubst '${TRAEFIK_IP_DASHED}' \
    < "${GIT_REPO_ROOT}/radar/middleware.yaml.tpl" \
    | kubectl --context "${HUB_CONTEXT}" apply -f -
TRAEFIK_IP_DASHED="${HUB_TRAEFIK_IP_DASHED}" envsubst '${TRAEFIK_IP_DASHED}' \
    < "${GIT_REPO_ROOT}/radar/ingressroute.yaml.tpl" \
    | kubectl --context "${HUB_CONTEXT}" apply -f -
echo "✅ Radar: https://radar.${HUB_TRAEFIK_IP_DASHED}.sslip.io"

# --- Final Instructions ---
echo
# Display information using the info script
source "$(dirname "$0")/info.sh"

# --- Optional: one-shot self-service tenant onboarding (--with-tenant) ---
# The cluster + platform are now up and tenant-free. With --with-tenant we chain
# monitoring (a hard requirement of the tenant's Grafana) and the self-service
# onboarding. These child scripts do NOT call acquire_lock, so the lock held by
# this script is not contended.
if [ "${WITH_TENANT}" = true ]; then
    echo
    echo "=================================================="
    echo "🧩 --with-tenant: chaining monitoring + self-service onboarding"
    echo "=================================================="
    "${GIT_REPO_ROOT}/monitoring/setup.sh" "${HUB_REGION}"
    "${GIT_REPO_ROOT}/demo/self-service-setup.sh" setup "${HUB_REGION}"
else
    echo
    echo "ℹ️  Cluster + platform ready (tenant-free). To onboard the self-service demo:"
    echo "     ${GIT_REPO_ROOT}/monitoring/setup.sh ${HUB_REGION}"
    echo "     ${GIT_REPO_ROOT}/demo/self-service-setup.sh setup ${HUB_REGION}"
    echo "   …or re-run with --with-tenant for the one-shot full demo."
fi
