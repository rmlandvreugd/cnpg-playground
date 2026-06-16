---
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: demo
  namespace: demo-db
spec:
  instances: 3
  imageName: ghcr.io/cloudnative-pg/postgresql:18-standard-trixie

  storage:
    size: 1Gi
  walStorage:
    size: 1Gi

  affinity:
    nodeSelector:
      node-role.kubernetes.io/postgres: ""
    tolerations:
    - key: node-role.kubernetes.io/postgres
      operator: Exists
      effect: NoSchedule
    enablePodAntiAffinity: true
    topologyKey: kubernetes.io/hostname
    podAntiAffinityType: required

  enableSuperuserAccess: true
  superuserSecret:
    name: demo-superuser

  bootstrap:
    initdb:
      dataChecksums: true
      database: demo
      owner: app
      secret:
        name: demo-app
      postInitSQL:
        - CREATE ROLE readonly LOGIN;
        - GRANT SELECT ON ALL TABLES IN SCHEMA public TO readonly;

  managed:
    roles:
    - name: app
      ensure: present
      login: true
      inherit: true
      connectionLimit: -1
      passwordSecret:
        name: demo-app
    - name: readonly
      ensure: present
      login: true
      inherit: true
      connectionLimit: -1
      passwordSecret:
        name: demo-readonly

  postgresql:
    parameters:
      max_connections: '100'
      log_checkpoints: 'on'
      log_lock_waits: 'on'
      pg_stat_statements.max: '10000'
      pg_stat_statements.track: 'all'
      hot_standby_feedback: 'on'
      shared_memory_type: 'sysv'
      dynamic_shared_memory_type: 'sysv'
      pgaudit.log: 'ddl,role,misc_set'
      pgaudit.log_catalog: 'off'
      pgaudit.log_relation: 'on'

  monitoring:
    enablePodMonitor: false
    disableDefaultQueries: false
    customQueriesConfigMap:
      - key: queries
        name: cnpg-default-monitoring

  certificates:
    serverAltDNSNames:
      - demo-demo-db.${TRAEFIK_IP_DASHED}.sslip.io

  plugins:
  - name: barman-cloud.cloudnative-pg.io
    isWALArchiver: true
    parameters:
      barmanObjectName: objectstore-demo
      serverName: demo
---
apiVersion: postgresql.cnpg.io/v1
kind: Pooler
metadata:
  name: pooler-demo-rw
  namespace: demo-db
spec:
  cluster:
    name: demo
  instances: 2
  type: rw
  pgbouncer:
    poolMode: session
    parameters:
      max_client_conn: "1000"
      default_pool_size: "10"
      # The app pins its schema via asyncpg's search_path startup parameter
      # (see app db/session.py). PgBouncer rejects unknown startup parameters
      # by default; allow it here so the param is forwarded to PostgreSQL.
      ignore_startup_parameters: "search_path"
