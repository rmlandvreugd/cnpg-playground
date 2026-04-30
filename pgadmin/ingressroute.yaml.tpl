apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: pgadmin
  namespace: pgadmin
spec:
  entryPoints:
    - web
  routes:
    - kind: Rule
      match: Host(`pgadmin.${TRAEFIK_IP_DASHED}.sslip.io`)
      services:
        - name: pgadmin
          port: 80
