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
      # OIDC endpoints target the single hub in-cluster Authelia portal (fixed
      # across all regions — a regional Traefik IP has no Authelia portal). This
      # is the in-cluster portal, fronted by the edge; not the host-IP :9091
      # endpoint, which would strand the two-domain session split.
      auth_url: "https://authelia.${HUB_TRAEFIK_IP_DASHED}.sslip.io/api/oidc/authorization"
      token_url: "https://authelia.${HUB_TRAEFIK_IP_DASHED}.sslip.io/api/oidc/token"
      api_url: "https://authelia.${HUB_TRAEFIK_IP_DASHED}.sslip.io/api/oidc/userinfo"
      groups_attribute_path: "groups"
      # org_mapping matches its external-org field against org_attribute_path
      # (NOT groups_attribute_path). Without this, org_mapping gets an empty
      # org list, no entry matches, and every user falls back to the default
      # Viewer role. Point it at the same groups claim the mapping keys on.
      org_attribute_path: "groups"
      # Server-admin (isGrafanaAdmin=true) for the admin persona is granted via
      # role_attribute_path, NOT org_mapping: the GrafanaAdmin flag is derived
      # from extractRoleAndAdminOptional (role_attribute_path) — a "*" in the
      # org position of org_mapping does NOT set the server-admin flag. JMESPath
      # returns GrafanaAdmin (=> Admin in the default org + server admin) when
      # the user is in grafana-admin, else empty so org_mapping governs the rest
      # (role_attribute_strict=false lets the empty result fall through).
      role_attribute_path: "contains(groups, 'grafana-admin') && 'GrafanaAdmin' || ''"
      # This is the PLATFORM monitoring Grafana — admin persona only. Tenant
      # personas (rbr-admin, rbr-ver-*, rbr-po) get their Grafana on the tenant
      # instance grafana-rbr-ver, NOT here (per the persona matrix, their role is
      # scoped to the "rbr" tenant). No tenant groups are mapped on this instance.
      org_mapping: ""
      # Required or Grafana drops the GrafanaAdmin role and falls back to Viewer.
      allow_assign_grafana_admin: "true"
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
