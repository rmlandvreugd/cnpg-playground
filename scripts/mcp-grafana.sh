#!/usr/bin/env bash
# Launcher for the Grafana MCP server (stdio). Resolves the platform Grafana URL and the
# grafana-mcp service-account token from the running cluster at every start, so the MCP
# config never goes stale across rebuilds (new MetalLB IP, new token).
# stdout is the MCP protocol stream: diagnostics go to stderr only.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export KUBECONFIG="${MCP_GRAFANA_KUBECONFIG:-${REPO_ROOT}/k8s/kube-config.yaml}"

fail() { echo "mcp-grafana.sh: $*" >&2; exit 1; }

match=$(kubectl -n grafana get ingressroute grafana -o jsonpath='{.spec.routes[0].match}' 2>/dev/null) \
    || fail "cannot read IngressRoute grafana/grafana (cluster down? KUBECONFIG=${KUBECONFIG})"
host=$(sed -E 's/.*Host\(`([^`]+)`\).*/\1/' <<<"${match}")
[[ -n "${host}" && "${host}" != "${match}" ]] || fail "no Host() in IngressRoute match: ${match}"

token=$(kubectl -n grafana get secret grafana-mcp-token -o jsonpath='{.data.token}' 2>/dev/null | base64 -d) \
    || fail "cannot read Secret grafana/grafana-mcp-token (GrafanaServiceAccount grafana-mcp not synced yet?)"
[[ -n "${token}" ]] || fail "Secret grafana/grafana-mcp-token has no token"

unset GRAFANA_USERNAME GRAFANA_PASSWORD GRAFANA_API_KEY
export GRAFANA_URL="https://${host}"
export GRAFANA_SERVICE_ACCOUNT_TOKEN="${token}"

# --tls-skip-verify: the cluster CA is regenerated on every rebuild.
exec uvx mcp-grafana --tls-skip-verify "$@"
