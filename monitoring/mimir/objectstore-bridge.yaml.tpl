apiVersion: v1
kind: Service
metadata:
  name: objectstore-local
  namespace: mimir
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
  namespace: mimir
subsets:
  - addresses:
      - ip: ${OBJECTSTORE_IP}
    ports:
      - name: s3
        port: 9000
