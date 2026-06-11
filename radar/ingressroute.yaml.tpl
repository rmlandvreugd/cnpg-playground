apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: radar
  namespace: radar
spec:
  entryPoints:
    - websecure
  routes:
    - kind: Rule
      match: Host(`radar.${TRAEFIK_IP_DASHED}.sslip.io`) && PathPrefix(`/mcp`)
      services:
        - name: radar
          port: 9280
    - kind: Rule
      match: Host(`radar.${TRAEFIK_IP_DASHED}.sslip.io`)
      middlewares:
        - name: authelia-forwardauth
      services:
        - name: radar
          port: 9280
  tls:
    secretName: radar-tls
