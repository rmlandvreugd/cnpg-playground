apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: pgadmin-rbr-ver
  namespace: pgadmin
spec:
  entryPoints:
    - websecure
  routes:
    - kind: Rule
      match: Host(`pgadmin-rbr-ver.${TRAEFIK_IP_DASHED}.sslip.io`)
      services:
        - name: pgadmin-rbr-ver
          port: 80
  tls:
    secretName: pgadmin-rbr-ver-tls
