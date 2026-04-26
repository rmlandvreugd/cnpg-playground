apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: traefik-dashboard
  namespace: traefik
spec:
  entryPoints:
    - web
  routes:
    - kind: Rule
      match: Host(`traefik.${TRAEFIK_IP_DASHED}.sslip.io`) && (PathPrefix(`/dashboard`) || PathPrefix(`/api`))
      services:
        - name: api@internal
          kind: TraefikService
