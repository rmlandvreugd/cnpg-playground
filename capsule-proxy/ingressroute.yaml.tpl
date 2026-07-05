apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: capsule-proxy
  namespace: capsule-system
spec:
  entryPoints:
    - websecure
  routes:
    - kind: Rule
      match: Host(`capsule-proxy.${TRAEFIK_IP_DASHED}.sslip.io`)
      services:
        - name: capsule-proxy
          port: 9001
          scheme: https
          serversTransport: capsule-proxy-transport
  tls:
    secretName: capsule-proxy-ingress-tls
