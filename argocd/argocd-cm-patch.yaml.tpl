data:
  url: "https://argocd.${TRAEFIK_IP_DASHED}.sslip.io"
  oidc.config: |
    name: Authelia
    issuer: https://authelia.${TRAEFIK_IP_DASHED}.sslip.io
    clientID: argocd
    clientSecret: $oidc.authelia.clientSecret
    requestedScopes: ["openid","profile","email","groups"]
    requestedIDTokenClaims:
      groups:
        essential: true
