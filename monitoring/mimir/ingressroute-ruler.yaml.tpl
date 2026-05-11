apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: mimir-ruler
  namespace: mimir
spec:
  entryPoints: [web]
  routes:
    - match: Host(`mimir-ruler.${TRAEFIK_IP_DASHED}.sslip.io`)
      kind: Rule
      services:
        - name: mimir-ruler
          port: 8080
