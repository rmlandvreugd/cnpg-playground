apiVersion: grafana.integreatly.org/v1beta1
kind: GrafanaDatasource
metadata:
  name: mimir-tempo
  namespace: grafana
spec:
  instanceSelector:
    matchLabels:
      dashboards: grafana
  allowCrossNamespaceImport: true
  datasource:
    name: DS_MIMIR_TEMPO
    uid: mimir-tempo
    type: prometheus
    access: proxy
    url: http://mimir-gateway.mimir.svc.cluster.local/prometheus
    jsonData:
      httpHeaderName1: X-Scope-OrgID
      timeInterval: 15s
    secureJsonData:
      # Platform view: the platform org plus every Capsule tenant's org.
      # >>> per-tenant: grafana-org-header (generated, see scripts/render-tenant-telemetry.py)
      # <<< per-tenant
