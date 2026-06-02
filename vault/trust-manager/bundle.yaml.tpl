apiVersion: trust.cert-manager.io/v1alpha1
kind: Bundle
metadata:
  name: vault-pki-bundle
spec:
  sources:
    - configMap:
        name: step-ca-roots
        key: ca-certificates.crt
    - secret:
        name: vault-pki-int-ca
        key: ca.crt
      namespace: cert-manager
  target:
    configMap:
      key: ca-certificates.crt
    secret:
      key: ca.crt