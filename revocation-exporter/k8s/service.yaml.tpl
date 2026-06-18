apiVersion: v1
kind: Service
metadata:
  name: revocation-exporter
  namespace: prometheus-operator
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
  namespace: prometheus-operator
subsets:
  - addresses:
      - ip: ${HOST_IP}
    ports:
      - name: metrics
        port: 9105
