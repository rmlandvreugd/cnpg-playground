apiVersion: v1
kind: Service
metadata:
  name: authelia-backend
  namespace: authelia
spec:
  type: ExternalName
  externalName: authelia.${HOST_IP_DASHED}.sslip.io
  ports:
  - name: https
    port: ${AUTHELIA_PORT}
    targetPort: ${AUTHELIA_PORT}
---
apiVersion: traefik.io/v1alpha1
kind: ServersTransport
metadata:
  name: authelia-transport
  namespace: authelia
spec:
  insecureSkipVerify: true
