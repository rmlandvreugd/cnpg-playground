apiVersion: grafana.integreatly.org/v1beta1
kind: GrafanaDatasource
metadata:
  name: prometheus
  namespace: grafana
spec:
  instanceSelector:
    matchLabels:
      dashboards: grafana
  allowCrossNamespaceImport: true
  datasource:
    name: DS_PROMETHEUS
    uid: prometheus
    type: prometheus
    access: proxy
    url: ${MIMIR_QUERY_URL}
    isDefault: true
    jsonData:
      httpHeaderName1: X-Scope-OrgID
      timeInterval: 15s
      exemplarTraceIdDestinations:
        - name: traceID
          datasourceUid: tempo
    secureJsonData:
      httpHeaderValue1: ${REGION}
