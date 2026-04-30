apiVersion: external-secrets.io/v1
kind: ClusterSecretStore
metadata:
  name: vault-approle
spec:
  provider:
    vault:
      server: "https://vault.vault.svc.cluster.local:${VAULT_PORT}"
      path: "cnpg"
      version: "v2"
      caProvider:
        type: Secret
        name: vault-ca-cert
        namespace: ${ESO_NAMESPACE}
        key: ca.crt
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
