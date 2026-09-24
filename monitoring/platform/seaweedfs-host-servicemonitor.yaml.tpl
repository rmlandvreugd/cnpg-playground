# Static Service + Endpoints for the HOST SeaweedFS container's Prometheus metrics.
#
# This is the store behind Loki-C, the control arm of the storage PoC. Without it
# the comparison has store-side metrics for arm B (the in-cluster SeaweedFS, via
# its operator-managed Services) but none for the control, which would make any
# "in-cluster vs host SeaweedFS" claim unfalsifiable.
#
# `weed server` serves /metrics only when -metricsPort is set — see
# SEAWEEDFS_METRICS_PORT in scripts/common.sh.
#
# The maintenance worker is deliberately NOT scraped: it is attached only to the
# default docker bridge, not the kind network, so it has no address a pod can
# reach. An earlier version templated its kind IP anyway, got an empty string,
# and the Endpoints object was rejected (`ip: <no value>`), failing setup.
#
# Headless Service + manual Endpoints is the established pattern for host
# containers on the kind bridge (mirrors zot-servicemonitor.yaml and
# traefik-edge-servicemonitor.yaml). The IPs are templated rather than hard-coded
# because the containers get their bridge address at creation time.
apiVersion: v1
kind: Service
metadata:
  name: seaweedfs-host-metrics
  namespace: otel
  labels:
    app.kubernetes.io/name: seaweedfs-host-metrics
spec:
  clusterIP: None
  ports:
    - name: metrics
      port: ${SEAWEEDFS_METRICS_PORT}
      targetPort: ${SEAWEEDFS_METRICS_PORT}
      protocol: TCP
---
apiVersion: v1
kind: Endpoints
metadata:
  name: seaweedfs-host-metrics
  namespace: otel
subsets:
  - addresses:
      - ip: ${SEAWEEDFS_IP}
    ports:
      - name: metrics
        port: ${SEAWEEDFS_METRICS_PORT}
        protocol: TCP
---
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: seaweedfs-host
  namespace: otel
spec:
  selector:
    matchLabels:
      app.kubernetes.io/name: seaweedfs-host-metrics
  endpoints:
    - port: metrics
      path: /metrics
      scheme: http
      interval: 30s
