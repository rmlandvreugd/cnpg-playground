apiVersion: v1
kind: Service
metadata:
  name: revocation-exporter
  namespace: monitoring
  labels:
    app.kubernetes.io/name: revocation-exporter
spec:
  ports:
    - name: metrics
      port: 9105
      targetPort: 9105
---
apiVersion: v1
kind: Endpoints
metadata:
  name: revocation-exporter
  namespace: monitoring
subsets:
  - addresses:
      - ip: ${HOST_IP}
    ports:
      - name: metrics
        port: 9105
