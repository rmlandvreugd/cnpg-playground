#!/usr/bin/env bash
##
## Copyright © contributors to CloudNativePG, established as
## CloudNativePG a Series of LF Projects, LLC.
##
## Licensed under the Apache License, Version 2.0 (the "License");
## you may not use this file except in compliance with the License.
## You may obtain a copy of the License at
##
##     http://www.apache.org/licenses/LICENSE-2.0
##
## Unless required by applicable law or agreed to in writing, software
## distributed under the License is distributed on an "AS IS" BASIS,
## WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
## See the License for the specific language governing permissions and
## limitations under the License.
##
## SPDX-License-Identifier: Apache-2.0
##

#
# Tear down the Prometheus/Grafana stack installed by monitoring/setup.sh
#
# Removes all Helm releases, Kubernetes resources, and namespaces created by
# setup.sh, leaving the Kind clusters themselves intact.
# When run without arguments, auto-detects all cnpg-playground Kind clusters.
# To target specific regions only, pass region names as arguments.
#

# Source the common setup script
source $(git rev-parse --show-toplevel)/scripts/common.sh

# --- Main Logic ---
detect_running_regions "$@"

HUB_REGION="${REGIONS[0]}"
HUB_CONTEXT="$(get_cluster_context "${HUB_REGION}")"

for region in "${REGIONS[@]}"; do
    echo "-------------------------------------------------------------"
    echo " 🗑️  Tearing down monitoring for region: ${region}"
    echo "-------------------------------------------------------------"

    K8S_CLUSTER_NAME=$(get_cluster_name "${region}")
    CONTEXT_NAME=$(get_cluster_context "${region}")

    # --- Grafana namespace: Alloy, Loki, Grafana CRs, Grafana Operator ---
    echo "🗑️  Uninstalling Alloy in '${K8S_CLUSTER_NAME}'..."
    helm_uninstall_if_present alloy grafana "${CONTEXT_NAME}"

    echo "🗑️  Uninstalling Loki in '${K8S_CLUSTER_NAME}'..."
    helm_uninstall_if_present loki grafana "${CONTEXT_NAME}"

    echo "🗑️  Removing objectstore-local bridge from grafana namespace..."
    kubectl --context "${CONTEXT_NAME}" -n grafana delete service objectstore-local --ignore-not-found
    kubectl --context "${CONTEXT_NAME}" -n grafana delete endpoints objectstore-local --ignore-not-found

    echo "🗑️  Removing Grafana IngressRoute..."
    kubectl --context "${CONTEXT_NAME}" -n grafana delete ingressroute grafana --ignore-not-found

    echo "🗑️  Removing Grafana CRs, datasources, and dashboards..."
    if kubectl --context "${CONTEXT_NAME}" get crd grafanas.grafana.integreatly.org &>/dev/null; then
        kubectl kustomize "${GIT_REPO_ROOT}/monitoring/grafana/" | \
            kubectl --context "${CONTEXT_NAME}" delete --ignore-not-found -f -
    else
        echo "  ℹ️  Grafana CRDs absent — skipping CR delete (namespace deletion will clean up)"
    fi

    echo "🗑️  Uninstalling Grafana Operator in '${K8S_CLUSTER_NAME}'..."
    helm_uninstall_if_present grafana-operator grafana "${CONTEXT_NAME}"

    echo "🗑️  Deleting grafana namespace..."
    kubectl --context "${CONTEXT_NAME}" delete namespace grafana --ignore-not-found

    # --- prometheus-operator namespace: Prometheus CR, RBAC, kube-prometheus-stack ---
    echo "🗑️  Removing Prometheus CR..."
    if kubectl --context "${CONTEXT_NAME}" get crd prometheuses.monitoring.coreos.com &>/dev/null; then
        kubectl --context "${CONTEXT_NAME}" -n prometheus-operator \
            delete prometheus prometheus --ignore-not-found
    fi

    echo "🗑️  Removing Prometheus RBAC resources..."
    kubectl kustomize "${GIT_REPO_ROOT}/monitoring/prometheus-instance" | \
        kubectl --context "${CONTEXT_NAME}" delete --ignore-not-found -f -

    echo "🗑️  Uninstalling kube-prometheus-stack in '${K8S_CLUSTER_NAME}'..."
    helm_uninstall_if_present kube-prometheus-stack prometheus-operator "${CONTEXT_NAME}"

    echo "🗑️  Deleting prometheus-operator namespace..."
    kubectl --context "${CONTEXT_NAME}" delete namespace prometheus-operator --ignore-not-found
done

# --- Hub region only: Tempo and Mimir ---
echo "-------------------------------------------------------------"
echo " 🗑️  Tearing down hub-only components in region: ${HUB_REGION}"
echo "-------------------------------------------------------------"

echo "🗑️  Removing OTel Collector IngressRoute..."
kubectl --context "${HUB_CONTEXT}" -n otel delete ingressroute otel-push --ignore-not-found

echo "🗑️  Uninstalling OTel Collector in '$(get_cluster_name "${HUB_REGION}")'..."
helm_uninstall_if_present otel-collector otel "${HUB_CONTEXT}"

echo "🗑️  Deleting otel namespace..."
kubectl --context "${HUB_CONTEXT}" delete namespace otel --ignore-not-found

echo "🗑️  Uninstalling Tempo in '$(get_cluster_name "${HUB_REGION}")'..."
helm_uninstall_if_present tempo tempo "${HUB_CONTEXT}"

echo "🗑️  Removing objectstore-local bridge from tempo namespace..."
kubectl --context "${HUB_CONTEXT}" -n tempo delete service objectstore-local --ignore-not-found
kubectl --context "${HUB_CONTEXT}" -n tempo delete endpoints objectstore-local --ignore-not-found

echo "🗑️  Deleting tempo namespace..."
kubectl --context "${HUB_CONTEXT}" delete namespace tempo --ignore-not-found

echo "🗑️  Removing Mimir IngressRoute..."
kubectl --context "${HUB_CONTEXT}" -n mimir delete ingressroute mimir-push --ignore-not-found

echo "🗑️  Uninstalling Mimir in '$(get_cluster_name "${HUB_REGION}")'..."
helm_uninstall_if_present mimir mimir "${HUB_CONTEXT}"

echo "🗑️  Removing objectstore-local bridge from mimir namespace..."
kubectl --context "${HUB_CONTEXT}" -n mimir delete service objectstore-local --ignore-not-found
kubectl --context "${HUB_CONTEXT}" -n mimir delete endpoints objectstore-local --ignore-not-found

echo "🗑️  Deleting mimir namespace..."
kubectl --context "${HUB_CONTEXT}" delete namespace mimir --ignore-not-found

# --- Non-hub regions: revert Traefik OTLP tracing re-install ---
if [[ ${#REGIONS[@]} -gt 1 ]]; then
    echo "-------------------------------------------------------------"
    echo " 🔁 Reverting Traefik OTLP tracing on non-hub regions..."
    echo "-------------------------------------------------------------"
    for non_hub_region in "${REGIONS[@]}"; do
        if [[ "${non_hub_region}" != "${HUB_REGION}" ]]; then
            NON_HUB_CTX="$(get_cluster_context "${non_hub_region}")"
            echo "🔁 Restoring Traefik without OTLP tracing in region '${non_hub_region}'..."
            helm_upgrade_install traefik \
                oci://ghcr.io/traefik/helm/traefik \
                traefik "${NON_HUB_CTX}" "${TRAEFIK_CHART_VERSION}" \
                --values "${GIT_REPO_ROOT}/traefik/values.yaml" \
                --set "tracing.otlp.http.enabled=false"
        fi
    done
fi

echo "-------------------------------------------------------------"
echo " ✅ Monitoring teardown complete."
echo "-------------------------------------------------------------"
