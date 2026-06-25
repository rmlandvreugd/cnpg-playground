apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: gangplank-tls-cert
  namespace: gangplank
spec:
  secretName: gangplank-tls
  issuerRef:
    name: vault-pki
    kind: ClusterIssuer
  privateKey:
    algorithm: ECDSA
    size: 256
  commonName: gangplank.${TRAEFIK_IP_DASHED}.sslip.io
  dnsNames:
  - gangplank.${TRAEFIK_IP_DASHED}.sslip.io
