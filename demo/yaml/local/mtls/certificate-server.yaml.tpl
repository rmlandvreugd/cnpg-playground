apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: pg-local-server-tls
  namespace: ${CNPG_DEMO_NAMESPACE}
spec:
  commonName: pg-local-rw
  dnsNames:
    - pg-local-rw
    - pg-local-rw.${CNPG_DEMO_NAMESPACE}
    - pg-local-rw.${CNPG_DEMO_NAMESPACE}.svc
    - pg-local-rw.${CNPG_DEMO_NAMESPACE}.svc.cluster.local
    - pg-local-r
    - pg-local-r.${CNPG_DEMO_NAMESPACE}
    - pg-local-r.${CNPG_DEMO_NAMESPACE}.svc
    - pg-local-r.${CNPG_DEMO_NAMESPACE}.svc.cluster.local
    - pg-local-ro
    - pg-local-ro.${CNPG_DEMO_NAMESPACE}
    - pg-local-ro.${CNPG_DEMO_NAMESPACE}.svc
    - pg-local-ro.${CNPG_DEMO_NAMESPACE}.svc.cluster.local
    - pg-local-${CNPG_DEMO_NAMESPACE}-p.${TRAEFIK_POSTGRES_IP_DASHED}.sslip.io
  issuerRef:
    kind: ClusterIssuer
    name: vault-pki
  secretName: pg-local-server-tls
  duration: 720h
  renewBefore: 168h
  privateKey:
    algorithm: ECDSA
    size: 256