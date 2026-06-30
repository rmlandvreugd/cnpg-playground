data:
  url: "https://argocd.${TRAEFIK_IP_DASHED}.sslip.io"
  oidc.config: |
    name: Authelia
    issuer: https://authelia.${TRAEFIK_EDGE_IP_DASHED}.sslip.io
    clientID: argocd
    # Sentinel restored to '$oidc.authelia.clientSecret' after envsubst — envsubst
    # otherwise strips the leading $oidc (unset var) and breaks the secret ref.
    clientSecret: __OIDC_CLIENT_SECRET_REF__
    requestedScopes: ["openid","profile","email","groups"]
    requestedIDTokenClaims:
      groups:
        essential: true
    # Authelia's TLS cert is signed by the local step-ca, not a public CA, so
    # argocd-server must be told the chain or OIDC discovery fails with
    # 'x509: certificate signed by unknown authority'.
    rootCA: |
${STEP_CA_CHAIN_PEM_ARGOCD}
