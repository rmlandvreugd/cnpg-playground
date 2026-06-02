apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: pg-local-replication-tls
  namespace: ${CNPG_DEMO_NAMESPACE}
spec:
  commonName: streaming_replica
  dnsNames:
    - pg-local-rw.${CNPG_DEMO_NAMESPACE}.svc.cluster.local
  issuerRef:
    kind: ClusterIssuer
    name: vault-pki
  secretName: pg-local-replication-tls
  duration: 720h
  renewBefore: 168h
  privateKey:
    algorithm: ECDSA
    size: 256