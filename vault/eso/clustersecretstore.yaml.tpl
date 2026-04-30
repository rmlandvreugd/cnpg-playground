apiVersion: external-secrets.io/v1
kind: ClusterSecretStore
metadata:
  name: vault-approle
spec:
  provider:
    vault:
      server: "http://vault.vault.svc.cluster.local:${VAULT_HTTP_PORT}"
      path: "cnpg"
      version: "v2"
      auth:
        appRole:
          path: "approle"
          roleRef:
            name: vault-approle-creds
            namespace: ${ESO_NAMESPACE}
            key: roleId
          secretRef:
            name: vault-approle-creds
            namespace: ${ESO_NAMESPACE}
            key: secretId
