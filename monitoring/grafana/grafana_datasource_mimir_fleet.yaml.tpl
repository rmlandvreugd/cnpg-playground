apiVersion: grafana.integreatly.org/v1beta1
kind: GrafanaDatasource
metadata:
  name: mimir-fleet
  namespace: grafana
spec:
  instanceSelector:
    matchLabels:
      dashboards: grafana
  allowCrossNamespaceImport: true
  datasource:
    name: DS_MIMIR_FLEET
    uid: mimir-fleet
    type: prometheus
    access: proxy
    url: ${MIMIR_QUERY_URL}
    isDefault: false
    jsonData:
      httpHeaderName1: X-Scope-OrgID
      timeInterval: 30s
      exemplarTraceIdDestinations:
        - name: traceID
          datasourceUid: tempo
    secureJsonData:
      httpHeaderValue1: ${FLEET_TENANTS}
