# Bridge to the host RustFS container from the grafana namespace, so the
# seaweedfs-ab filer.backup sidecar can reach the loki-mirror bucket.
#
# Same manual Service+Endpoints pattern as monitoring/tempo and monitoring/mimir.
# The name MUST stay 'objectstore-local': the RustFS server cert carries
# DNS:objectstore-local as a bare SAN, and the sink dials
# https://objectstore-local:9000, so any other Service name would fail
# verification. (scripts/setup.sh also mints
# objectstore-local.grafana.svc.cluster.local, but only from the next cluster
# rebuild — the bare name is what makes this work today.)
apiVersion: v1
kind: Service
metadata:
  name: objectstore-local
  namespace: grafana
spec:
  ports:
    - name: s3
      port: 9000
      targetPort: 9000
---
apiVersion: v1
kind: Endpoints
metadata:
  name: objectstore-local
  namespace: grafana
subsets:
  - addresses:
      - ip: ${OBJECTSTORE_IP}
    ports:
      - name: s3
        port: 9000
