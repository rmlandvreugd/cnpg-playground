apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: vault-pki
spec:
  vault:
    server: https://vault.vault.svc.cluster.local:${VAULT_PORT}
    path: pki_int/sign/cluster-certs
    caBundle: ${VAULT_CA_BUNDLE}
    auth:
      appRole:
        path: approle
        roleId: ${VAULT_APPROLE_ROLE_ID}
        secretRef:
          name: vault-approle
          key: secretId
