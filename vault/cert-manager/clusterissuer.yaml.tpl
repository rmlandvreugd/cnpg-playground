apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: vault-pki
spec:
  vault:
    server: http://vault.vault.svc.cluster.local:${VAULT_HTTP_PORT}
    path: pki_int/sign/cluster-certs
    auth:
      appRole:
        path: approle
        roleId: ${VAULT_APPROLE_ROLE_ID}
        secretRef:
          name: vault-approle
          key: secretId
