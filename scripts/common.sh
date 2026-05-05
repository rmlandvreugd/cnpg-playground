#!/usr/bin/env bash
#
# This script contains common variables and functions shared by the setup,
# info, and cleanup scripts for the CloudNativePG playground.
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

set -euo pipefail

# Minimal thresholds to check before calling tuning script
declare -A thresholds=(
  [fs.inotify.max_user_watches]=20000
  [fs.inotify.max_user_instances]=1000
  [kernel.keys.maxkeys]=1000
  [kernel.keys.maxbytes]=250000
)

needs_update=0

# Check current sysctl values
for key in "${!thresholds[@]}"; do
  path="/proc/sys/$(echo "$key" | tr '.' '/')"
  if [[ -f "$path" ]]; then
    current=$(cat "$path")
    if (( current < thresholds[$key] )); then
      echo "Current $key ($current) is below threshold (${thresholds[$key]})"
      needs_update=1
    fi
  else
    echo "Warning: sysctl key $key not found at $path"
  fi
done

# Run the tuning script if needed
if (( needs_update )); then
  echo "Running tuning script to update sysctl settings..."
  "${BASH_SOURCE%/*}/tune-sysctl.sh"
  ret=$?
  if (( ret != 0 )); then
    echo "$(basename "$0"): Tuning script exited without applying changes."
  fi
fi

# --- Common Configuration ---
# Kind base name for clusters
K8S_CONTEXT_PREFIX=${K8S_CONTEXT_PREFIX-kind-}
K8S_BASE_NAME=${K8S_NAME-k8s-}

# RustFS Configuration
RUSTFS_IMAGE="${RUSTFS_IMAGE:-rustfs/rustfs:latest}"
RUSTFS_BASE_NAME="${RUSTFS_BASE_NAME:-objectstore}"
RUSTFS_BASE_PORT=${RUSTFS_BASE_PORT:-9001}
RUSTFS_ROOT_USER="${RUSTFS_ROOT_USER:-cnpg}"
RUSTFS_ROOT_PASSWORD="${RUSTFS_ROOT_PASSWORD:-Cl0udNativePGRocks}"

# Vault Configuration
VAULT_IMAGE="${VAULT_IMAGE:-hashicorp/vault:2.0}"
VAULT_CONTAINER_NAME="${VAULT_CONTAINER_NAME:-vault}"
VAULT_PORT=${VAULT_PORT:-8200}

# Vault admin credentials
VAULT_ADMIN_USER="${VAULT_ADMIN_USER:-vault-admin}"
VAULT_ADMIN_PASSWORD="${VAULT_ADMIN_PASSWORD:-admin-password-123}"
VAULT_HTTP_PORT="${VAULT_HTTP_PORT:-8202}"

# Dex
DEX_IMAGE="${DEX_IMAGE:-ghcr.io/dexidp/dex:v2.45.1}"
DEX_CONTAINER_NAME="${DEX_CONTAINER_NAME:-dex}"
DEX_PORT="${DEX_PORT:-5556}"
DEX_OIDC_CLIENT_ID="${DEX_OIDC_CLIENT_ID:-vault-client}"
DEX_OIDC_CLIENT_SECRET="${DEX_OIDC_CLIENT_SECRET:-vault-oidc-secret}"
DEX_STATIC_PASSWORD_HASH="${DEX_STATIC_PASSWORD_HASH:-\$2a\$10\$2b2cU8CPhOTaGrs1HRQuAueS7JTT5ZHsHSzYiFPm1leZck7Mc8T4W}"
DEX_RBR_ADMIN_PASSWORD_HASH="${DEX_RBR_ADMIN_PASSWORD_HASH:-${DEX_STATIC_PASSWORD_HASH}}"
DEX_RBR_VER_ADMIN_PASSWORD_HASH="${DEX_RBR_VER_ADMIN_PASSWORD_HASH:-${DEX_STATIC_PASSWORD_HASH}}"
DEX_UNRELATED_PASSWORD_HASH="${DEX_UNRELATED_PASSWORD_HASH:-${DEX_STATIC_PASSWORD_HASH}}"
DEX_GRAFANA_RBR_VER_CLIENT_SECRET="${DEX_GRAFANA_RBR_VER_CLIENT_SECRET:-grafana-rbr-ver-demo-secret}"

# cert-manager
CERT_MANAGER_VERSION="${CERT_MANAGER_VERSION:-v1.20.2}"

# External Secrets Operator
ESO_VERSION="${ESO_VERSION:-v2.4.1}"
ESO_NAMESPACE="${ESO_NAMESPACE:-external-secrets}"

# CNPG ESO demo
CNPG_DEMO_NAMESPACE="${CNPG_DEMO_NAMESPACE:-demo-local-db}"

# MetalLB Configuration
METALLB_VERSION="${METALLB_VERSION:-v0.15.3}"
METALLB_CHART_VERSION="${METALLB_CHART_VERSION:-0.15.3}"
CERT_MANAGER_CHART_VERSION="${CERT_MANAGER_CHART_VERSION:-v1.20.2}"
ESO_CHART_VERSION="${ESO_CHART_VERSION:-2.4.1}"
TRAEFIK_CHART_VERSION="${TRAEFIK_CHART_VERSION:-39.0.8}"
CNPG_CHART_VERSION="${CNPG_CHART_VERSION:-0.28.0}"
BARMAN_CLOUD_PLUGIN_CHART_VERSION="${BARMAN_CLOUD_PLUGIN_CHART_VERSION:-0.6.0}"
GRAFANA_OPERATOR_CHART_VERSION="${GRAFANA_OPERATOR_CHART_VERSION:-5.22.2}"
KUBE_PROMETHEUS_STACK_CHART_VERSION="${KUBE_PROMETHEUS_STACK_CHART_VERSION:-83.6.0}"
LOKI_CHART_VERSION="${LOKI_CHART_VERSION:-13.5.0}"
ALLOY_CHART_VERSION="${ALLOY_CHART_VERSION:-1.8.0}"

# --- Common Prerequisite Checks ---
REQUIRED_COMMANDS="kind kubectl helm git grep sed envsubst jq"
for cmd in $REQUIRED_COMMANDS; do
    if ! command -v "$cmd" &> /dev/null; then
        echo "❌ Error: Missing required command: $cmd"
        exit 1
    fi
done

# --- Common Setup ---
# Find a supported container provider
CONTAINER_PROVIDER=""
for provider in docker podman; do
    if command -v "$provider" &> /dev/null; then
        CONTAINER_PROVIDER=$provider
        break
    fi
done

if [ -z "${CONTAINER_PROVIDER:-}" ]; then
    echo "❌ Error: Missing container provider. Supported providers are: docker, podman"
    exit 1
fi

# Determine project root and kubeconfig path
GIT_REPO_ROOT=$(git rev-parse --show-toplevel)
KUBE_CONFIG_PATH="${GIT_REPO_ROOT}/k8s/kube-config.yaml"

# source funcs_regions.sh
source $(git rev-parse --show-toplevel)/scripts/funcs_regions.sh

# --- Traefik Configuration ---
TRAEFIK_VERSION="${TRAEFIK_VERSION:-v3.3.0}"
TRAEFIK_IMAGE="${TRAEFIK_IMAGE:-traefik:v3.3}"

# Waits up to <timeout> seconds for the Traefik LoadBalancer IP to be assigned.
# Prints the IP on success; returns 1 on timeout.
get_traefik_lb_ip() {
    local context="$1"
    local max_wait="${2:-60}"
    local elapsed=0
    while [ "$elapsed" -lt "$max_wait" ]; do
        local ip
        ip=$(kubectl --context "$context" -n traefik get svc traefik \
            -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)
        if [ -n "$ip" ]; then
            echo "$ip"
            return 0
        fi
        sleep 2
        elapsed=$((elapsed + 2))
    done
    return 1
}

# Converts dotted IP to dashed notation for sslip.io hostnames.
# Example: 172.18.255.200 → 172-18-255-200
ip_to_dashed() {
    echo "$1" | tr '.' '-'
}

# Returns the first IPv4 subnet of a container network.
# Docker stores it under .IPAM.Config[].Subnet; Podman under .Subnets[].Subnet.
get_kind_ipv4_subnet() {
    local network="${1:-kind}"
    if [ "$CONTAINER_PROVIDER" = "podman" ]; then
        $CONTAINER_PROVIDER network inspect "$network" \
            -f '{{range .Subnets}}{{.Subnet}}{{"\n"}}{{end}}' | grep '\.' | head -n 1
    else
        $CONTAINER_PROVIDER network inspect "$network" \
            -f '{{range .IPAM.Config}}{{.Subnet}}{{"\n"}}{{end}}' | grep '\.' | head -n 1
    fi
}

helm_upgrade_install() {
    local release="$1"
    local chart_ref="$2"
    local namespace="$3"
    local context="$4"
    local version="$5"
    shift 5

    local repo_args=()
    if [[ "${1:-}" == "--repo-url" ]]; then
        if [[ "${chart_ref}" == */* ]]; then
            echo "chart_ref must be a short chart name when --repo-url is used: ${chart_ref}" >&2
            return 1
        fi
        repo_args=(--repo "$2")
        shift 2
    fi

    helm upgrade --install "${release}" "${chart_ref}" \
        "${repo_args[@]}" \
        --namespace "${namespace}" \
        --create-namespace \
        --kube-context "${context}" \
        --version "${version}" \
        --wait \
        --timeout 300s \
        "$@"
}

wait_deployment() {
    local context="$1"
    local namespace="$2"
    local deployment="$3"
    local timeout="${4:-120s}"
    kubectl --context "${context}" -n "${namespace}" \
        rollout status deployment "${deployment}" --timeout="${timeout}"
}

helm_uninstall_if_present() {
    local release="$1"
    local namespace="$2"
    local context="$3"
    if helm status "${release}" --namespace "${namespace}" --kube-context "${context}" &>/dev/null; then
        helm uninstall "${release}" --namespace "${namespace}" --kube-context "${context}"
    fi
}
