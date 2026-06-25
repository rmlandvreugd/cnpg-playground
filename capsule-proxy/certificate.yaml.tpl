apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: capsule-proxy-ingress-tls-cert
  namespace: capsule-system
spec:
  secretName: capsule-proxy-ingress-tls
  issuerRef:
    name: vault-pki
    kind: ClusterIssuer
  privateKey:
    algorithm: ECDSA
    size: 256
  commonName: capsule-proxy.${TRAEFIK_IP_DASHED}.sslip.io
  dnsNames:
  - capsule-proxy.${TRAEFIK_IP_DASHED}.sslip.io
