apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: pg-local-pooler-server-tls
  namespace: ${CNPG_DEMO_NAMESPACE}
spec:
  commonName: cnpg_pooler_pgbouncer
  dnsNames:
    - pg-local-rw.${CNPG_DEMO_NAMESPACE}.svc.cluster.local
  issuerRef:
    kind: ClusterIssuer
    name: vault-pki
  secretName: pg-local-pooler-server-tls
  duration: 720h
  renewBefore: 168h
  privateKey:
    algorithm: ECDSA
    size: 256