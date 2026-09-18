apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: otel-push
  namespace: otel
spec:
  entryPoints: [web]
  routes:
    - match: Host(`otel-push.${TRAEFIK_IP_DASHED}.sslip.io`)
      kind: Rule
      services:
        - name: otel-collector-opentelemetry-collector
          port: 4318
