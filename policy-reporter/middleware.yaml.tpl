apiVersion: traefik.io/v1alpha1
kind: Middleware
metadata:
  name: authelia-forwardauth
  namespace: policy-reporter
spec:
  forwardAuth:
    # In-cluster portal (via edge). Host must match the in-cluster cookie domain
    # so Authelia resolves the right session cookie + authelia_url for the redirect.
    address: 'https://authelia.${TRAEFIK_IP_DASHED}.sslip.io/api/authz/forward-auth'
    tls:
      insecureSkipVerify: true
    authResponseHeaders:
      - Remote-User
      - Remote-Groups
      - Remote-Name
      - Remote-Email
