apiVersion: grafana.integreatly.org/v1beta1
kind: GrafanaDatasource
metadata:
  name: mimir-fleet-rbr-ver
  namespace: grafana
spec:
  instanceSelector:
    matchLabels:
      dashboards: grafana-rbr-ver
  allowCrossNamespaceImport: true
  datasource:
    name: DS_MIMIR_FLEET
    uid: mimir-fleet-rbr-ver
    type: prometheus
    access: proxy
    url: ${MIMIR_QUERY_URL}
    isDefault: false
    jsonData:
      httpHeaderName1: X-Scope-OrgID
      timeInterval: 30s
    secureJsonData:
      httpHeaderValue1: ${FLEET_TENANTS}
