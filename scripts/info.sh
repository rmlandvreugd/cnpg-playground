#!/usr/bin/env bash
#
# This script automatically detects running CloudNativePG playground clusters
# and displays their status, including version, nodes, and pods.
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

# Source the common setup script
source "$(dirname "$0")/common.sh"

# Prints the ingress endpoints that ACTUALLY exist in the given cluster context by
# reading the live Traefik route objects, rather than hardcoding a list. This keeps
# info.sh self-maintaining: whatever setup.sh / monitoring/setup.sh / pgadmin-setup.sh /
# eso-vault.sh / self-service-setup.sh have published shows up, and nothing else (e.g.
# gangplank/capsule-proxy, which print success URLs but create no IngressRoute, are
# correctly omitted). The applied routes already carry the fully-rendered sslip.io host.
print_ingress_urls() {
    local context="$1"
    local http_rows tcp_rows

    # HTTP/S routes: scheme from entryPoint (websecure->https, web->http); host from the
    # first Host(`…`) match. Prefer a route with no PathPrefix (root UI); if every route
    # is path-scoped (e.g. the Traefik dashboard's /dashboard), use the first and keep
    # that path so the link actually lands somewhere useful.
    http_rows=$(kubectl --context "${context}" get ingressroute -A -o json 2>/dev/null | jq -r '
        .items[]
        | (.spec.entryPoints // []) as $eps
        | (if   ($eps | index("websecure")) then "https"
           elif ($eps | index("web"))       then "http"
           else "http" end) as $scheme
        | [ .spec.routes[]? | select((.match // "") | test("Host\\(`")) ] as $routes
        | select(($routes | length) > 0)
        | ( [ $routes[] | select((.match | test("PathPrefix")) | not) ] ) as $rootless
        | (if ($rootless | length) > 0 then $rootless[0] else $routes[0] end) as $r
        | ($r.match | capture("Host\\(`(?<h>[^`]+)`\\)").h) as $host
        | (if ($rootless | length) > 0 then ""
           else ($r.match | capture("PathPrefix\\(`(?<p>[^`]+)`\\)").p + "/") end) as $path
        | "\($host | split(".")[0])\t\($scheme)://\($host)\($path)"
    ' 2>/dev/null | sort -u)

    # Postgres TCP routes (entrypoint :5432, TLS passthrough): host from HostSNI(`…`).
    tcp_rows=$(kubectl --context "${context}" get ingressroutetcp -A -o json 2>/dev/null | jq -r '
        .items[]
        | .spec.routes[]?
        | select((.match // "") | test("HostSNI\\(`"))
        | (.match | capture("HostSNI\\(`(?<h>[^`]+)`\\)").h) as $host
        | select($host != "*")
        | "\($host | split(".")[0])\t\($host):5432 (psql, sslmode=require)"
    ' 2>/dev/null | sort -u)

    if [ -z "${http_rows}" ] && [ -z "${tcp_rows}" ]; then
        if get_traefik_lb_ip "${context}" 5 >/dev/null; then
            echo "  (no ingress routes published yet — run setup.sh / monitoring/setup.sh / demo scripts)"
        else
            echo "  ⚠️  Traefik not found — run setup.sh and monitoring/setup.sh first"
        fi
        return
    fi

    if [ -n "${http_rows}" ]; then
        printf '%s\n' "${http_rows}" | while IFS=$'\t' read -r label url; do
            printf "  %-22s %s\n" "${label}" "${url}"
        done
    fi
    if [ -n "${tcp_rows}" ]; then
        printf '%s\n' "${tcp_rows}" | while IFS=$'\t' read -r label url; do
            printf "  %-22s %s\n" "${label}" "${url}"
        done
    fi
    return 0
}

# --- Script Setup ---
if [ ! -f "${KUBE_CONFIG_PATH}" ]; then
    echo "❌ Error: Kubeconfig file not found at '${KUBE_CONFIG_PATH}'"
    echo "Please run the setup.sh script first."
    exit 1
fi
export KUBECONFIG="${KUBE_CONFIG_PATH}"

# --- Auto-detect Regions ---
detect_running_regions

# --- Access Instructions ---
echo
echo "--------------------------------------------------"
echo "🕹️  Cluster Access Instructions"
echo "--------------------------------------------------"
echo
echo "To access your playground clusters, first set the KUBECONFIG environment variable:"
echo "export KUBECONFIG=${KUBE_CONFIG_PATH}"
echo
echo "Available cluster contexts:"
for region in "${REGIONS[@]}"; do
    CONTEXT_NAME=$(get_cluster_context "${region}")
    echo "  • ${CONTEXT_NAME}"
done
echo
echo "To switch to a specific cluster (e.g., the '${REGIONS[0]}' region), use:"
echo "kubectl config use-context $(get_cluster_context ${REGIONS[0]})"
echo

# --- Main Info Loop ---
echo "--------------------------------------------------"
echo "ℹ️  Cluster Information"
echo "--------------------------------------------------"
for region in "${REGIONS[@]}"; do
    CLUSTER_NAME=$(get_cluster_name "${region}")
    CONTEXT_NAME=$(get_cluster_context "${region}")
    echo
    echo "🔷 Cluster: ${CLUSTER_NAME}"
    echo "==================================="
    echo "🔹 Version:"
    kubectl --context "${CONTEXT_NAME}" version
    echo
    echo "🔹 Nodes:"
    kubectl --context "${CONTEXT_NAME}" get nodes -o wide
    echo
    echo "🔹 Secrets:"
    kubectl --context "${CONTEXT_NAME}" get secrets
    echo
    echo "🔹 Ingress URLs:"
    print_ingress_urls "${CONTEXT_NAME}"
done
