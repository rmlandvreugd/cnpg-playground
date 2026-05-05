---
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: verstappen
  namespace: rbr-ver-db
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
    name: verstappen-superuser

  bootstrap:
    initdb:
      dataChecksums: true
      database: max
      owner: app
      secret:
        name: verstappen-app

  managed:
    roles:
    - name: app
      ensure: present
      login: true
      inherit: true
      connectionLimit: -1
      passwordSecret:
        name: verstappen-app
    - name: readonly
      ensure: present
      login: true
      inherit: true
      connectionLimit: -1
      passwordSecret:
        name: verstappen-readonly

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

  certificates:
    serverAltDNSNames:
      - verstappen-rbr-ver-db.${TRAEFIK_IP_DASHED}.sslip.io

  plugins:
  - name: barman-cloud.cloudnative-pg.io
    isWALArchiver: true
    parameters:
      barmanObjectName: objectstore-rbr-ver
      serverName: verstappen
---
apiVersion: postgresql.cnpg.io/v1
kind: Pooler
metadata:
  name: pooler-verstappen-rw
  namespace: rbr-ver-db
spec:
  cluster:
    name: verstappen
  instances: 2
  type: rw
  pgbouncer:
    poolMode: session
    parameters:
      max_client_conn: "1000"
      default_pool_size: "10"
---
# See https://cloudnative-pg.io/documentation/current/backup/#scheduled-backups
apiVersion: postgresql.cnpg.io/v1
kind: ScheduledBackup
metadata:
  name: verstappen-backup
  namespace: rbr-ver-db
spec:
  method: plugin
  schedule: '0 0 0 * * *'
  backupOwnerReference: self
  cluster:
    name: verstappen
  pluginConfiguration:
    name: barman-cloud.cloudnative-pg.io
  immediate: true
