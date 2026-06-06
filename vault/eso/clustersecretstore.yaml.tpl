apiVersion: external-secrets.io/v1
kind: ClusterSecretStore
metadata:
  name: vault-approle
spec:
  provider:
    vault:
      server: "https://vault.vault.svc.cluster.local:8200"
      path: "cnpg"
      version: "v2"
      caProvider:
        type: ConfigMap
        name: vault-pki-bundle
        namespace: ${ESO_NAMESPACE}
        key: ca-certificates.crt
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
