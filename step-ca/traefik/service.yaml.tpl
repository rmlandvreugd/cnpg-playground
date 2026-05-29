apiVersion: v1
kind: Service
metadata:
  name: step-ca
  namespace: step-ca
spec:
  ports:
    - name: https
      port: 8443
      targetPort: 8443
---
apiVersion: v1
kind: Endpoints
metadata:
  name: step-ca
  namespace: step-ca
subsets:
  - addresses:
      - ip: ${STEP_CA_IP}
    ports:
      - name: https
        port: 8443
