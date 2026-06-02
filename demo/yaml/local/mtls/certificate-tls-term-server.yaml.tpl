apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: pg-local-tls-term-server
  namespace: ${CNPG_DEMO_NAMESPACE}
spec:
  commonName: pg-local-${CNPG_DEMO_NAMESPACE}-t.${TRAEFIK_POSTGRES_IP_DASHED}.sslip.io
  dnsNames:
    - pg-local-${CNPG_DEMO_NAMESPACE}-t.${TRAEFIK_POSTGRES_IP_DASHED}.sslip.io
  issuerRef:
    kind: ClusterIssuer
    name: vault-pki
  secretName: pg-local-tls-term-server-tls
  duration: 720h
  renewBefore: 168h
  privateKey:
    algorithm: ECDSA
    size: 256