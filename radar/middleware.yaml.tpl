apiVersion: traefik.io/v1alpha1
kind: Middleware
metadata:
  name: authelia-forwardauth
  namespace: radar
spec:
  forwardAuth:
    address: 'https://authelia.${HOST_IP_DASHED}.sslip.io:${AUTHELIA_PORT}/api/authz/forward-auth'
    tls:
      insecureSkipVerify: true
    authResponseHeaders:
      - Remote-User
      - Remote-Groups
      - Remote-Name
      - Remote-Email
