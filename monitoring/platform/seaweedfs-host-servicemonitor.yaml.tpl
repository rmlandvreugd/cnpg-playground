# Static Service + Endpoints for the HOST SeaweedFS container's Prometheus metrics.
#
# This is the store behind Loki-C, the control arm of the storage PoC. Without it
# the comparison has store-side metrics for arm B (the in-cluster SeaweedFS, via
# its operator-managed Services) but none for the control, which would make any
# "in-cluster vs host SeaweedFS" claim unfalsifiable.
#
# `weed server` serves /metrics only when -metricsPort is set — see
# SEAWEEDFS_METRICS_PORT in scripts/common.sh. The maintenance worker already had
# its own -metricsPort and is scraped here too.
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
apiVersion: v1
kind: Service
metadata:
  name: seaweedfs-worker-metrics
  namespace: otel
  labels:
    app.kubernetes.io/name: seaweedfs-worker-metrics
spec:
  clusterIP: None
  ports:
    - name: metrics
      port: ${SEAWEEDFS_WORKER_METRICS_PORT}
      targetPort: ${SEAWEEDFS_WORKER_METRICS_PORT}
      protocol: TCP
---
apiVersion: v1
kind: Endpoints
metadata:
  name: seaweedfs-worker-metrics
  namespace: otel
subsets:
  - addresses:
      - ip: ${SEAWEEDFS_WORKER_IP}
    ports:
      - name: metrics
        port: ${SEAWEEDFS_WORKER_METRICS_PORT}
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
---
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: seaweedfs-worker
  namespace: otel
spec:
  selector:
    matchLabels:
      app.kubernetes.io/name: seaweedfs-worker-metrics
  endpoints:
    - port: metrics
      path: /metrics
      scheme: http
      interval: 30s
