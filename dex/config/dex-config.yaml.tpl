issuer: https://${DEX_HOST}:${DEX_PORT}/dex
storage:
  type: sqlite3
  config:
    file: /var/dex/dex.db
web:
  https: 0.0.0.0:${DEX_PORT}
  tlsCert: /etc/dex/tls/dex.crt
  tlsKey: /etc/dex/tls/dex.key
staticClients:
- id: ${DEX_OIDC_CLIENT_ID}
  redirectURIs:
  - https://127.0.0.1:${VAULT_PORT}/ui/vault/auth/oidc/oidc/callback
  - https://localhost:8250/oidc/callback
  - https://${VAULT_HOST}:${VAULT_PORT}/ui/vault/auth/oidc/oidc/callback
  name: Vault
  secret: ${DEX_OIDC_CLIENT_SECRET}
- id: grafana-rbr-ver
  name: Grafana RBR VER
  secret: ${DEX_GRAFANA_RBR_VER_CLIENT_SECRET}
  redirectURIs:
  - https://grafana-rbr-ver.${TRAEFIK_IP_DASHED}.sslip.io/login/generic_oauth
enablePasswordDB: true
staticPasswords:
- email: "user@example.com"
  hash: "${DEX_STATIC_PASSWORD_HASH}"
  username: "dexuser"
  userID: "user-12345"
- email: "rbr-admin@example.com"
  hash: "${DEX_RBR_ADMIN_PASSWORD_HASH}"
  username: "rbr-admin"
  userID: "rbr-admin-001"
  groups:
  - "rbr-db-admin"
  - "rbr-ver-db-admin"
- email: "rbr-ver-admin@example.com"
  hash: "${DEX_RBR_VER_ADMIN_PASSWORD_HASH}"
  username: "rbr-ver-admin"
  userID: "rbr-ver-admin-001"
  groups:
  - "rbr-ver-db-admin"
- email: "unrelated@example.com"
  hash: "${DEX_UNRELATED_PASSWORD_HASH}"
  username: "unrelated"
  userID: "unrelated-001"
  groups: []
