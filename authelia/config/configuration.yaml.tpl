server:
  address: 'tcp://:${AUTHELIA_PORT}'
  tls:
    certificate: /config/tls/authelia.crt
    key: /config/tls/authelia.key

log:
  level: info

identity_validation:
  reset_password:
    jwt_secret: '${AUTHELIA_JWT_SECRET}'

authentication_backend:
  file:
    path: /config/users_database.yml
    password:
      algorithm: bcrypt

session:
  secret: '${AUTHELIA_SESSION_SECRET}'
  cookies:
    - name: authelia_session
      domain: '${TRAEFIK_EDGE_IP_DASHED}.sslip.io'
      authelia_url: 'https://${AUTHELIA_HOST}'
      expiration: 1h
      inactivity: 5m

storage:
  encryption_key: '${AUTHELIA_STORAGE_ENCRYPTION_KEY}'
  local:
    path: /config/db.sqlite3

notifier:
  filesystem:
    filename: /config/notification.txt

access_control:
  default_policy: one_factor
  rules:
    - domain: 'radar.${TRAEFIK_IP_DASHED}.sslip.io'
      policy: one_factor
      subject:
        - 'group:k8s-admin'
    - domain: 'radar.${TRAEFIK_IP_DASHED}.sslip.io'
      policy: deny

identity_providers:
  oidc:
    hmac_secret: '${AUTHELIA_OIDC_HMAC_SECRET}'
    jwks:
      - key_id: 'default'
        algorithm: 'RS256'
        use: 'sig'
        key: {{ secret "/config/secrets/jwks_rsa_private.pem" | mindent 10 "|" | msquote }}
    claims_policies:
      default_policy:
        id_token:
          - 'groups'
          - 'email'
          - 'preferred_username'
          - 'name'
    clients:
      - client_id: vault
        client_name: Vault
        client_secret: '${AUTHELIA_VAULT_CLIENT_SECRET_HASH}'
        authorization_policy: one_factor
        redirect_uris:
          - 'https://127.0.0.1:${VAULT_PORT}/ui/vault/auth/oidc/oidc/callback'
          - 'https://localhost:8250/oidc/callback'
          - 'https://${VAULT_HOST}/ui/vault/auth/oidc/oidc/callback'
        scopes:
          - openid
          - email
          - profile
          - groups
        claims_policy: 'default_policy'
        userinfo_signed_response_alg: none
      - client_id: step-ca
        client_name: step-ca
        client_secret: '${AUTHELIA_STEP_CA_CLIENT_SECRET_HASH}'
        authorization_policy: one_factor
        redirect_uris:
          - 'https://${STEP_CA_HOST}:${STEP_CA_PORT}/oidc/callback'
        scopes:
          - openid
          - email
          - profile
          - groups
        claims_policy: 'default_policy'
        userinfo_signed_response_alg: none
      - client_id: grafana-rbr-ver
        client_name: Grafana RBR VER
        client_secret: '${AUTHELIA_GRAFANA_RBR_VER_CLIENT_SECRET_HASH}'
        authorization_policy: one_factor
        redirect_uris:
          - 'https://grafana-rbr-ver.${TRAEFIK_IP_DASHED}.sslip.io/login/generic_oauth'
        scopes:
          - openid
          - email
          - profile
          - groups
        claims_policy: 'default_policy'
        userinfo_signed_response_alg: none
      - client_id: grafana-monitoring
        client_name: Grafana Monitoring
        client_secret: '${AUTHELIA_GRAFANA_MONITORING_CLIENT_SECRET_HASH}'
        authorization_policy: one_factor
        redirect_uris:
          - 'https://grafana.${TRAEFIK_IP_DASHED}.sslip.io/login/generic_oauth'
        scopes:
          - openid
          - email
          - profile
          - groups
        claims_policy: 'default_policy'
        userinfo_signed_response_alg: none
      - client_id: kubernetes
        client_name: Kubernetes
        public: true
        redirect_uris:
          - 'http://localhost:8000'
          - 'http://localhost:18000'
        scopes:
          - openid
          - email
          - profile
          - groups
        claims_policy: 'default_policy'
      - client_id: gangplank
        client_name: Gangplank
        client_secret: '${AUTHELIA_GANGPLANK_CLIENT_SECRET_HASH}'
        authorization_policy: one_factor
        redirect_uris:
          - 'https://gangplank.${TRAEFIK_IP_DASHED}.sslip.io/callback'
        scopes:
          - openid
          - email
          - profile
          - groups
        claims_policy: 'default_policy'
        userinfo_signed_response_alg: none
      - client_id: argocd
        client_name: ArgoCD
        client_secret: '${AUTHELIA_ARGOCD_CLIENT_SECRET_HASH}'
        authorization_policy: one_factor
        redirect_uris:
          - 'https://argocd.${TRAEFIK_IP_DASHED}.sslip.io/auth/callback'
        scopes:
          - openid
          - email
          - profile
          - groups
        claims_policy: 'default_policy'
        userinfo_signed_response_alg: none
      - client_id: seaweedfs-s3
        client_name: SeaweedFS S3
        client_secret: '${AUTHELIA_SEAWEEDFS_S3_CLIENT_SECRET_HASH}'
        authorization_policy: one_factor
        redirect_uris:
          - 'https://seaweedfs.${TRAEFIK_EDGE_IP_DASHED}.sslip.io/iam'
        scopes:
          - openid
          - email
          - profile
          - groups
        claims_policy: 'default_policy'
        userinfo_signed_response_alg: none
