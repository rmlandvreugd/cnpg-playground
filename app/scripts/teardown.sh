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

# Delete namespaces
echo "Removing namespaces..."
kubectl delete namespace demo --wait=false 2>/dev/null || true
kubectl delete namespace demo-dev --wait=false 2>/dev/null || true
kubectl delete namespace demo-db --wait=false 2>/dev/null || true

echo ""
echo "=== Teardown Complete ==="
echo "Note: PVCs in demo-db namespace may persist. Delete manually if needed:"
echo "  kubectl delete pvc --all -n demo-db"
