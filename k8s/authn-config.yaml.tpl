apiVersion: apiserver.config.k8s.io/v1
kind: AuthenticationConfiguration
jwt:
  - issuer:
      url: https://authelia.${HUB_TRAEFIK_IP_DASHED}.sslip.io
      audiences:
        - kubernetes
        - gangplank
      audienceMatchPolicy: MatchAny
      certificateAuthority: |
${STEP_CA_CHAIN_PEM}
    claimMappings:
      username:
        claim: email
        prefix: "oidc:"
      groups:
        claim: groups
        prefix: "oidc:"
    userValidationRules:
      - expression: "!user.username.startsWith('system:')"
        message: "username cannot use reserved system: prefix"
