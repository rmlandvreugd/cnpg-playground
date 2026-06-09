users:
  admin:
    displayname: "Administrator"
    password: "${AUTHELIA_STATIC_PASSWORD_HASH}"
    email: admin@example.com
    groups:
      - admin
      - authelia-admin
      - grafana-admin
      - vault-admin
      - data-admin
      - database-admin
      - k8s-admin
  authuser:
    displayname: "Authelia User"
    password: "${AUTHELIA_STATIC_PASSWORD_HASH}"
    email: user@example.com
    groups: []
  rbr-admin:
    displayname: "RBR Admin"
    password: "${AUTHELIA_RBR_ADMIN_PASSWORD_HASH}"
    email: rbr-admin@example.com
    groups:
      - rbr-db-admin
      - rbr-ver-db-admin
  rbr-ver-admin:
    displayname: "RBR VER Admin"
    password: "${AUTHELIA_RBR_VER_ADMIN_PASSWORD_HASH}"
    email: rbr-ver-admin@example.com
    groups:
      - rbr-ver-db-admin
  unrelated:
    displayname: "Unrelated"
    password: "${AUTHELIA_UNRELATED_PASSWORD_HASH}"
    email: unrelated@example.com
    groups: []
