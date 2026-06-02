apiVersion: v1
kind: Service
metadata:
  name: traefik-postgres
  namespace: traefik
spec:
  type: LoadBalancer
  loadBalancerIP: ${TRAEFIK_POSTGRES_IP}
  selector:
    app.kubernetes.io/instance: traefik-traefik
    app.kubernetes.io/name: traefik
  ports:
    - name: postgres
      port: 5432
      targetPort: postgres
      protocol: TCP