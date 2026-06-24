apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: pgadmin-rbr-ver-cert
  namespace: pgadmin
spec:
  secretName: pgadmin-rbr-ver-tls
  issuerRef:
    name: vault-pki
    kind: ClusterIssuer
  # vault-pki signs EC keys only (role key_type=ec); RSA CSRs are rejected.
  privateKey:
    algorithm: ECDSA
    size: 256
  commonName: pgadmin-rbr-ver.${TRAEFIK_IP_DASHED}.sslip.io
  dnsNames:
  - pgadmin-rbr-ver.${TRAEFIK_IP_DASHED}.sslip.io
