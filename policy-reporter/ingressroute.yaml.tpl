apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: policy-reporter
  namespace: policy-reporter
spec:
  entryPoints:
    - websecure
  routes:
    - kind: Rule
      match: Host(`policy-reporter.${TRAEFIK_IP_DASHED}.sslip.io`)
      middlewares:
        - name: authelia-forwardauth
      services:
        - name: policy-reporter-ui
          port: 8080
  tls:
    secretName: policy-reporter-tls
