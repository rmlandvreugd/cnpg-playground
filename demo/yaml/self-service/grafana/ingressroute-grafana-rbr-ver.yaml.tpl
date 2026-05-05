apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: grafana-rbr-ver
  namespace: grafana
spec:
  entryPoints:
    - websecure
  routes:
    - kind: Rule
      match: Host(`grafana-rbr-ver.${TRAEFIK_IP_DASHED}.sslip.io`)
      services:
        - name: grafana-rbr-ver-service
          port: 3000
  tls:
    secretName: grafana-rbr-ver-tls
