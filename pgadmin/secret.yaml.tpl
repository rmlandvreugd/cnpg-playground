apiVersion: v1
kind: Secret
metadata:
  name: pgadmin-credentials
  namespace: pgadmin
stringData:
  email: ${PGADMIN_EMAIL}
  password: ${PGADMIN_PASSWORD}
