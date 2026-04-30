apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: pg-local
  namespace: ${CNPG_DEMO_NAMESPACE}
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
    name: pg-local-superuser

  bootstrap:
    initdb:
      dataChecksums: true
      database: app
      owner: app
      secret:
        name: pg-local-app
      postInitApplicationSQL:
        - CREATE ROLE readonly LOGIN
        - GRANT CONNECT ON DATABASE app TO readonly
        - GRANT USAGE ON SCHEMA public TO readonly
        - GRANT SELECT ON ALL TABLES IN SCHEMA public TO readonly
        - ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT ON TABLES TO readonly

  managed:
    roles:
    - name: app
      ensure: present
      login: true
      inherit: true
      connectionLimit: -1
      passwordSecret:
        name: pg-local-app
    - name: readonly
      ensure: present
      login: true
      inherit: true
      connectionLimit: -1
      passwordSecret:
        name: pg-local-readonly

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
---
apiVersion: postgresql.cnpg.io/v1
kind: Pooler
metadata:
  name: pooler-local-rw
  namespace: ${CNPG_DEMO_NAMESPACE}
spec:
  cluster:
    name: pg-local
  instances: 2
  type: rw
  pgbouncer:
    poolMode: session
    parameters:
      max_client_conn: "1000"
      default_pool_size: "10"
