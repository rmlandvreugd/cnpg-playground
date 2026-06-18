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

legacy=
if [ "${LEGACY:-}" = "true" ]; then
   legacy="-legacy"
fi

# Ensure prerequisites are met
prereqs="kubectl kubectl-cnpg"
for cmd in $prereqs; do
   if [ -z "$(which $cmd)" ]; then
      echo "${error_icon} Missing command $cmd"
      exit 1
   fi
done

# Setup a separate Kubeconfig
cd "${git_repo_root}"
export KUBECONFIG=${kube_config_path}

# Determine regions from arguments, or auto-detect running clusters
detect_running_regions "$@"

# Begin deployment, one region at a time
for region in "${REGIONS[@]}"; do

   CONTEXT_NAME=$(get_cluster_context "${region}")
   
   echo "${info_icon} Deploying in region ${region} with context ${CONTEXT_NAME}"

   # Create Barman object stores
   echo "${info_icon} Creating Barman Cloud object store for region ${region}..."
   kubectl apply --context ${CONTEXT_NAME} -f \
     ${demo_yaml_path}/object-stores/objectstore-${region}.yaml

   # Apply custom metrics ConfigMap if present for this region (must precede cluster)
   if [ -f "${demo_yaml_path}/${region}/cnpg-custom-metrics-configmap.yaml" ]; then
     echo "${info_icon} Applying custom metrics ConfigMap for region ${region}..."
     kubectl apply --context ${CONTEXT_NAME} -f \
       ${demo_yaml_path}/${region}/cnpg-custom-metrics-configmap.yaml
   fi

   # Create the Postgres cluster
   echo "${info_icon} Creating PostgreSQL cluster in region ${region}..."
   kubectl apply --context ${CONTEXT_NAME} -f \
     ${demo_yaml_path}/${region}/pg-${region}${legacy}.yaml

   # Wait for the cluster to be ready
   echo "${info_icon} Waiting for PostgreSQL cluster in region ${region} to be ready..."
   kubectl wait --context ${CONTEXT_NAME} \
     --timeout 30m \
     --for=condition=Ready cluster/pg-${region}

done

echo "All regions have been deployed successfully!"