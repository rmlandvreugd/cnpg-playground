apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: grafana-rbr-ver-cert
  namespace: grafana
spec:
  secretName: grafana-rbr-ver-tls
  issuerRef:
    name: vault-pki
    kind: ClusterIssuer
  privateKey:
    algorithm: ECDSA
    size: 256
  commonName: grafana-rbr-ver.${TRAEFIK_IP_DASHED}.sslip.io
  dnsNames:
  - grafana-rbr-ver.${TRAEFIK_IP_DASHED}.sslip.io
