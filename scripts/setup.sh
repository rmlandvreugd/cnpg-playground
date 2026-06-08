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
"${SCRIPT_DIR}/dex-setup.sh"
echo

# Setup a single, shared Kubeconfig for all clusters
export KUBECONFIG="${KUBE_CONFIG_PATH}"
> "${KUBE_CONFIG_PATH}" # Create or clear the kubeconfig file
cd "${GIT_REPO_ROOT}"
kind_config_path="${GIT_REPO_ROOT}/k8s/kind-cluster.yaml"

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
            -p "${SEAWEEDFS_MASTER_PORT}:9333" \
            -p "${SEAWEEDFS_VOLUME_PORT}:9340" \
            -p "${SEAWEEDFS_FILER_PORT}:8888" \
            -p "${SEAWEEDFS_ADMIN_PORT}:23646" \
            -v "${SEAWEEDFS_CONTAINER_NAME}:/data" \
            --restart unless-stopped \
            "${SEAWEEDFS_IMAGE}" \
            mini -dir=/data
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
subjectAltName=DNS:${SEAWEEDFS_CONTAINER_NAME},DNS:seaweedfs.grafana.svc.cluster.local,IP:${SEAWEEDFS_IP}
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
        sudo chmod 640 "${SEAWEEDFS_TLS_DIR}/seaweedfs_key.pem"
        rm -f "${SW_INT_CERT_TMP}" "${SW_INT_KEY_TMP}" "${SW_EXT_TMP}" \
              "${SW_CSR_TMP}" "${SW_KEY_TMP}" "${SW_CERT_TMP}"

        sudo tee "${SEAWEEDFS_CFG_DIR}/identities.json" > /dev/null <<JSON
{
  "identities": [
    {
      "name": "loki",
      "credentials": [{"accessKey": "${SEAWEEDFS_ACCESS_KEY}", "secretKey": "${SEAWEEDFS_SECRET_KEY}"}],
      "actions": ["Read:loki", "Write:loki", "List:loki", "Tagging:loki"]
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
            -p "${SEAWEEDFS_MASTER_PORT}:9333" \
            -p "${SEAWEEDFS_VOLUME_PORT}:9340" \
            -p "${SEAWEEDFS_FILER_PORT}:8888" \
            -p "${SEAWEEDFS_ADMIN_PORT}:23646" \
            -v "${SEAWEEDFS_CONTAINER_NAME}:/data" \
            -v "${SEAWEEDFS_TLS_DIR}:/etc/seaweedfs/tls:ro" \
            -v "${SEAWEEDFS_CFG_DIR}/identities.json:/etc/seaweedfs/identities.json:ro" \
            --restart unless-stopped \
            "${SEAWEEDFS_IMAGE}" \
            mini -dir=/data \
                -s3.port=0 \
                -s3.port.https=8333 \
                -s3.cert.file=/etc/seaweedfs/tls/seaweedfs_cert.pem \
                -s3.key.file=/etc/seaweedfs/tls/seaweedfs_key.pem \
                -s3.config=/etc/seaweedfs/identities.json
        ${CONTAINER_PROVIDER} network connect kind "${SEAWEEDFS_CONTAINER_NAME}"
    fi

    $CONTAINER_PROVIDER network connect kind "${STEP_CA_CONTAINER_NAME}" 2>/dev/null || true
    $CONTAINER_PROVIDER network connect kind "${VAULT_CONTAINER_NAME}" 2>/dev/null || true
    $CONTAINER_PROVIDER network connect kind "${DEX_CONTAINER_NAME}"   2>/dev/null || true

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
    helm_upgrade_install cert-manager \
        oci://quay.io/jetstack/charts/cert-manager \
        cert-manager "${CONTEXT_NAME}" "${CERT_MANAGER_CHART_VERSION}" \
        --set crds.enabled=true

    # Wait for cert-manager to be ready before creating Issuers/ClusterIssuers
    echo "⏳ Waiting for cert-manager webhook to be ready..."
    kubectl --context "${CONTEXT_NAME}" wait --for=condition=Available deployment/cert-manager-webhook -n cert-manager --timeout=120s

    # trust-manager (distributes CA bundles to all namespaces as ConfigMaps and Secrets)
    echo "🔧 Installing trust-manager ${TRUST_MANAGER_CHART_VERSION} in '${K8S_CLUSTER_NAME}'..."
    helm_upgrade_install trust-manager \
        oci://quay.io/jetstack/charts/trust-manager \
        cert-manager "${CONTEXT_NAME}" "${TRUST_MANAGER_CHART_VERSION}" \
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

    # Apply trust-manager Bundle resources
    echo "📋 Applying step-ca trust-manager Bundle..."
    envsubst < "${GIT_REPO_ROOT}/step-ca/trust-manager/bundle.yaml.tpl" \
        | kubectl --context "${CONTEXT_NAME}" -n cert-manager apply -f -

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

echo "=================================================="
echo "🔑 Adding step-ca OIDC provisioner (post-Dex)..."
echo "=================================================="
HOST_IP=$(hostname -I | awk '{print $1}')
HOST_IP_DASHED=$(echo "$HOST_IP" | tr '.' '-')
DEX_HOST="dex.${HOST_IP_DASHED}.sslip.io"

# Add step-ca's own intermediate CA to its trust store so step-ca can verify
# Dex's TLS cert (which is now signed by step-ca's intermediate CA via X5C provisioner)
echo "🔐 Adding step-ca intermediate CA to step-ca trust store (for Dex OIDC)..."
CA_CERTS_TMPFILE=$(mktemp)
${CONTAINER_PROVIDER} cp "${STEP_CA_CONTAINER_NAME}:/etc/ssl/certs/ca-certificates.crt" "${CA_CERTS_TMPFILE}"
sudo cat "${GIT_REPO_ROOT}/step-ca/pki/intermediate_ca.crt" >> "${CA_CERTS_TMPFILE}"
${CONTAINER_PROVIDER} cp "${CA_CERTS_TMPFILE}" "${STEP_CA_CONTAINER_NAME}:/tmp/ca-certificates.crt"
${CONTAINER_PROVIDER} exec -u 0 "${STEP_CA_CONTAINER_NAME}" sh -c 'cp /tmp/ca-certificates.crt /etc/ssl/certs/ca-certificates.crt && rm /tmp/ca-certificates.crt'
rm -f "${CA_CERTS_TMPFILE}"

STEP_CA_PASSWORD=$(sudo cat "${GIT_REPO_ROOT}/step-ca/secrets/.ca_password")
${CONTAINER_PROVIDER} exec \
    -e STEPPATH=/home/step \
    "${STEP_CA_CONTAINER_NAME}" \
    step ca provisioner add dex --type OIDC \
    --client-id "${DEX_OIDC_CLIENT_ID}" \
    --client-secret "${DEX_OIDC_CLIENT_SECRET}" \
    --configuration-endpoint "https://${DEX_HOST}:${DEX_PORT}/dex/.well-known/openid-configuration" \
    --password-file /home/step/secrets/password \
    --ca-config /home/step/config/ca.json
# Reload step-ca to pick up the new provisioner
${CONTAINER_PROVIDER} exec "${STEP_CA_CONTAINER_NAME}" kill -HUP 1
echo "✅ step-ca OIDC provisioner added"
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
REVOC_ENDPOINTS="step-ca:localhost:${STEP_CA_PORT},vault:localhost:${VAULT_PORT},seaweedfs:localhost:${SEAWEEDFS_S3_PORT}"
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

# --- Final Instructions ---
echo
# Display information using the info script
source "$(dirname "$0")/info.sh"
