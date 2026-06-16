#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$(dirname "$SCRIPT_DIR")"

# Parse args
INSTALL_APP="${INSTALL_APP:-false}"
for arg in "$@"; do
    case "$arg" in
        --with-app) INSTALL_APP=true ;;
    esac
done

echo "=== Demo App Setup ==="
echo "DB provisioning: always"
echo "App install (--with-app): $INSTALL_APP"

# Get prod Traefik IP (primary .200)
TRAEFIK_IP=$(kubectl get svc -n traefik traefik -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "172.18.255.200")
TRAEFIK_IP_DASHED=$(echo "$TRAEFIK_IP" | tr '.' '-')
echo "Prod Traefik IP: $TRAEFIK_IP (dashed: $TRAEFIK_IP_DASHED)"

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

# Create dev Traefik LoadBalancer (draws a fresh MetalLB IP from kind-pool)
echo "Creating dev Traefik LoadBalancer..."
kubectl get svc traefik -n traefik -o json \
    | jq 'del(.status,.spec.clusterIP,.spec.clusterIPs,.spec.loadBalancerIP,
              .metadata.uid,.metadata.resourceVersion,.metadata.creationTimestamp,
              .metadata.annotations)
          | .metadata.name="traefik-dev"
          | .metadata.annotations={"metallb.universe.tf/address-pool":"kind-pool"}' \
    | kubectl apply -f -
kubectl wait --for=jsonpath='{.status.loadBalancer.ingress[0].ip}' \
    svc/traefik-dev -n traefik --timeout=60s
DEV_TRAEFIK_IP=$(kubectl get svc traefik-dev -n traefik \
    -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
DEV_TRAEFIK_IP_DASHED=$(echo "$DEV_TRAEFIK_IP" | tr '.' '-')
echo "Dev Traefik IP: $DEV_TRAEFIK_IP (dashed: $DEV_TRAEFIK_IP_DASHED)"

# Opt-in: install prod app into demo namespace
if [ "$INSTALL_APP" = true ]; then
    echo "Deploying prod app via Helm (--with-app)..."
    helm upgrade --install demo-app "$APP_DIR/helm/demo-app" \
        --namespace demo \
        --set "global.traefikIpDashed=$TRAEFIK_IP_DASHED" \
        --set image.tag=v1 \
        --set migration.strategy=initContainer \
        --set observability.tracing.enabled=false
    echo ""
    echo "Prod App URL: https://demo-demo.$TRAEFIK_IP_DASHED.sslip.io"
    echo "Prod Health:  https://demo-demo.$TRAEFIK_IP_DASHED.sslip.io/health"
fi

echo ""
echo "=== Setup Complete ==="
echo ""
echo "Dev Traefik IP assigned: $DEV_TRAEFIK_IP"
echo ""
echo "To start Tilt live-dev:"
echo "  export TRAEFIK_IP_DASHED=$DEV_TRAEFIK_IP_DASHED"
echo "  tilt up"
echo ""
echo "Dev app URL (after tilt up): https://demo-dev-demo.$DEV_TRAEFIK_IP_DASHED.sslip.io"
