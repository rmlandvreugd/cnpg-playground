apiVersion: grafana.integreatly.org/v1beta1
kind: Grafana
metadata:
  name: grafana-rbr-ver
  namespace: grafana
  labels:
    dashboards: "grafana-rbr-ver"
spec:
  config:
    server:
      root_url: "https://grafana-rbr-ver.${TRAEFIK_IP_DASHED}.sslip.io"
    log:
      mode: "console"
    security:
      admin_user: admin
      admin_password: admin
    live:
      max_connections: "0"
    "auth.generic_oauth":
      enabled: "true"
      name: "Dex"
      allow_sign_up: "true"
      client_id: "grafana-rbr-ver"
      client_secret: ""
      scopes: "openid email profile groups"
      auth_url: "https://${DEX_HOST}:${DEX_PORT}/dex/auth"
      token_url: "https://${DEX_HOST}:${DEX_PORT}/dex/token"
      api_url: "https://${DEX_HOST}:${DEX_PORT}/dex/userinfo"
      groups_attribute_path: "groups"
      org_attribute_path: "groups"
      org_mapping: "rbr-db-admin:rbr:Admin rbr-ver-db-admin:rbr:Editor"
      allowed_groups: "rbr-db-admin,rbr-ver-db-admin"
      role_attribute_strict: "false"
      tls_client_ca_file: "/etc/ssl/dex-ca/ca-chain.pem"
  deployment:
    spec:
      template:
        spec:
          nodeSelector:
            node-role.kubernetes.io/infra: ""
          initContainers:
            - name: install-dex-ca
              image: docker.io/grafana/grafana:12.4.1
              command:
                - sh
                - -c
                - "cp /etc/ssl/certs/ca-certificates.crt /shared-ssl-certs/ca-certificates.crt && cat /etc/ssl/dex-ca/ca-chain.pem >> /shared-ssl-certs/ca-certificates.crt"
              volumeMounts:
                - name: dex-ca
                  mountPath: /etc/ssl/dex-ca
                  readOnly: true
                - name: shared-ssl-certs
                  mountPath: /shared-ssl-certs
          volumes:
            - name: dex-ca
              configMap:
                name: dex-ca-cert
            - name: shared-ssl-certs
              emptyDir: {}
          containers:
            - name: grafana
              env:
                - name: GF_AUTH_GENERIC_OAUTH_CLIENT_SECRET
                  valueFrom:
                    secretKeyRef:
                      name: grafana-rbr-ver-oauth
                      key: client-secret
              volumeMounts:
                - name: dex-ca
                  mountPath: /etc/ssl/dex-ca
                  readOnly: true
                - name: shared-ssl-certs
                  mountPath: /etc/ssl/certs
