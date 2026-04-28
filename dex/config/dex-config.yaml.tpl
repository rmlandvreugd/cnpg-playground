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
enablePasswordDB: true
staticPasswords:
- email: "user@example.com"
  hash: "$2a$10$2b2cU8CPhOTaGrs1HRQuAueS7JTT5ZHsHSzYiFPm1leZck7Mc8T4W"
  username: "dexuser"
  userID: "user-12345"
