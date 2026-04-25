apiVersion: v1
kind: Service
metadata:
  name: vault
  namespace: vault
spec:
  ports:
    - name: api
      port: 8200
      targetPort: 8200
---
apiVersion: v1
kind: Endpoints
metadata:
  name: vault
  namespace: vault
subsets:
  - addresses:
      - ip: ${VAULT_IP}
    ports:
      - name: api
        port: 8200
