apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: pg-local-pooler-client-tls
  namespace: ${CNPG_DEMO_NAMESPACE}
spec:
  commonName: pg-local-pooler
  dnsNames:
    - pooler-local-rw
    - pooler-local-rw.${CNPG_DEMO_NAMESPACE}
    - pooler-local-rw.${CNPG_DEMO_NAMESPACE}.svc
    - pooler-local-rw.${CNPG_DEMO_NAMESPACE}.svc.cluster.local
  issuerRef:
    kind: ClusterIssuer
    name: vault-pki
  secretName: pg-local-pooler-client-tls
  duration: 720h
  renewBefore: 168h
  privateKey:
    algorithm: ECDSA
    size: 256