apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: argocd
  namespace: argocd
spec:
  entryPoints:
    - websecure
  routes:
    - kind: Rule
      match: Host(`argocd.${TRAEFIK_IP_DASHED}.sslip.io`)
      services:
        - name: argocd-server
          port: 80
  tls:
    secretName: argocd-tls
