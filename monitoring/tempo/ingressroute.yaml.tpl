apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: tempo-otlp-http
  namespace: tempo
spec:
  entryPoints: [web]
  routes:
    - match: Host(`tempo-otlp.${TRAEFIK_IP_DASHED}.sslip.io`)
      kind: Rule
      services:
        - name: tempo-distributor
          port: 4318
