apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: gangplank
  namespace: gangplank
spec:
  entryPoints:
    - websecure
  routes:
    - kind: Rule
      match: Host(`gangplank.${TRAEFIK_IP_DASHED}.sslip.io`)
      services:
        - name: gangplank
          port: 80
  tls:
    secretName: gangplank-tls
