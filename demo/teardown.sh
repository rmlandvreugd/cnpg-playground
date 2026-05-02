#!/usr/bin/env bash
#
# This script tears down the demo example for CloudNativePG.
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

set -ux

git_repo_root=$(git rev-parse --show-toplevel)

# Source the common setup script
source ${git_repo_root}/scripts/common.sh

trunk=0
if [ "${TRUNK:-}" = "true" ]; then
   trunk=1
fi

kube_config_path=${git_repo_root}/k8s/kube-config.yaml
demo_yaml_path=${git_repo_root}/demo/yaml

# Setup a separate Kubeconfig
cd "${git_repo_root}"
export KUBECONFIG=${kube_config_path}

# Determine regions from arguments, or auto-detect running clusters
detect_running_regions "$@"

# Delete deployment, one region at a time
for region in "${REGIONS[@]}"; do

   CONTEXT_NAME=$(get_cluster_context "${region}")

   # Delete the Postgres cluster
   kubectl delete --context ${CONTEXT_NAME} --ignore-not-found=true -f \
     ${demo_yaml_path}/${region}

   # Delete Barman object stores
   kubectl delete --context ${CONTEXT_NAME} --ignore-not-found=true -f \
     ${demo_yaml_path}/object-stores

   if [ $trunk -eq 1 ]; then
     kubectl delete --context "${CONTEXT_NAME}" --ignore-not-found=true -f \
       https://raw.githubusercontent.com/cloudnative-pg/plugin-barman-cloud/refs/heads/main/manifest.yaml
     kubectl delete --context "${CONTEXT_NAME}" --ignore-not-found=true -f \
       https://raw.githubusercontent.com/cloudnative-pg/artifacts/main/manifests/operator-manifest.yaml
   else
     helm_uninstall_if_present barman-cloud cnpg-system "${CONTEXT_NAME}"
     helm_uninstall_if_present cnpg-operator cnpg-system "${CONTEXT_NAME}"
   fi

   # Remove backup data
   ${CONTAINER_PROVIDER} exec objectstore-${region} rm -rf /data/backups/pg-${region}

done
