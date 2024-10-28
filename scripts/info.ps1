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

$gitRepoRoot = & git rev-parse --show-toplevel
$kubeConfigPath = "$gitRepoRoot/k8s/kube-config.yaml"

Write-Output @"
To access the playground clusters, ensure you set the following environment
variable:

`$env:KUBECONFIG = "$kubeConfigPath"

To switch between clusters, use the commands below:

kubectl config use-context kind-k8s-eu
kubectl config use-context kind-k8s-us

To check which cluster you’re currently connected to:

kubectl config current-context
"@
