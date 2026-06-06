{
  "subject": {{ toJson .Subject }},
  "sans": {{ toJson .SANs }},
  {{ if typeIs "*rsa.PublicKey" .InsecureKey -}}
  "keyUsage": ["keyEncipherment", "digitalSignature"],
  {{ else -}}
  "keyUsage": ["digitalSignature"],
  {{ end -}}
  {{ if .Insecure.CR.ExtKeyUsage -}}
  "extendedKeyUsage": {{ toJson .Insecure.CR.ExtKeyUsage }},
  {{ else -}}
  "extendedKeyUsage": ["serverAuth", "clientAuth"],
  {{ end -}}
  "crlDistributionPoints": ["URI:https://${STEP_CA_HOST}:${STEP_CA_PORT}/1.0/crl"]
}
