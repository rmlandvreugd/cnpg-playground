apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: policy-reporter-tls-cert
  namespace: policy-reporter
spec:
  secretName: policy-reporter-tls
  issuerRef:
    name: vault-pki
    kind: ClusterIssuer
  privateKey:
    algorithm: ECDSA
    size: 256
  commonName: policy-reporter.${TRAEFIK_IP_DASHED}.sslip.io
  dnsNames:
  - policy-reporter.${TRAEFIK_IP_DASHED}.sslip.io
