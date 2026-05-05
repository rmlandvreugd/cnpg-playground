apiVersion: v1
kind: Secret
metadata:
  name: grafana-rbr-ver-oauth
  namespace: grafana
stringData:
  client-secret: ${GRAFANA_RBR_VER_CLIENT_SECRET}
