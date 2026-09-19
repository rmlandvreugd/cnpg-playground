#!/usr/bin/env bash
# Print the emergency (break-glass) admin login for the platform Grafana. Day-to-day
# access is Authelia SSO; automation uses the grafana-mcp service-account token.
# Tenant Grafana: demo/self-service-setup.sh breakglass local
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export KUBECONFIG="${KUBECONFIG:-${REPO_ROOT}/k8s/kube-config.yaml}"
SECRET=grafana-admin-credentials

user=$(kubectl -n grafana get secret "${SECRET}" -o jsonpath='{.data.GF_SECURITY_ADMIN_USER}' | base64 -d)
pass=$(kubectl -n grafana get secret "${SECRET}" -o jsonpath='{.data.GF_SECURITY_ADMIN_PASSWORD}' | base64 -d)
host=$(kubectl -n grafana get ingressroute grafana -o jsonpath='{.spec.routes[0].match}' \
    | sed -E 's/.*Host\(`([^`]+)`\).*/\1/')

echo "🚨 Break-glass admin for the platform Grafana (emergency use only)"
echo "   URL:      https://${host}/login  (use the username/password form, not SSO)"
echo "   User:     ${user}"
echo "   Password: ${pass}"
echo ""
echo "⚠️  Rotate afterwards (restarting Grafana also re-issues the MCP token; reconnect the MCP):"
echo "   kubectl delete secret ${SECRET} -n grafana && kubectl rollout restart deploy/grafana-deployment -n grafana"
