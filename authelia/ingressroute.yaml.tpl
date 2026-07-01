apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: authelia
  namespace: authelia
spec:
  entryPoints:
    - websecure
  routes:
    - kind: Rule
      match: Host(`authelia.${TRAEFIK_IP_DASHED}.sslip.io`)
      services:
        - name: authelia-backend
          port: 443
          scheme: https
          serversTransport: authelia-transport
  tls:
    secretName: authelia-tls
