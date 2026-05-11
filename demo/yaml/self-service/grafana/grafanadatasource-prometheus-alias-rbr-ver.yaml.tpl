apiVersion: grafana.integreatly.org/v1beta1
kind: GrafanaDatasource
metadata:
  name: prometheus-rbr-ver
  namespace: grafana
spec:
  instanceSelector:
    matchLabels:
      dashboards: "grafana-rbr-ver"
  allowCrossNamespaceImport: true
  datasource:
    name: DS_PROMETHEUS
    uid: prometheus
    type: prometheus
    access: proxy
    url: http://mimir-nginx.mimir.svc.cluster.local/prometheus
    isDefault: true
    jsonData:
      httpHeaderName1: X-Scope-OrgID
      timeInterval: 15s
      exemplarTraceIdDestinations:
        - name: traceID
          datasourceUid: tempo
    secureJsonData:
      httpHeaderValue1: ${REGION}
