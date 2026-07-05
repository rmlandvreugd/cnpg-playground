apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: argocd-tls-cert
  namespace: argocd
spec:
  secretName: argocd-tls
  issuerRef:
    name: vault-pki
    kind: ClusterIssuer
  privateKey:
    algorithm: ECDSA
    size: 256
  commonName: argocd.${TRAEFIK_IP_DASHED}.sslip.io
  dnsNames:
  - argocd.${TRAEFIK_IP_DASHED}.sslip.io
