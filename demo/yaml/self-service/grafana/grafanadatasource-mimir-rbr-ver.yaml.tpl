apiVersion: grafana.integreatly.org/v1beta1
kind: GrafanaDatasource
metadata:
  name: mimir-rbr-ver
  namespace: grafana
spec:
  instanceSelector:
    matchLabels:
      dashboards: "grafana-rbr-ver"
  allowCrossNamespaceImport: true
  datasource:
    name: DS_MIMIR
    uid: mimir
    type: prometheus
    access: proxy
    url: http://mimir-nginx.mimir.svc.cluster.local/prometheus
    isDefault: false
    jsonData:
      httpHeaderName1: X-Scope-OrgID
      timeInterval: 15s
      exemplarTraceIdDestinations:
        - name: traceID
          datasourceUid: tempo
    secureJsonData:
      httpHeaderValue1: ${REGION}
