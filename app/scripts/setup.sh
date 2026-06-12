#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$(dirname "$SCRIPT_DIR")"

echo "=== Demo App Setup ==="

# Get Traefik IP
TRAEFIK_IP=$(kubectl get svc -n traefik traefik -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "172.18.255.200")
TRAEFIK_IP_DASHED=$(echo "$TRAEFIK_IP" | tr '.' '-')
echo "Traefik IP: $TRAEFIK_IP (dashed: $TRAEFIK_IP_DASHED)"

# Create namespaces
echo "Creating namespaces..."
kubectl apply -f "$APP_DIR/k8s/namespace-demo.yaml"
kubectl apply -f "$APP_DIR/k8s/namespace-demo-dev.yaml"
kubectl apply -f "$APP_DIR/k8s/namespace-demo-db.yaml"

# Deploy ExternalSecrets
echo "Deploying ExternalSecrets..."
kubectl apply -f "$APP_DIR/k8s/externalsecret-demo-app.yaml"
kubectl apply -f "$APP_DIR/k8s/externalsecret-demo-readonly.yaml"
kubectl apply -f "$APP_DIR/k8s/externalsecret-demo-superuser.yaml"

# Deploy ObjectStore
echo "Deploying ObjectStore..."
envsubst < "$APP_DIR/k8s/objectstore-demo.yaml.tpl" | kubectl apply -f -

# Deploy CNPG cluster
echo "Deploying CNPG cluster..."
TRAEFIK_IP_DASHED="$TRAEFIK_IP_DASHED" envsubst < "$APP_DIR/k8s/cluster-demo.yaml.tpl" | kubectl apply -f -

# Wait for cluster ready
echo "Waiting for CNPG cluster to be ready..."
kubectl wait cluster/demo -n demo-db --for=condition=Ready --timeout=300s || true

# Build and deploy app via Helm
echo "Deploying app via Helm..."
helm upgrade --install demo-app "$APP_DIR/helm/demo-app" \
    --namespace demo \
    --set "global.traefikIpDashed=$TRAEFIK_IP_DASHED" \
    --set image.tag=v1 \
    --set migration.strategy=initContainer \
    --set observability.tracing.enabled=false

echo ""
echo "=== Setup Complete ==="
echo "App URL: https://demo-demo.$TRAEFIK_IP_DASHED.sslip.io"
echo "Health:  https://demo-demo.$TRAEFIK_IP_DASHED.sslip.io/health"
echo "Metrics: https://demo-demo.$TRAEFIK_IP_DASHED.sslip.io/metrics"
