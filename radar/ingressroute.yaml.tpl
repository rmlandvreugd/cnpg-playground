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
      match: Host(`radar.${TRAEFIK_IP_DASHED}.sslip.io`)
      services:
        - name: radar
          port: 9280
  tls:
    secretName: radar-tls
