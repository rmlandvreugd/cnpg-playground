#!/usr/bin/env bash
#
# This script installs and configures the Prometheus and Grafana operators.
# When run without arguments, it automatically detects all cnpg-playground
# Kind clusters in your environment and deploys the monitoring stack for each.
# To install monitoring for specific regions only, pass the region names as arguments.
#
#
# Copyright The CloudNativePG Contributors
#
# Setup a Prometheus/Grafana stack on infrastructure nodes
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
source $(git rev-parse --show-toplevel)/scripts/common.sh

# --- Main Logic ---
# Determine regions from arguments, or auto-detect if none are provided
detect_running_regions "$@"

# Add a target port for the port-forward, the port will be incremeted by 1 for each region
port=3001

for region in "${REGIONS[@]}"; do
    echo "-------------------------------------------------------------"
    echo " 🔥 Provisioning Prometheus resources for region: ${region}"
    echo "-------------------------------------------------------------"

    K8S_CLUSTER_NAME=$(get_cluster_name "${region}")
    CONTEXT_NAME=$(get_cluster_context "${region}")

    echo "📊 Installing kube-prometheus-stack ${KUBE_PROMETHEUS_STACK_CHART_VERSION} in '${K8S_CLUSTER_NAME}'..."
    helm_upgrade_install kube-prometheus-stack \
        oci://ghcr.io/prometheus-community/charts/kube-prometheus-stack \
        prometheus-operator "${CONTEXT_NAME}" "${KUBE_PROMETHEUS_STACK_CHART_VERSION}" \
        --values "${GIT_REPO_ROOT}/monitoring/kube-prometheus-stack-values.yaml"

    kubectl kustomize ${GIT_REPO_ROOT}/monitoring/prometheus-instance | \
        kubectl --context=${CONTEXT_NAME} apply --force-conflicts --server-side -f -

    echo "-------------------------------------------------------------"
    echo " 📈 Provisioning Grafana resources for region: ${region}"
    echo "-------------------------------------------------------------"

    echo "📈 Installing Grafana Operator ${GRAFANA_OPERATOR_CHART_VERSION} in '${K8S_CLUSTER_NAME}'..."
    helm_upgrade_install grafana-operator \
        oci://ghcr.io/grafana/helm-charts/grafana-operator \
        grafana "${CONTEXT_NAME}" "${GRAFANA_OPERATOR_CHART_VERSION}" \
        --set "nodeSelector.node-role\\.kubernetes\\.io/infra=" \
        --set "tolerations[0].key=node-role.kubernetes.io/infra" \
        --set "tolerations[0].operator=Exists" \
        --set "tolerations[0].effect=NoSchedule"

# Creating Grafana instance and dashboards
    kubectl kustomize ${GIT_REPO_ROOT}/monitoring/grafana/ | \
      kubectl --context ${CONTEXT_NAME} apply -f -

# Restart the operator
if kubectl get ns cnpg-system &> /dev/null
then
  kubectl rollout restart deployment -n cnpg-system cnpg-controller-manager
  kubectl rollout status deployment -n cnpg-system cnpg-controller-manager
fi

    if TRAEFIK_LB_IP=$(get_traefik_lb_ip "${CONTEXT_NAME}" 30); then
        TRAEFIK_IP_DASHED=$(ip_to_dashed "${TRAEFIK_LB_IP}")
        TRAEFIK_IP_DASHED="${TRAEFIK_IP_DASHED}" envsubst '${TRAEFIK_IP_DASHED}' \
            < "${GIT_REPO_ROOT}/monitoring/grafana/ingressroute.yaml.tpl" \
            | kubectl --context "${CONTEXT_NAME}" apply -f -
        echo "-----------------------------------------------------------------------------------------------------------------"
        echo " 📈 Grafana is available at:"
        echo " http://grafana.${TRAEFIK_IP_DASHED}.sslip.io"
        echo " The default password for the user admin is 'admin'."
        echo "-----------------------------------------------------------------------------------------------------------------"
    else
        echo "⚠️  Traefik not found in ${CONTEXT_NAME} — falling back to port-forward"
        echo "-----------------------------------------------------------------------------------------------------------------"
        echo " ⏩ To forward the Grafana service for region: ${region} to your localhost"
        echo " Wait for the Grafana service to be created and then forward the service"
        echo ""
        echo " kubectl port-forward service/grafana-service ${port}:3000 -n grafana --context ${CONTEXT_NAME}"
        echo ""
        echo " You can then connect to the Grafana GUI using"
        echo " http://localhost:${port}"
        echo " The default password for the user admin is 'admin'. You will be prompted to change the password on the first login."
        echo "-----------------------------------------------------------------------------------------------------------------"
    fi
    # increment target port by 1
    ((port++))
done
