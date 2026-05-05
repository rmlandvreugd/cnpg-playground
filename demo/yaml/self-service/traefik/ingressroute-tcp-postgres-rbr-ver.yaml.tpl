apiVersion: traefik.io/v1alpha1
kind: IngressRouteTCP
metadata:
  name: postgres-rbr-ver
  namespace: traefik
spec:
  entryPoints:
    - postgres
  routes:
    - match: HostSNI(`verstappen-rbr-ver-db.${TRAEFIK_IP_DASHED}.sslip.io`)
      services:
        - name: verstappen-rw
          namespace: rbr-ver-db
          port: 5432
  tls:
    passthrough: true
