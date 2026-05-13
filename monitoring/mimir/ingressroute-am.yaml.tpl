apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: mimir-am
  namespace: mimir
spec:
  entryPoints: [web]
  routes:
    - match: Host(`mimir-am.${TRAEFIK_IP_DASHED}.sslip.io`)
      kind: Rule
      services:
        - name: mimir-alertmanager
          port: 8080
