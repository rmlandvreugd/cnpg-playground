apiVersion: grafana.integreatly.org/v1beta1
kind: Grafana
metadata:
  name: grafana
  namespace: grafana
  labels:
    dashboards: "grafana"
spec:
  config:
    server:
      root_url: "https://grafana.${TRAEFIK_IP_DASHED}.sslip.io"
    log:
      mode: "console"
    security:
      admin_user: admin
      admin_password: admin
    live:
      max_connections: "0"
    # Note: no signout_redirect_url -> Grafana's logout returns to its own login
    # page instead of stranding the browser on Authelia. RP-initiated SSO logout
    # (Authelia end_session + post_logout_redirect_uris) needs Authelia >= 4.40;
    # this deployment runs 4.39.x which neither advertises end_session nor
    # accepts the post_logout_redirect_uris client key.
    "auth.generic_oauth":
      enabled: "true"
      name: "Authelia"
      allow_sign_up: "true"
      client_id: "grafana-monitoring"
      client_secret: ""
      scopes: "openid email profile groups"
      # Browser-facing + backend OIDC endpoints must use the Traefik-domain
      # Authelia (same domain as the user's SSO session), not the host-IP
      # :9091 endpoint, or the two-domain session split strands login.
      auth_url: "https://authelia.${TRAEFIK_IP_DASHED}.sslip.io/api/oidc/authorization"
      token_url: "https://authelia.${TRAEFIK_IP_DASHED}.sslip.io/api/oidc/token"
      api_url: "https://authelia.${TRAEFIK_IP_DASHED}.sslip.io/api/oidc/userinfo"
      groups_attribute_path: "groups"
      org_mapping: "rbr-db-admin:Main Org.:Admin rbr-ver-db-admin:Main Org.:Viewer"
      role_attribute_strict: "false"
      tls_client_ca_file: "/etc/ssl/authelia-ca/ca-chain.pem"
  deployment:
    spec:
      template:
        spec:
          nodeSelector:
            node-role.kubernetes.io/infra: ""
          initContainers:
            - name: install-authelia-ca
              image: docker.io/grafana/grafana:12.4.1
              command:
                - sh
                - -c
                - "cp /etc/ssl/certs/ca-certificates.crt /shared-ssl-certs/ca-certificates.crt && cat /etc/ssl/authelia-ca/ca-chain.pem >> /shared-ssl-certs/ca-certificates.crt"
              volumeMounts:
                - name: authelia-ca
                  mountPath: /etc/ssl/authelia-ca
                  readOnly: true
                - name: shared-ssl-certs
                  mountPath: /shared-ssl-certs
          volumes:
            - name: authelia-ca
              configMap:
                name: authelia-ca-cert
            - name: shared-ssl-certs
              emptyDir: {}
          containers:
            - name: grafana
              env:
                - name: GF_AUTH_GENERIC_OAUTH_CLIENT_SECRET
                  valueFrom:
                    secretKeyRef:
                      name: grafana-monitoring-oauth
                      key: client-secret
              volumeMounts:
                - name: authelia-ca
                  mountPath: /etc/ssl/authelia-ca
                  readOnly: true
                - name: shared-ssl-certs
                  mountPath: /etc/ssl/certs
