apiVersion: v1
kind: ConfigMap
metadata:
  name: pgadmin-servers
  namespace: pgadmin
data:
  servers.json: |
    {
      "Servers": {
        "1": {
          "Name": "pg-local (RW)",
          "Group": "CNPG Demo",
          "Host": "pg-local-rw.${CNPG_DEMO_NAMESPACE}.svc.cluster.local",
          "Port": 5432,
          "MaintenanceDB": "postgres",
          "Username": "postgres",
          "SSLMode": "prefer"
        },
        "2": {
          "Name": "pg-local (RO)",
          "Group": "CNPG Demo",
          "Host": "pg-local-ro.${CNPG_DEMO_NAMESPACE}.svc.cluster.local",
          "Port": 5432,
          "MaintenanceDB": "postgres",
          "Username": "postgres",
          "SSLMode": "prefer"
        }
      }
    }
