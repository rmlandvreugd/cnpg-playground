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

HUB_REGION="${REGIONS[0]}"
HUB_CONTEXT="$(get_cluster_context "${HUB_REGION}")"

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

    # --- Mimir: hub install (first region only) ---
    if [[ "${region}" == "${HUB_REGION}" ]]; then
        echo "📦 Wiring objectstore into mimir namespace..."
        RUSTFS_CONTAINER_NAME="${RUSTFS_BASE_NAME}-${region}"
        OBJECTSTORE_IP=$(${CONTAINER_PROVIDER} inspect "${RUSTFS_CONTAINER_NAME}" \
            --format '{{.NetworkSettings.Networks.kind.IPAddress}}')
        kubectl --context "${CONTEXT_NAME}" create namespace mimir --dry-run=client -o yaml \
            | kubectl --context "${CONTEXT_NAME}" apply -f -
        OBJECTSTORE_IP="${OBJECTSTORE_IP}" envsubst '${OBJECTSTORE_IP}' \
            < "${GIT_REPO_ROOT}/monitoring/mimir/objectstore-bridge.yaml.tpl" \
            | kubectl --context "${CONTEXT_NAME}" apply -f -

        echo "🪣 Creating Mimir S3 buckets..."
        kubectl --context "${CONTEXT_NAME}" -n mimir delete pod mimir-bucket-init --ignore-not-found
        kubectl run mimir-bucket-init --restart=Never \
            --context "${CONTEXT_NAME}" \
            -n mimir \
            --image=minio/mc:latest \
            --pod-running-timeout=60s \
            --command -- sh -c "mc alias set store http://objectstore-local:9000 '${RUSTFS_ROOT_USER}' '${RUSTFS_ROOT_PASSWORD}' >/dev/null 2>&1 \
                && mc mb --ignore-existing store/mimir-blocks \
                && mc mb --ignore-existing store/mimir-alertmanager \
                && mc mb --ignore-existing store/mimir-ruler \
                && echo '✅ Mimir buckets ready'"
        kubectl --context "${CONTEXT_NAME}" -n mimir wait pod/mimir-bucket-init \
            --for=jsonpath='{.status.phase}'=Succeeded --timeout=60s \
            && kubectl --context "${CONTEXT_NAME}" -n mimir logs pod/mimir-bucket-init \
            || echo "  ⚠️  Mimir bucket init may have failed — verify manually"
        kubectl --context "${CONTEXT_NAME}" -n mimir delete pod mimir-bucket-init --ignore-not-found

        echo "📊 Installing Mimir ${MIMIR_CHART_VERSION} in '${K8S_CLUSTER_NAME}'..."
        helm_upgrade_install mimir \
            oci://ghcr.io/grafana/helm-charts/mimir-distributed \
            mimir "${CONTEXT_NAME}" "${MIMIR_CHART_VERSION}" \
            --values "${GIT_REPO_ROOT}/monitoring/mimir/mimir-values.yaml" \
            --set "mimir.structuredConfig.common.storage.s3.access_key_id=${RUSTFS_ROOT_USER}" \
            --set "mimir.structuredConfig.common.storage.s3.secret_access_key=${RUSTFS_ROOT_PASSWORD}"

        if [[ ${#REGIONS[@]} -gt 1 ]]; then
            HUB_TRAEFIK_IP="$(get_traefik_lb_ip "${HUB_CONTEXT}" 30)"
            HUB_TRAEFIK_DASHED="$(ip_to_dashed "${HUB_TRAEFIK_IP}")"
            TRAEFIK_IP_DASHED="${HUB_TRAEFIK_DASHED}" envsubst '${TRAEFIK_IP_DASHED}' \
                < "${GIT_REPO_ROOT}/monitoring/mimir/ingressroute.yaml.tpl" \
                | kubectl --context "${CONTEXT_NAME}" apply -f -
        fi
    fi

    # Compute MIMIR_PUSH_URL for this region
    if [[ "${region}" == "${HUB_REGION}" ]]; then
        MIMIR_PUSH_URL="http://mimir-nginx.mimir.svc.cluster.local/api/v1/push"
    else
        HUB_TRAEFIK_IP="$(get_traefik_lb_ip "${HUB_CONTEXT}" 30)"
        HUB_TRAEFIK_DASHED="$(ip_to_dashed "${HUB_TRAEFIK_IP}")"
        MIMIR_PUSH_URL="http://mimir-push.${HUB_TRAEFIK_DASHED}.sslip.io/api/v1/push"
    fi

    echo "📊 Applying Prometheus CR with remoteWrite → Mimir for '${region}'..."
    REGION="${region}" MIMIR_PUSH_URL="${MIMIR_PUSH_URL}" \
        envsubst '${REGION} ${MIMIR_PUSH_URL}' \
        < "${GIT_REPO_ROOT}/monitoring/prometheus-instance/prometheus-cr.yaml.tpl" \
        | kubectl --context "${CONTEXT_NAME}" apply --force-conflicts --server-side -f -

    # --- Tempo: hub install (first region only) ---
    if [[ "${region}" == "${HUB_REGION}" ]]; then
        echo "📦 Wiring objectstore into tempo namespace..."
        RUSTFS_CONTAINER_NAME="${RUSTFS_BASE_NAME}-${region}"
        OBJECTSTORE_IP=$(${CONTAINER_PROVIDER} inspect "${RUSTFS_CONTAINER_NAME}" \
            --format '{{.NetworkSettings.Networks.kind.IPAddress}}')
        kubectl --context "${CONTEXT_NAME}" create namespace tempo --dry-run=client -o yaml \
            | kubectl --context "${CONTEXT_NAME}" apply -f -
        OBJECTSTORE_IP="${OBJECTSTORE_IP}" envsubst '${OBJECTSTORE_IP}' \
            < "${GIT_REPO_ROOT}/monitoring/tempo/objectstore-bridge.yaml.tpl" \
            | kubectl --context "${CONTEXT_NAME}" apply -f -

        echo "🪣 Creating Tempo S3 bucket..."
        kubectl --context "${CONTEXT_NAME}" -n tempo delete pod tempo-bucket-init --ignore-not-found
        kubectl run tempo-bucket-init --restart=Never \
            --context "${CONTEXT_NAME}" \
            -n tempo \
            --image=minio/mc:latest \
            --pod-running-timeout=60s \
            --command -- sh -c "mc alias set store http://objectstore-local:9000 '${RUSTFS_ROOT_USER}' '${RUSTFS_ROOT_PASSWORD}' >/dev/null 2>&1 \
                && mc mb --ignore-existing store/tempo \
                && echo '✅ Bucket tempo ready'"
        kubectl --context "${CONTEXT_NAME}" -n tempo wait pod/tempo-bucket-init \
            --for=jsonpath='{.status.phase}'=Succeeded --timeout=60s \
            && kubectl --context "${CONTEXT_NAME}" -n tempo logs pod/tempo-bucket-init \
            || echo "  ⚠️  Tempo bucket init may have failed — verify manually"
        kubectl --context "${CONTEXT_NAME}" -n tempo delete pod tempo-bucket-init --ignore-not-found

        echo "📊 Installing Tempo ${TEMPO_CHART_VERSION} in '${K8S_CLUSTER_NAME}'..."
        helm_upgrade_install tempo \
            oci://ghcr.io/grafana-community/helm-charts/tempo-distributed \
            tempo "${CONTEXT_NAME}" "${TEMPO_CHART_VERSION}" \
            --values "${GIT_REPO_ROOT}/monitoring/tempo/tempo-values.yaml" \
            --set "storage.trace.s3.access_key=${RUSTFS_ROOT_USER}" \
            --set "storage.trace.s3.secret_key=${RUSTFS_ROOT_PASSWORD}"

        echo "📡 Installing OTel Collector (tail-based sampling gateway)..."
        kubectl --context "${CONTEXT_NAME}" create namespace otel --dry-run=client -o yaml \
            | kubectl --context "${CONTEXT_NAME}" apply -f -

        helm_upgrade_install otel-collector \
            oci://ghcr.io/open-telemetry/opentelemetry-helm-charts/opentelemetry-collector \
            otel "${CONTEXT_NAME}" "${OTEL_COLLECTOR_CHART_VERSION}" \
            --values "${GIT_REPO_ROOT}/monitoring/otel-collector/otel-collector-values.yaml" \
            --set "image.tag=${OTEL_COLLECTOR_IMAGE_TAG}"

        kubectl --context "${CONTEXT_NAME}" -n otel rollout status deploy/otel-collector-opentelemetry-collector \
            --timeout=120s

        kubectl --context "${CONTEXT_NAME}" delete ingressroute tempo-otlp-http -n tempo \
            --ignore-not-found

        if [[ ${#REGIONS[@]} -gt 1 ]]; then
            HUB_TRAEFIK_IP="$(get_traefik_lb_ip "${HUB_CONTEXT}" 30)"
            HUB_TRAEFIK_DASHED="$(ip_to_dashed "${HUB_TRAEFIK_IP}")"
            TRAEFIK_IP_DASHED="${HUB_TRAEFIK_DASHED}" envsubst '${TRAEFIK_IP_DASHED}' \
                < "${GIT_REPO_ROOT}/monitoring/otel-collector/ingressroute.yaml.tpl" \
                | kubectl --context "${CONTEXT_NAME}" apply -f -

            echo "🔁 Reapplying Traefik on non-hub regions to push OTLP to otel-collector..."
            for non_hub_region in "${REGIONS[@]}"; do
                if [[ "${non_hub_region}" != "${HUB_REGION}" ]]; then
                    NON_HUB_CTX="$(get_cluster_context "${non_hub_region}")"
                    helm_upgrade_install traefik \
                        oci://ghcr.io/traefik/helm/traefik \
                        traefik "${NON_HUB_CTX}" "${TRAEFIK_CHART_VERSION}" \
                        --values "${GIT_REPO_ROOT}/traefik/values.yaml" \
                        --set "tracing.otlp.http.enabled=true" \
                        --set "tracing.otlp.http.endpoint=http://otel-push.${HUB_TRAEFIK_DASHED}.sslip.io/v1/traces" \
                        --set "tracing.serviceName=traefik-${non_hub_region}" \
                        --set "tracing.resourceAttributes.cluster=${non_hub_region}"
                fi
            done
        fi
    fi

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

    echo "📊 Applying Mimir datasource (tenant=${region}) + prometheus alias..."
    REGION="${region}" envsubst '${REGION}' \
        < "${GIT_REPO_ROOT}/monitoring/grafana/grafana_datasource_mimir.yaml.tpl" \
        | kubectl --context "${CONTEXT_NAME}" apply -f -
    REGION="${region}" envsubst '${REGION}' \
        < "${GIT_REPO_ROOT}/monitoring/grafana/grafana_datasource_prometheus_alias.yaml.tpl" \
        | kubectl --context "${CONTEXT_NAME}" apply -f -

    # --- Loki + Alloy (pgaudit log aggregation) ---
    echo "📊 Wiring objectstore into grafana namespace for Loki..."
    RUSTFS_CONTAINER_NAME="${RUSTFS_BASE_NAME}-${region}"
    OBJECTSTORE_IP=$(${CONTAINER_PROVIDER} inspect "${RUSTFS_CONTAINER_NAME}" \
        --format '{{.NetworkSettings.Networks.kind.IPAddress}}')
    kubectl --context "${CONTEXT_NAME}" apply -f - <<EOF
apiVersion: v1
kind: Service
metadata:
  name: objectstore-local
  namespace: grafana
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
  namespace: grafana
subsets:
  - addresses:
      - ip: ${OBJECTSTORE_IP}
    ports:
      - name: s3
        port: 9000
EOF

    echo "🪣 Creating Loki S3 bucket..."
    kubectl --context "${CONTEXT_NAME}" -n grafana delete pod loki-bucket-init --ignore-not-found
    kubectl run loki-bucket-init --restart=Never \
        --context "${CONTEXT_NAME}" \
        -n grafana \
        --image=minio/mc:latest \
        --pod-running-timeout=60s \
        --command -- sh -c "mc alias set store http://objectstore-local:9000 '${RUSTFS_ROOT_USER}' '${RUSTFS_ROOT_PASSWORD}' >/dev/null 2>&1 \
            && mc mb --ignore-existing store/loki \
            && echo '✅ Bucket loki ready'"
    kubectl --context "${CONTEXT_NAME}" -n grafana wait pod/loki-bucket-init \
        --for=jsonpath='{.status.phase}'=Succeeded --timeout=60s \
        && kubectl --context "${CONTEXT_NAME}" -n grafana logs pod/loki-bucket-init \
        || echo "  ⚠️  Bucket init may have failed — verify: kubectl run mc ... mc mb store/loki"
    kubectl --context "${CONTEXT_NAME}" -n grafana delete pod loki-bucket-init --ignore-not-found

    echo "📊 Installing Loki ${LOKI_CHART_VERSION} in '${K8S_CLUSTER_NAME}'..."
    helm_upgrade_install loki oci://ghcr.io/grafana-community/helm-charts/loki \
        grafana "${CONTEXT_NAME}" "${LOKI_CHART_VERSION}" \
        --values "${GIT_REPO_ROOT}/monitoring/loki/loki-values.yaml" \
        --set "loki.storage.s3.accessKeyId=${RUSTFS_ROOT_USER}" \
        --set "loki.storage.s3.secretAccessKey=${RUSTFS_ROOT_PASSWORD}"

    RENDERED_ALLOY_CONFIG="$(mktemp)"
    REGION="${region}" MIMIR_PUSH_URL="${MIMIR_PUSH_URL}" \
        envsubst '${REGION} ${MIMIR_PUSH_URL}' \
        < "${GIT_REPO_ROOT}/monitoring/alloy/alloy-config.river.tpl" \
        > "${RENDERED_ALLOY_CONFIG}"

    echo "📊 Installing Alloy ${ALLOY_CHART_VERSION} in '${K8S_CLUSTER_NAME}'..."
    helm_upgrade_install alloy alloy \
        grafana "${CONTEXT_NAME}" "${ALLOY_CHART_VERSION}" \
        --repo-url https://grafana.github.io/helm-charts \
        --values "${GIT_REPO_ROOT}/monitoring/alloy/alloy-values.yaml" \
        --set-file "alloy.configMap.content=${RENDERED_ALLOY_CONFIG}"

    rm -f "${RENDERED_ALLOY_CONFIG}"

    echo "🔄 Reloading Alloy config (config-reloader sidecar sometimes misses helm configmap update)..."
    kubectl --context "${CONTEXT_NAME}" rollout restart deployment/alloy -n grafana
    kubectl --context "${CONTEXT_NAME}" rollout status deployment/alloy -n grafana --timeout=120s

# Restart the operator
if kubectl get ns cnpg-system &> /dev/null; then
  CNPG_DEPLOY=$(kubectl get deployment -n cnpg-system -o name 2>/dev/null | grep -E "cnpg|cloudnative-pg" | head -1)
  if [[ -n "${CNPG_DEPLOY}" ]]; then
    kubectl rollout restart "${CNPG_DEPLOY}" -n cnpg-system
    kubectl rollout status "${CNPG_DEPLOY}" -n cnpg-system
  fi
fi

    if kubectl --context "${CONTEXT_NAME}" get namespace cnpg-system &>/dev/null; then
        echo "📊 Applying CNPG PodMonitors (operator + cluster/pooler wildcards)..."
        kubectl --context "${CONTEXT_NAME}" apply \
            -f "${GIT_REPO_ROOT}/monitoring/cnpg/cnpg-operator-podmonitor.yaml" \
            -f "${GIT_REPO_ROOT}/monitoring/cnpg/cnpg-cluster-wildcard-podmonitor.yaml" \
            -f "${GIT_REPO_ROOT}/monitoring/cnpg/cnpg-pooler-wildcard-podmonitor.yaml"
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
