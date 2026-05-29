apiVersion: trust.cert-manager.io/v1alpha1
kind: Bundle
metadata:
  name: step-ca-bundle
spec:
  sources:
    - configMap:
        name: step-ca-roots
        key: ca-certificates.crt
  target:
    configMap:
      key: ca-certificates.crt
