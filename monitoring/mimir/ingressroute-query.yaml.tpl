apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: mimir-query
  namespace: mimir
spec:
  entryPoints: [web]
  routes:
    - match: Host(`mimir-query.${TRAEFIK_IP_DASHED}.sslip.io`)
      kind: Rule
      services:
        - name: mimir-nginx
          port: 80
