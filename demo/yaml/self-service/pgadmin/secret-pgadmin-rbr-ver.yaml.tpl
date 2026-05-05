apiVersion: v1
kind: Secret
metadata:
  name: pgadmin-rbr-ver-credentials
  namespace: pgadmin
stringData:
  email: ${PGADMIN_RBR_VER_EMAIL}
  password: ${PGADMIN_RBR_VER_PASSWORD}
