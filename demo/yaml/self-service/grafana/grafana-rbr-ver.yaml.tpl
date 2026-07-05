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
    # Note: no signout_redirect_url -> Grafana's logout returns to its own login
    # page instead of stranding the browser on Authelia. RP-initiated SSO logout
    # (Authelia end_session + post_logout_redirect_uris) needs Authelia >= 4.40;
    # this deployment runs 4.39.x which neither advertises end_session nor
    # accepts the post_logout_redirect_uris client key.
    "auth.generic_oauth":
      enabled: "true"
      name: "Authelia"
      allow_sign_up: "true"
      client_id: "grafana-rbr-ver"
      client_secret: ""
      scopes: "openid email profile groups"
      # Browser-facing + backend OIDC endpoints must use the Traefik-domain
      # Authelia (same domain as the user's SSO session), not the host-IP
      # :9091 endpoint, or the two-domain session split strands login.
      auth_url: "https://authelia.${TRAEFIK_IP_DASHED}.sslip.io/api/oidc/authorization"
      token_url: "https://authelia.${TRAEFIK_IP_DASHED}.sslip.io/api/oidc/token"
      api_url: "https://authelia.${TRAEFIK_IP_DASHED}.sslip.io/api/oidc/userinfo"
      groups_attribute_path: "groups"
      org_attribute_path: "groups"
      # Server-admin (isGrafanaAdmin) for the admin persona comes from
      # role_attribute_path, NOT org_mapping: a "*" in the org position does not
      # set the server-admin flag (that flag is derived from role_attribute_path
      # via extractRoleAndAdminOptional). Empty for everyone else so org_mapping
      # governs their role (role_attribute_strict=false lets '' fall through).
      role_attribute_path: "contains(groups, 'grafana-admin') && 'GrafanaAdmin' || ''"
      # This instance is the rbr tenant's own Grafana and has only the default
      # org (id 1) — grafana-operator never creates a named "rbr" org, so the
      # old "rbr" org target resolved to nothing. Tenant personas map onto org 1.
      # Per persona matrix: rbr-admin=Admin, rbr-ver-admin & rbr-ver-dev=Editor,
      # rbr-po=Viewer on this tenant instance.
      org_mapping: "rbr-db-admin:1:Admin rbr-ver-db-admin:1:Editor rbr-ver-dev:1:Editor rbr-po:1:Viewer"
      # Required or Grafana drops the GrafanaAdmin role and falls back to Viewer.
      allow_assign_grafana_admin: "true"
      allowed_groups: "grafana-admin,rbr-db-admin,rbr-ver-db-admin,rbr-ver-dev,rbr-po"
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
                      name: grafana-rbr-ver-oauth
                      key: client-secret
              volumeMounts:
                - name: authelia-ca
                  mountPath: /etc/ssl/authelia-ca
                  readOnly: true
                - name: shared-ssl-certs
                  mountPath: /etc/ssl/certs
