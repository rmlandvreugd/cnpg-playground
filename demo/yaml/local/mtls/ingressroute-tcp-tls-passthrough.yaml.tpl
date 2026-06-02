apiVersion: traefik.io/v1alpha1
kind: IngressRouteTCP
metadata:
  name: pg-local-tls-passthrough
  namespace: ${CNPG_DEMO_NAMESPACE}
spec:
  entryPoints:
    - postgres
  routes:
    - match: HostSNI(`pg-local-${CNPG_DEMO_NAMESPACE}-p.${TRAEFIK_POSTGRES_IP_DASHED}.sslip.io`)
      services:
        - name: pg-local-rw
          port: 5432
          namespace: ${CNPG_DEMO_NAMESPACE}
  tls:
    passthrough: true