apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: radar-tls-cert
  namespace: radar
spec:
  secretName: radar-tls
  issuerRef:
    name: vault-pki
    kind: ClusterIssuer
  privateKey:
    algorithm: ECDSA
    size: 256
  commonName: radar.${TRAEFIK_IP_DASHED}.sslip.io
  dnsNames:
  - radar.${TRAEFIK_IP_DASHED}.sslip.io
