#!/usr/bin/env bash
#
# This script deploys CloudNativePG in two regions and sets up a PostgreSQL
# example cluster using a distributed topology. The configuration leverages
# state synchronization with S3 object storage.
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

set -eu

info_icon="ℹ️"
success_icon="✅"
warning_icon="⚠️"
error_icon="❌"

git_repo_root=$(git rev-parse --show-toplevel)

# Source the common setup script
source ${git_repo_root}/scripts/common.sh

kube_config_path=${git_repo_root}/k8s/kube-config.yaml
demo_yaml_path=${git_repo_root}/demo/yaml

check_crd_existence() {
    # Check if the CRD exists in the cluster
    kubectl get crd "$1" &> /dev/null
    return $?
}

legacy=
if [ "${LEGACY:-}" = "true" ]; then
   legacy="-legacy"
fi

trunk=0
if [ "${TRUNK:-}" = "true" ]; then
   trunk=1
fi

# Ensure prerequisites are met
prereqs="kubectl kubectl-cnpg cmctl"
for cmd in $prereqs; do
   if [ -z "$(which $cmd)" ]; then
      echo "${error_icon} Missing command $cmd"
      exit 1
   fi
done

# Setup a separate Kubeconfig
cd "${git_repo_root}"
export KUBECONFIG=${kube_config_path}

# Determine regions from arguments, or use defaults
set_regions "$@"

# Begin deployment, one region at a time
for region in "${REGIONS[@]}"; do

   CONTEXT_NAME=$(get_cluster_context "${region}")
   
   echo "${info_icon} Deploying in region ${region} with context ${CONTEXT_NAME}"
   if [ $trunk -eq 1 ]
   then
     # Deploy CloudNativePG operator (trunk - main branch)
     echo "${info_icon} Deploying CloudNativePG operator (trunk version)"
     curl -sSfL \
       https://raw.githubusercontent.com/cloudnative-pg/artifacts/main/manifests/operator-manifest.yaml | \
       kubectl --context ${CONTEXT_NAME} apply -f - --server-side
   else
     # Deploy CloudNativePG operator (latest version, through the plugin)
      echo "${info_icon} Deploying CloudNativePG operator (latest stable version)"
     kubectl cnpg install generate --control-plane | \
       kubectl --context ${CONTEXT_NAME} apply -f - --server-side
   fi

   # Wait for CNPG deployment to complete
   echo "${info_icon} Waiting for CloudNativePG operator to be ready..."
   kubectl --context ${CONTEXT_NAME} rollout status deployment \
      -n cnpg-system cnpg-controller-manager

   # Deploy cert-manager
   echo "${info_icon} Deploying cert-manager..."
   kubectl apply --context ${CONTEXT_NAME} -f \
      https://github.com/cert-manager/cert-manager/releases/latest/download/cert-manager.yaml

   # Wait for cert-manager deployment to complete
   echo "${info_icon} Waiting for cert-manager to be ready..."
   kubectl rollout --context ${CONTEXT_NAME} status deployment \
      -n cert-manager
   cmctl check api --wait=2m --context ${CONTEXT_NAME}

   if [ $trunk -eq 1 ]
   then
     # Deploy Barman Cloud Plugin (trunk)
     echo "${info_icon} Deploying Barman Cloud Plugin (trunk version)"
     kubectl apply --context ${CONTEXT_NAME} -f \
       https://raw.githubusercontent.com/cloudnative-pg/plugin-barman-cloud/refs/heads/main/manifest.yaml
   else
     # Deploy Barman Cloud Plugin (latest stable)
     echo "${info_icon} Deploying Barman Cloud Plugin (latest stable version)"
     kubectl apply --context ${CONTEXT_NAME} -f \
        https://github.com/cloudnative-pg/plugin-barman-cloud/releases/latest/download/manifest.yaml
   fi

   # Wait for Barman Cloud Plugin deployment to complete
   echo "${info_icon} Waiting for Barman Cloud Plugin to be ready..."
   kubectl rollout --context ${CONTEXT_NAME} status deployment \
      -n cnpg-system barman-cloud

   # Create Barman object stores
   echo "${info_icon} Creating Barman Cloud object store for region ${region}..."
   kubectl apply --context ${CONTEXT_NAME} -f \
     ${demo_yaml_path}/object-stores/objectstore-${region}.yaml

   # Create the Postgres cluster
   echo "${info_icon} Creating PostgreSQL cluster in region ${region}..."
   kubectl apply --context ${CONTEXT_NAME} -f \
     ${demo_yaml_path}/${region}/pg-${region}${legacy}.yaml

   # Create the PodMonitor if Prometheus has been installed
   if check_crd_existence podmonitors.monitoring.coreos.com
   then
      echo "${info_icon} Creating PodMonitor for PostgreSQL cluster in region ${region}..."
     kubectl apply --context ${CONTEXT_NAME} -f \
       ${demo_yaml_path}/${region}/pg-${region}-podmonitor.yaml
   fi

   # Wait for the cluster to be ready
   echo "${info_icon} Waiting for PostgreSQL cluster in region ${region} to be ready..."
   kubectl wait --context ${CONTEXT_NAME} \
     --timeout 30m \
     --for=condition=Ready cluster/pg-${region}

done

echo "All regions have been deployed successfully!"