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

set -Eeuo pipefail

# Centralized failure diagnostics: with `set -E` this ERR trap propagates into
# functions/subshells and fires for every script that sources common.sh, turning
# a silent `set -e` abort into a clear "<file> line <N>: <command>" message.
# Commands guarded with `|| true` (common in teardown scripts) do NOT trigger it.
_common_on_err() {
    local rc=$?
    echo "❌ ${BASH_SOURCE[1]:-script} failed (exit ${rc}) at line ${BASH_LINENO[0]}: ${BASH_COMMAND}" >&2
}
trap _common_on_err ERR

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

# SeaweedFS Configuration (Loki-only object store, weed server -filer -s3)
SEAWEEDFS_IMAGE="${SEAWEEDFS_IMAGE:-chrislusf/seaweedfs:latest}"
SEAWEEDFS_CONTAINER_NAME="${SEAWEEDFS_CONTAINER_NAME:-seaweedfs}"
SEAWEEDFS_S3_PORT="${SEAWEEDFS_S3_PORT:-8333}"                   # S3 HTTPS
SEAWEEDFS_S3_HTTP_PORT="${SEAWEEDFS_S3_HTTP_PORT:-8334}"         # S3 HTTP (8333+1, avoids conflict with HTTPS)
SEAWEEDFS_MASTER_PORT="${SEAWEEDFS_MASTER_PORT:-9333}"           # Master UI + API
SEAWEEDFS_VOLUME_PORT="${SEAWEEDFS_VOLUME_PORT:-9340}"           # Volume server (explicit; weed server default is 8080)
SEAWEEDFS_FILER_PORT="${SEAWEEDFS_FILER_PORT:-8889}"             # Filer UI + API (8889 avoids common 8888 conflicts)
SEAWEEDFS_ADMIN_PORT="${SEAWEEDFS_ADMIN_PORT:-23646}"            # Admin UI HTTPS (via security.toml [https.admin])
SEAWEEDFS_ADMIN_CONTAINER_NAME="${SEAWEEDFS_ADMIN_CONTAINER_NAME:-seaweedfs-admin}"
SEAWEEDFS_WEBDAV_PORT="${SEAWEEDFS_WEBDAV_PORT:-7333}"              # WebDAV HTTPS (-cert.file/-key.file on same port)
SEAWEEDFS_WEBDAV_CONTAINER_NAME="${SEAWEEDFS_WEBDAV_CONTAINER_NAME:-seaweedfs-webdav}"
SEAWEEDFS_WORKER_METRICS_PORT="${SEAWEEDFS_WORKER_METRICS_PORT:-9327}"  # Worker Prometheus metrics
SEAWEEDFS_WORKER_CONTAINER_NAME="${SEAWEEDFS_WORKER_CONTAINER_NAME:-seaweedfs-worker}"
SEAWEEDFS_ACCESS_KEY="${SEAWEEDFS_ACCESS_KEY:-loki}"
SEAWEEDFS_SECRET_KEY="${SEAWEEDFS_SECRET_KEY:-lokiS3secret}"

# Revocation Exporter Configuration (host container, --network host)
REVOCATION_EXPORTER_CONTAINER_NAME="${REVOCATION_EXPORTER_CONTAINER_NAME:-revocation-exporter}"
REVOCATION_EXPORTER_PORT="${REVOCATION_EXPORTER_PORT:-9105}"
REVOCATION_EXPORTER_IMAGE="${REVOCATION_EXPORTER_IMAGE:-revocation-exporter:latest}"

# Vault Configuration
VAULT_IMAGE="${VAULT_IMAGE:-hashicorp/vault:2.0}"
VAULT_CONTAINER_NAME="${VAULT_CONTAINER_NAME:-vault}"
VAULT_PORT=${VAULT_PORT:-8200}

# Vault admin credentials
VAULT_ADMIN_USER="${VAULT_ADMIN_USER:-vault-admin}"
VAULT_ADMIN_PASSWORD="${VAULT_ADMIN_PASSWORD:-admin-password-123}"
VAULT_HTTP_PORT="${VAULT_HTTP_PORT:-8202}"

# step-ca Configuration
STEP_CA_IMAGE="${STEP_CA_IMAGE:-smallstep/step-ca:latest}"
STEP_CA_CONTAINER_NAME="${STEP_CA_CONTAINER_NAME:-step-ca}"
STEP_CA_PORT="${STEP_CA_PORT:-8443}"
STEP_CA_CA_NAME="${STEP_CA_CA_NAME:-CloudNativePG Playground CA}"
STEP_CA_DNS_NAME="${STEP_CA_DNS_NAME:-step-ca}"
STEP_CA_PROVISIONER_NAME="${STEP_CA_PROVISIONER_NAME:-admin}"

# trust-manager Configuration
TRUST_MANAGER_CHART_VERSION="${TRUST_MANAGER_CHART_VERSION:-0.17.1}"

# Authelia
AUTHELIA_IMAGE="${AUTHELIA_IMAGE:-ghcr.io/authelia/authelia:4.39.20}"
AUTHELIA_CONTAINER_NAME="${AUTHELIA_CONTAINER_NAME:-authelia}"
AUTHELIA_PORT="${AUTHELIA_PORT:-9091}"
# User password hashes (bcrypt — same values as before, Authelia file provider accepts bcrypt)
AUTHELIA_STATIC_PASSWORD_HASH="${AUTHELIA_STATIC_PASSWORD_HASH:-\$2a\$10\$2b2cU8CPhOTaGrs1HRQuAueS7JTT5ZHsHSzYiFPm1leZck7Mc8T4W}"
AUTHELIA_RBR_ADMIN_PASSWORD_HASH="${AUTHELIA_RBR_ADMIN_PASSWORD_HASH:-${AUTHELIA_STATIC_PASSWORD_HASH}}"
AUTHELIA_RBR_VER_ADMIN_PASSWORD_HASH="${AUTHELIA_RBR_VER_ADMIN_PASSWORD_HASH:-${AUTHELIA_STATIC_PASSWORD_HASH}}"
AUTHELIA_UNRELATED_PASSWORD_HASH="${AUTHELIA_UNRELATED_PASSWORD_HASH:-${AUTHELIA_STATIC_PASSWORD_HASH}}"
AUTHELIA_RBR_VER_DEV_PASSWORD_HASH="${AUTHELIA_RBR_VER_DEV_PASSWORD_HASH:-${AUTHELIA_STATIC_PASSWORD_HASH}}"
AUTHELIA_RBR_PO_PASSWORD_HASH="${AUTHELIA_RBR_PO_PASSWORD_HASH:-${AUTHELIA_STATIC_PASSWORD_HASH}}"
# OIDC client secrets (plaintext — hashed to PBKDF2 at setup time by authelia-setup.sh)
AUTHELIA_VAULT_CLIENT_SECRET="${AUTHELIA_VAULT_CLIENT_SECRET:-vault-oidc-secret}"
AUTHELIA_STEP_CA_CLIENT_SECRET="${AUTHELIA_STEP_CA_CLIENT_SECRET:-step-ca-demo-secret}"
AUTHELIA_GRAFANA_RBR_VER_CLIENT_SECRET="${AUTHELIA_GRAFANA_RBR_VER_CLIENT_SECRET:-grafana-rbr-ver-demo-secret}"
AUTHELIA_GRAFANA_MONITORING_CLIENT_SECRET="${AUTHELIA_GRAFANA_MONITORING_CLIENT_SECRET:-grafana-monitoring-demo-secret}"
AUTHELIA_GANGPLANK_CLIENT_SECRET="${AUTHELIA_GANGPLANK_CLIENT_SECRET:-gangplank-demo-secret}"
AUTHELIA_ARGOCD_CLIENT_SECRET="${AUTHELIA_ARGOCD_CLIENT_SECRET:-argocd-demo-secret}"
AUTHELIA_SEAWEEDFS_ADMIN_CLIENT_SECRET="${AUTHELIA_SEAWEEDFS_ADMIN_CLIENT_SECRET:-seaweedfs-admin-demo-secret}"
AUTHELIA_SEAWEEDFS_S3_CLIENT_SECRET="${AUTHELIA_SEAWEEDFS_S3_CLIENT_SECRET:-seaweedfs-s3-demo-secret}"
# Authelia internal secrets (session, storage, OIDC HMAC, JWT)
AUTHELIA_SESSION_SECRET="${AUTHELIA_SESSION_SECRET:-authelia-session-secret-dev}"
AUTHELIA_STORAGE_ENCRYPTION_KEY="${AUTHELIA_STORAGE_ENCRYPTION_KEY:-authelia-storage-key-dev-32chars!}"
AUTHELIA_OIDC_HMAC_SECRET="${AUTHELIA_OIDC_HMAC_SECRET:-authelia-oidc-hmac-secret-dev}"
AUTHELIA_JWT_SECRET="${AUTHELIA_JWT_SECRET:-authelia-jwt-secret-dev}"

# cert-manager
CERT_MANAGER_VERSION="${CERT_MANAGER_VERSION:-v1.20.2}"

# External Secrets Operator
ESO_VERSION="${ESO_VERSION:-v2.4.1}"
ESO_NAMESPACE="${ESO_NAMESPACE:-external-secrets}"

# CNPG ESO demo
CNPG_DEMO_NAMESPACE="${CNPG_DEMO_NAMESPACE:-demo-local-db}"

# MetalLB Configuration
METALLB_VERSION="${METALLB_VERSION:-v0.16.1}"
METALLB_CHART_VERSION="${METALLB_CHART_VERSION:-0.16.1}"
CERT_MANAGER_CHART_VERSION="${CERT_MANAGER_CHART_VERSION:-v1.20.2}"
TRUST_MANAGER_CHART_VERSION="${TRUST_MANAGER_CHART_VERSION:-v0.12.2}"
METRICS_SERVER_CHART_VERSION="${METRICS_SERVER_CHART_VERSION:-3.13.1}"
KUBELET_CSR_APPROVER_CHART_VERSION="${KUBELET_CSR_APPROVER_CHART_VERSION:-1.2.14}"

# Capsule + capsule-proxy + gangplank
CAPSULE_CHART_VERSION="${CAPSULE_CHART_VERSION:-0.13.6}"
CAPSULE_PROXY_CHART_VERSION="${CAPSULE_PROXY_CHART_VERSION:-0.13.5}"
GANGPLANK_CHART_VERSION="${GANGPLANK_CHART_VERSION:-0.2.1}"
# Kyverno
KYVERNO_CHART_VERSION="${KYVERNO_CHART_VERSION:-3.4.2}"
# Argo Ecosystem
ARGOCD_CHART_VERSION="${ARGOCD_CHART_VERSION:-9.7.0}"
ARGO_WORKFLOWS_CHART_VERSION="${ARGO_WORKFLOWS_CHART_VERSION:-1.0.17}"
ARGO_EVENTS_CHART_VERSION="${ARGO_EVENTS_CHART_VERSION:-2.4.22}"
ARGO_ROLLOUTS_CHART_VERSION="${ARGO_ROLLOUTS_CHART_VERSION:-2.41.0}"

ESO_CHART_VERSION="${ESO_CHART_VERSION:-2.4.1}"
TRAEFIK_CHART_VERSION="${TRAEFIK_CHART_VERSION:-39.0.8}"
CNPG_CHART_VERSION="${CNPG_CHART_VERSION:-0.28.0}"
BARMAN_CLOUD_PLUGIN_CHART_VERSION="${BARMAN_CLOUD_PLUGIN_CHART_VERSION:-0.6.0}"
GRAFANA_OPERATOR_CHART_VERSION="${GRAFANA_OPERATOR_CHART_VERSION:-5.22.2}"
KUBE_PROMETHEUS_STACK_CHART_VERSION="${KUBE_PROMETHEUS_STACK_CHART_VERSION:-86.2.3}"
LOKI_CHART_VERSION="${LOKI_CHART_VERSION:-13.5.0}"
ALLOY_CHART_VERSION="${ALLOY_CHART_VERSION:-1.8.0}"
MIMIR_CHART_VERSION="${MIMIR_CHART_VERSION:-6.0.6}"
TEMPO_CHART_VERSION="${TEMPO_CHART_VERSION:-2.25.2}"
OTEL_COLLECTOR_CHART_VERSION="${OTEL_COLLECTOR_CHART_VERSION:-0.158.2}"  # OCI: ghcr.io/open-telemetry/opentelemetry-helm-charts
OTEL_COLLECTOR_IMAGE_TAG="${OTEL_COLLECTOR_IMAGE_TAG:-0.153.0}"          # otel/opentelemetry-collector-contrib; chart 0.153.0 appVersion is 0.151.0
TIGERA_OPERATOR_CHART_VERSION="${TIGERA_OPERATOR_CHART_VERSION:-v3.32.0}"
CARETTA_CHART_VERSION="${CARETTA_CHART_VERSION:-0.0.16}"
RADAR_CHART_VERSION="${RADAR_CHART_VERSION:-1.7.9}"
GRAFANA_IMAGE="${GRAFANA_IMAGE:-docker.io/grafana/grafana:12.4.1}"

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

# --- Mutual-exclusion lock ---
# Prevents concurrent setup.sh / teardown.sh runs from corrupting the shared
# kubeconfig (k8s/kube-config.yaml). Call acquire_lock once per top-level script
# immediately after sourcing common.sh.
# Globals so the EXIT/INT/TERM trap handler can resolve paths after acquire_lock
# returns (its locals would be out of scope, tripping `set -u`).
_PLAYGROUND_LOCKFILE="${GIT_REPO_ROOT}/.playground.lock"
_PLAYGROUND_PIDFILE="${_PLAYGROUND_LOCKFILE}.pid"

_release_playground_lock() {
    flock -u 9 2>/dev/null || true
    rm -f "${_PLAYGROUND_PIDFILE}"
}

acquire_lock() {
    if command -v flock &>/dev/null; then
        # flock(1) available (Linux / WSL) — atomically grab an exclusive lock on fd 9.
        exec 9>"${_PLAYGROUND_LOCKFILE}"
        if ! flock -n 9; then
            local holder
            holder=$(cat "${_PLAYGROUND_PIDFILE}" 2>/dev/null || echo "unknown")
            echo "❌ Another playground script is already running (PID ${holder}). Aborting." >&2
            exit 1
        fi
    else
        # macOS fallback: PID file with staleness check (small TOCTOU window; acceptable for dev tooling).
        if [[ -f "${_PLAYGROUND_PIDFILE}" ]]; then
            local holder
            holder=$(cat "${_PLAYGROUND_PIDFILE}")
            if kill -0 "${holder}" 2>/dev/null; then
                echo "❌ Another playground script is already running (PID ${holder}). Aborting." >&2
                exit 1
            fi
            echo "⚠️  Stale lock from PID ${holder} (process gone). Reclaiming." >&2
        fi
    fi

    echo $$ > "${_PLAYGROUND_PIDFILE}"

    # EXIT fires on normal exit and signal death when INT/TERM are also trapped.
    trap '_release_playground_lock' EXIT
    trap '_release_playground_lock; trap - INT;  kill -INT  $$' INT
    trap '_release_playground_lock; trap - TERM; kill -TERM $$' TERM
}

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

# retry <tries> <delay_seconds> <command...>
# Re-runs the command until it succeeds or <tries> is reached. Intended for
# operations that race with a not-yet-reachable admission webhook (e.g. applying
# a resource right after its controller's Deployment goes Available, before
# kube-proxy has programmed the webhook Service endpoint -> "connection refused").
retry() {
    local tries="$1" delay="$2"; shift 2
    local n=1
    until "$@"; do
        if (( n >= tries )); then
            echo "❌ command failed after ${tries} attempts: $*" >&2
            return 1
        fi
        echo "⚠️  attempt ${n}/${tries} failed, retrying in ${delay}s: $*" >&2
        sleep "${delay}"
        n=$((n + 1))
    done
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

    # `--no-wait` opt-out: some charts (e.g. cert-manager) make `helm --wait`
    # stall indefinitely even when every resource is already Ready. Callers that
    # do their own explicit `kubectl wait` afterwards can pass --no-wait to skip it.
    local wait_args=(--wait)
    local debug_args=()
    local passthrough=() arg
    for arg in "$@"; do
        if [[ "${arg}" == "--no-wait" ]]; then
            wait_args=()
        elif [[ "${arg}" == "--debug" ]]; then
            debug_args=(--debug)
        else
            passthrough+=("${arg}")
        fi
    done
    set -- ${passthrough[@]+"${passthrough[@]}"}

    local attempt retries=3 delay=15
    for attempt in $(seq 1 $retries); do
        # Clear a release stuck in a pending/failed state so retries and re-runs
        # self-heal instead of failing with "another operation in progress".
        local st
        st=$(helm status "${release}" -n "${namespace}" --kube-context "${context}" \
             -o json 2>/dev/null | grep -o '"status":"[^"]*"' | head -1 | cut -d'"' -f4 || true)
        case "${st}" in
            pending-install)
                helm uninstall "${release}" -n "${namespace}" --kube-context "${context}" --wait || true ;;
            pending-upgrade|pending-rollback|failed)
                # Roll back to the last good revision; if there is none (e.g. the very
                # first install failed -> "release has no 0 version"), uninstall so the
                # next attempt is a clean install.
                helm rollback "${release}" -n "${namespace}" --kube-context "${context}" 2>/dev/null \
                    || helm uninstall "${release}" -n "${namespace}" --kube-context "${context}" --wait \
                    || true ;;
        esac

        # Wrap in `timeout` so a stuck `helm --wait` (which can blow past its own
        # --timeout) becomes a failure the retry loop can act on, not a frozen process.
        timeout --kill-after=30s 1000s helm upgrade --install "${release}" "${chart_ref}" \
            "${repo_args[@]}" \
            --namespace "${namespace}" \
            --create-namespace \
            --kube-context "${context}" \
            --version "${version}" \
            ${wait_args[@]+"${wait_args[@]}"} \
            ${debug_args[@]+"${debug_args[@]}"} \
            --timeout 900s \
            "$@" && return 0
        if [[ $attempt -lt $retries ]]; then
            echo "⚠️  helm install attempt $attempt/$retries failed, retrying in ${delay}s..." >&2
            sleep $delay
        fi
    done
    echo "❌ helm install failed after $retries attempts: ${release}" >&2
    return 1
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

install_cnpg_operator() {
    local context_name="$1"
    if [ "${TRUNK:-}" = "true" ]; then
        echo "🔧 Deploying CloudNativePG operator (trunk version)"
        curl -sSfL \
          https://raw.githubusercontent.com/cloudnative-pg/artifacts/main/manifests/operator-manifest.yaml | \
          kubectl --context "${context_name}" apply -f - --server-side
        echo "⏳ Waiting for CloudNativePG operator to be ready..."
        kubectl --context "${context_name}" rollout status deployment \
          -n cnpg-system cnpg-controller-manager
    else
        echo "🔧 Deploying CloudNativePG operator (chart ${CNPG_CHART_VERSION})"
        helm_upgrade_install cnpg-operator cloudnative-pg cnpg-system "${context_name}" \
          "${CNPG_CHART_VERSION}" \
          --repo-url https://cloudnative-pg.github.io/charts
    fi
}

install_barman_plugin() {
    local context_name="$1"
    if [ "${TRUNK:-}" = "true" ]; then
        echo "🔧 Deploying Barman Cloud Plugin (trunk version)"
        kubectl apply --context "${context_name}" -f \
          https://raw.githubusercontent.com/cloudnative-pg/plugin-barman-cloud/refs/heads/main/manifest.yaml
        echo "⏳ Waiting for Barman Cloud Plugin to be ready..."
        kubectl rollout --context "${context_name}" status deployment \
          -n cnpg-system barman-cloud
    else
        echo "🔧 Deploying Barman Cloud Plugin (chart ${BARMAN_CLOUD_PLUGIN_CHART_VERSION})"
        echo "📜 Issuing barman-cloud TLS certificates via vault-pki..."
        kubectl apply --context "${context_name}" -f \
          "${GIT_REPO_ROOT}/demo/yaml/barman-cloud/certificate-server.yaml"
        kubectl apply --context "${context_name}" -f \
          "${GIT_REPO_ROOT}/demo/yaml/barman-cloud/certificate-client.yaml"
        kubectl wait --context "${context_name}" --timeout=60s \
          --for=condition=Ready certificate/barman-cloud-server -n cnpg-system
        kubectl wait --context "${context_name}" --timeout=60s \
          --for=condition=Ready certificate/barman-cloud-client -n cnpg-system
        helm_upgrade_install barman-cloud plugin-barman-cloud cnpg-system "${context_name}" \
          "${BARMAN_CLOUD_PLUGIN_CHART_VERSION}" \
          --repo-url https://cloudnative-pg.github.io/charts \
          --set certificate.createClientCertificate=false \
          --set certificate.createServerCertificate=false
    fi
}
