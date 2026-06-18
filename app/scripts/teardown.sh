#!/usr/bin/env bash
set -euo pipefail

echo "=== Demo App Teardown ==="

# Uninstall Helm releases
echo "Removing Helm releases..."
helm uninstall demo-app --namespace demo 2>/dev/null || true
helm uninstall demo-app --namespace demo-dev 2>/dev/null || true

# Remove dev Traefik LoadBalancer
echo "Removing dev Traefik LoadBalancer..."
kubectl delete svc traefik-dev -n traefik --ignore-not-found 2>/dev/null || true

# Delete CNPG cluster
echo "Removing CNPG cluster..."
kubectl delete cluster demo -n demo-db --wait=false 2>/dev/null || true
kubectl delete pooler pooler-demo-rw -n demo-db --wait=false 2>/dev/null || true

# Delete ObjectStore
kubectl delete objectstore objectstore-demo -n demo-db --wait=false 2>/dev/null || true

# Delete ExternalSecrets
kubectl delete externalsecret demo-app -n demo-db --wait=false 2>/dev/null || true
kubectl delete externalsecret demo-readonly -n demo-db --wait=false 2>/dev/null || true
kubectl delete externalsecret demo-superuser -n demo-db --wait=false 2>/dev/null || true

# Remove seeded Vault credentials
echo "Removing Vault credentials at cnpg/demo/..."
VAULT_CONTAINER="${VAULT_CONTAINER_NAME:-vault}"
ROOT_TOKEN=$(sudo cat "$(git -C "$(dirname "$0")" rev-parse --show-toplevel)/vault/.root_token" 2>/dev/null || true)
if [ -n "${ROOT_TOKEN:-}" ] && docker inspect "$VAULT_CONTAINER" >/dev/null 2>&1; then
    _vcmd() {
        docker exec \
            -e VAULT_ADDR="https://127.0.0.1:8200" \
            -e VAULT_CACERT=/vault/certs/vault-ca.pem \
            -e VAULT_TOKEN="$ROOT_TOKEN" \
            "$VAULT_CONTAINER" vault "$@"
    }
    _vcmd kv metadata delete cnpg/demo/superuser 2>/dev/null || true
    _vcmd kv metadata delete cnpg/demo/app       2>/dev/null || true
    _vcmd kv metadata delete cnpg/demo/readonly  2>/dev/null || true
    echo "Vault credentials removed."
else
    echo "Vault container not found or no root token — skipping Vault cleanup."
fi

# Delete namespaces
echo "Removing namespaces..."
kubectl delete namespace demo --wait=false 2>/dev/null || true
kubectl delete namespace demo-dev --wait=false 2>/dev/null || true
kubectl delete namespace demo-db --wait=false 2>/dev/null || true

echo ""
echo "=== Teardown Complete ==="
echo "Note: PVCs in demo-db namespace may persist. Delete manually if needed:"
echo "  kubectl delete pvc --all -n demo-db"
