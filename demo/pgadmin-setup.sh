#!/usr/bin/env bash
#
# Deploy pgAdmin4 as a web UI for the local PostgreSQL cluster.
# When run without arguments, detects all cnpg-playground Kind clusters
# and deploys pgAdmin4 for each. Pass region names to target specific clusters.
#
# Usage:
#   scripts/pgadmin-setup.sh [region ...]
#   PGADMIN_EMAIL=you@example.com scripts/pgadmin-setup.sh local
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

set -euo pipefail

source "$(git rev-parse --show-toplevel)/scripts/common.sh"

PGADMIN_DIR="${GIT_REPO_ROOT}/pgadmin"
CNPG_DEMO_NAMESPACE="${CNPG_DEMO_NAMESPACE:-demo-local-db}"
PGADMIN_EMAIL="${PGADMIN_EMAIL:-admin@pgadmin.local}"

detect_running_regions "$@"

port=5051

for region in "${REGIONS[@]}"; do
    echo "-------------------------------------------------------------"
    echo " 🔑 Deploying pgAdmin4 for region: ${region}"
    echo "-------------------------------------------------------------"

    CONTEXT_NAME=$(get_cluster_context "${region}")

    kubectl --context "${CONTEXT_NAME}" apply -f "${PGADMIN_DIR}/namespace.yaml"

    PGADMIN_PASSWORD="$(openssl rand -base64 32 | tr -d '/+=' | head -c 32)"
    PGADMIN_EMAIL="${PGADMIN_EMAIL}" PGADMIN_PASSWORD="${PGADMIN_PASSWORD}" \
        envsubst '${PGADMIN_EMAIL} ${PGADMIN_PASSWORD}' \
        < "${PGADMIN_DIR}/secret.yaml.tpl" \
        | kubectl --context "${CONTEXT_NAME}" apply -f -

    CNPG_DEMO_NAMESPACE="${CNPG_DEMO_NAMESPACE}" \
        envsubst '${CNPG_DEMO_NAMESPACE}' \
        < "${PGADMIN_DIR}/servers.json.tpl" \
        | kubectl --context "${CONTEXT_NAME}" apply -f -

    kubectl --context "${CONTEXT_NAME}" apply -f "${PGADMIN_DIR}/deployment.yaml"

    echo "⏳ Waiting for pgAdmin4 to be ready..."
    kubectl --context "${CONTEXT_NAME}" rollout status deployment/pgadmin -n pgadmin

    if TRAEFIK_LB_IP=$(get_traefik_lb_ip "${CONTEXT_NAME}" 30); then
        TRAEFIK_IP_DASHED=$(ip_to_dashed "${TRAEFIK_LB_IP}")
        TRAEFIK_IP_DASHED="${TRAEFIK_IP_DASHED}" \
            envsubst '${TRAEFIK_IP_DASHED}' \
            < "${PGADMIN_DIR}/ingressroute.yaml.tpl" \
            | kubectl --context "${CONTEXT_NAME}" apply -f -
        echo "-----------------------------------------------------------------------------------------------------------------"
        echo " 🔑 pgAdmin4 is available at:"
        echo " http://pgadmin.${TRAEFIK_IP_DASHED}.sslip.io"
        echo " Email:    ${PGADMIN_EMAIL}"
        echo " Password: ${PGADMIN_PASSWORD}"
        echo "-----------------------------------------------------------------------------------------------------------------"
    else
        echo "⚠️  Traefik not found in ${CONTEXT_NAME} — falling back to port-forward"
        echo "-----------------------------------------------------------------------------------------------------------------"
        echo " ⏩ To forward pgAdmin4 for region ${region} to your localhost:"
        echo ""
        echo " kubectl port-forward service/pgadmin ${port}:80 -n pgadmin --context ${CONTEXT_NAME}"
        echo ""
        echo " Then open: http://localhost:${port}"
        echo " Email:    ${PGADMIN_EMAIL}"
        echo " Password: ${PGADMIN_PASSWORD}"
        echo "-----------------------------------------------------------------------------------------------------------------"
    fi

    ((port++))
done
