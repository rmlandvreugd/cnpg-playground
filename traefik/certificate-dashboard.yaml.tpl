apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: traefik-dashboard-cert
  namespace: traefik
spec:
  secretName: traefik-dashboard-tls
  issuerRef:
    name: vault-pki
    kind: ClusterIssuer
  dnsNames:
  - traefik.${TRAEFIK_IP_DASHED}.sslip.io
