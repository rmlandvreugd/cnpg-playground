apiVersion: v1
kind: ConfigMap
metadata:
  name: pgadmin-rbr-ver-servers
  namespace: pgadmin
data:
  servers.json: |
    {
      "Servers": {
        "1": {
          "Name": "verstappen (rbr-ver-db)",
          "Group": "rbr-ver",
          "Host": "verstappen-rbr-ver-db.${TRAEFIK_IP_DASHED}.sslip.io",
          "Port": 5432,
          "MaintenanceDB": "max",
          "SSLMode": "require",
          "Username": "app"
        }
      }
    }
