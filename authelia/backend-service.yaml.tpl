apiVersion: v1
kind: Service
metadata:
  name: authelia-backend
  namespace: authelia
spec:
  # In-cluster portal proxies to the EDGE Traefik (172.18.0.250), which routes
  # Host(authelia.${TRAEFIK_IP_DASHED}) on to the Authelia container. Port is the
  # edge websecure entrypoint (443), not Authelia's :9091.
  type: ExternalName
  externalName: authelia.${TRAEFIK_EDGE_IP_DASHED}.sslip.io
  ports:
  - name: https
    port: 443
    targetPort: 443
---
apiVersion: traefik.io/v1alpha1
kind: ServersTransport
metadata:
  name: authelia-transport
  namespace: authelia
spec:
  # Edge presents a step-ca cert for the edge SNI; skip verify on this hop.
  insecureSkipVerify: true
