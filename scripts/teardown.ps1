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

# Look for a supported container provider and use it throughout
$containerProviders = "docker", "podman"
$CONTAINER_PROVIDER = $null
foreach ($provider in $containerProviders) {
    if (Get-Command $provider -ErrorAction SilentlyContinue) {
        $CONTAINER_PROVIDER = $provider
        break
    }
}

# Ensure we found a supported container provider
if (-not $CONTAINER_PROVIDER) {
    Write-Output "Missing container provider, supported providers are $($containerProviders -join ', ')"
    exit 1
}

$gitRepoRoot = & git rev-parse --show-toplevel
Set-Location -Path $gitRepoRoot

& $CONTAINER_PROVIDER rm minio-eu -f
& $CONTAINER_PROVIDER rm minio-us -f
& kind delete cluster --name k8s-eu
& kind delete cluster --name k8s-us
Remove-Item -Recurse -Force minio-eu/*, minio-eu/.minio.sys
Remove-Item -Recurse -Force minio-us/*, minio-us/.minio.sys
Remove-Item -Force k8s/kube-config.yaml
