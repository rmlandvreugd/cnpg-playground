apiVersion: traefik.io/v1alpha1
kind: IngressRouteTCP
metadata:
  name: pg-local-tls-term
  namespace: ${CNPG_DEMO_NAMESPACE}
spec:
  entryPoints:
    - postgres
  routes:
    - match: HostSNI(`pg-local-${CNPG_DEMO_NAMESPACE}-t.${TRAEFIK_POSTGRES_IP_DASHED}.sslip.io`)
      services:
        - name: pg-local-rw
          port: 5432
          namespace: ${CNPG_DEMO_NAMESPACE}
  tls:
    secretName: pg-local-tls-term-server-tls
    options:
      name: mtls-verify
      namespace: traefik