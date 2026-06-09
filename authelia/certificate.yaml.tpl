apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: authelia-tls-cert
  namespace: authelia
spec:
  secretName: authelia-tls
  issuerRef:
    name: vault-pki
    kind: ClusterIssuer
  privateKey:
    algorithm: ECDSA
    size: 256
  commonName: authelia.${TRAEFIK_IP_DASHED}.sslip.io
  dnsNames:
  - authelia.${TRAEFIK_IP_DASHED}.sslip.io
