apiVersion: monitoring.coreos.com/v1
kind: Prometheus
metadata:
  name: prometheus
  namespace: prometheus-operator
spec:
  serviceAccountName: prometheus
  podMonitorSelector: {}
  podMonitorNamespaceSelector: {}
  serviceMonitorSelector: {}
  serviceMonitorNamespaceSelector: {}
  ruleSelector: {}
  ruleNamespaceSelector: {}
  probeSelector: {}
  probeNamespaceSelector: {}
  externalLabels:
    cluster: "${REGION}"
  nodeSelector:
    node-role.kubernetes.io/infra: ""
  remoteWrite:
    - url: ${MIMIR_PUSH_URL}
      headers:
        X-Scope-OrgID: ${REGION}
      writeRelabelConfigs:
        # Allow-list into long-term storage. Anything absent here exists ONLY in
        # Prometheus, whose retention is the operator default of 24h — so a
        # metric missing from this regex cannot be queried over a multi-day
        # window even though it is scraped and visible "now".
        #
        # loki_.* and SeaweedFS_.* are required by the A/B/C storage benchmark
        # (bead t9p7.3), whose soak runs >=26h and therefore outlives Prometheus.
        # The two container_* series are the resource-cost verdict panel; the
        # rest of cadvisor is deliberately NOT forwarded, as its cardinality
        # would dwarf everything else here for no benefit.
        - sourceLabels: [__name__]
          regex: '(up|scrape_.*|kube_.*|node_.*|kubelet_.*|apiserver_.*|cnpg_.*|pg_.*|traefik_.*|loki_.*|SeaweedFS_.*|container_cpu_usage_seconds_total|container_memory_working_set_bytes)'
          action: keep
    # Per-tenant remoteWrite: each Capsule tenant's series into its own Mimir org (the
    # tenant's Grafana datasource reads that org). Generated — do not name a tenant here.
    # >>> per-tenant: prometheus-remote-write (generated, see scripts/render-tenant-telemetry.py)
    # <<< per-tenant
