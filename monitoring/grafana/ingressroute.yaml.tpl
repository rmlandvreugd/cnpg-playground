apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: grafana
  namespace: grafana
spec:
  entryPoints:
    - websecure
  routes:
    - kind: Rule
      match: Host(`grafana.${TRAEFIK_IP_DASHED}.sslip.io`)
      services:
        - name: grafana-service
          port: 3000
  tls:
    secretName: grafana-monitoring-tls
