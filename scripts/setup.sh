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
source "$(dirname "$0")/common.sh"

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
        --name "${RUSTFS_CONTAINER_NAME}" -d -p "${current_objectstore_port}:9001" \
        -v "${RUSTFS_CONTAINER_NAME}:/data" \
        -e "RUSTFS_ACCESS_KEY=${RUSTFS_ROOT_USER}" \
        -e "RUSTFS_SECRET_KEY=${RUSTFS_ROOT_PASSWORD}" \
        -e RUSTFS_CONSOLE_ENABLE=true \
        --restart unless-stopped \
        "${RUSTFS_IMAGE}" --console-enable /data

    echo "🏗️  Creating Kind cluster '${K8S_CLUSTER_NAME}'..."
    if [ "$CONTAINER_PROVIDER" == "podman" ]; then
        export KIND_EXPERIMENTAL_PROVIDER=podman
    fi
    kind create cluster --config "${kind_config_path}" --name "${K8S_CLUSTER_NAME}"

    echo "🏷️  Labeling nodes in '${K8S_CLUSTER_NAME}'..."
    kubectl label node -l postgres.node.kubernetes.io node-role.kubernetes.io/postgres= --context "$(get_cluster_context "${region}")"
    kubectl label node -l infra.node.kubernetes.io node-role.kubernetes.io/infra= --context "$(get_cluster_context "${region}")"
    kubectl label node -l app.node.kubernetes.io node-role.kubernetes.io/app= --context "$(get_cluster_context "${region}")"

    echo "🛠️  Installing MetalLB ${METALLB_VERSION} in '${K8S_CLUSTER_NAME}'..."
    # Enable strict ARP for kube-proxy
    kubectl get configmap kube-proxy -n kube-system -o yaml --context "$(get_cluster_context "${region}")" | \
    sed -e "s/strictARP: false/strictARP: true/" | \
    kubectl replace -f - --context "$(get_cluster_context "${region}")"

    # Install MetalLB
    kubectl apply -f "https://raw.githubusercontent.com/metallb/metallb/${METALLB_VERSION}/config/manifests/metallb-native.yaml" --context "$(get_cluster_context "${region}")"

    # Wait for MetalLB to be ready
    echo "⏳ Waiting for MetalLB to be ready in '${K8S_CLUSTER_NAME}'..."
    kubectl wait --namespace metallb-system \
                --for=condition=ready pod \
                --selector=app=metallb \
                --timeout=120s \
                --context "$(get_cluster_context "${region}")"

    # Determine the IP range for MetalLB based on the region index
    # to avoid conflicts on the shared 'kind' network.
    # We specifically look for the IPv4 subnet.
    KIND_NET_SUBNET=$($CONTAINER_PROVIDER network inspect kind -f '{{range .IPAM.Config}}{{.Subnet}}{{"\n"}}{{end}}' | grep '\.' | head -n 1)
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

    echo "🌐 Connecting RustFS to the Kind network..."
    $CONTAINER_PROVIDER network connect kind "${RUSTFS_CONTAINER_NAME}"

    TRAEFIK_IP=$(echo "$IP_RANGE" | cut -d- -f1)
    TRAEFIK_IP_DASHED=$(ip_to_dashed "${TRAEFIK_IP}")
    echo "🔧 Installing Traefik ${TRAEFIK_VERSION} in '${K8S_CLUSTER_NAME}'..."
    kubectl --context "${CONTEXT_NAME}" apply -f \
        "https://raw.githubusercontent.com/traefik/traefik/${TRAEFIK_VERSION}/docs/content/reference/dynamic-configuration/kubernetes-crd-definition-v1.yml"
    kubectl kustomize "${GIT_REPO_ROOT}/traefik" \
        | kubectl --context "${CONTEXT_NAME}" apply -f -
    kubectl --context "${CONTEXT_NAME}" -n traefik \
        rollout status deployment traefik --timeout=90s

    echo "🌐 Applying Traefik dashboard IngressRoute..."
    TRAEFIK_IP_DASHED="${TRAEFIK_IP_DASHED}" envsubst '${TRAEFIK_IP_DASHED}' \
        < "${GIT_REPO_ROOT}/traefik/ingressroute-dashboard.yaml.tpl" \
        | kubectl --context "${CONTEXT_NAME}" apply -f -
    echo "✅ Traefik dashboard: http://traefik.${TRAEFIK_IP_DASHED}.sslip.io"

    echo "✅ Resource provisioning for '${region}' complete."

    # Store details for the next phase
    objectstore_ports["${region}"]="${current_objectstore_port}"
    all_objectstore_names+=("${RUSTFS_CONTAINER_NAME}")
    ((current_objectstore_port++))
done

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

# --- Final Instructions ---
echo
# Display information using the info script
source "$(dirname "$0")/info.sh"
