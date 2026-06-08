apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: grafana-monitoring-cert
  namespace: grafana
spec:
  secretName: grafana-monitoring-tls
  issuerRef:
    name: vault-pki
    kind: ClusterIssuer
  privateKey:
    algorithm: ECDSA
    size: 256
  commonName: grafana.${TRAEFIK_IP_DASHED}.sslip.io
  dnsNames:
  - grafana.${TRAEFIK_IP_DASHED}.sslip.io
