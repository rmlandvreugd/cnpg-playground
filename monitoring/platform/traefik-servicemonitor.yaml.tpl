# Scrape the in-cluster Traefik metrics entrypoint (:9100, Service traefik-metrics from
# the chart's metrics.prometheus.service) and label each series with its Capsule tenant.
#
# This lives here rather than in the chart's metrics.prometheus.serviceMonitor because the
# relabelings are generated per tenant (bd3d.7): regenerating them through the chart would
# mean re-running `helm upgrade traefik` with the exact install-time --set flags every time
# a tenant is onboarded. A ServiceMonitor is a plain object, so it is just re-applied.
#
# Router and service labels only exist with metrics.prometheus.addRoutersLabels /
# addServicesLabels (traefik/values.yaml). Entry-point-level series carry neither and stay
# tenant="platform": they aggregate across tenants (bd3d.10).
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: traefik-metrics
  namespace: traefik
  labels:
    app.kubernetes.io/name: traefik
    app.kubernetes.io/component: metrics
spec:
  jobLabel: traefik
  namespaceSelector:
    matchNames:
      - traefik
  selector:
    matchLabels:
      app.kubernetes.io/name: traefik
      app.kubernetes.io/instance: traefik-traefik
  endpoints:
    - path: /metrics
      targetPort: metrics
      metricRelabelings:
        - targetLabel: tenant
          replacement: platform
        # >>> per-tenant: traefik-metric-relabelings (generated, see scripts/render-tenant-telemetry.py)
        # <<< per-tenant
