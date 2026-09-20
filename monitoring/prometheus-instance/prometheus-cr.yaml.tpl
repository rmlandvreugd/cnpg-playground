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
        - sourceLabels: [__name__]
          regex: '(up|scrape_.*|kube_.*|node_.*|kubelet_.*|apiserver_.*|cnpg_.*|pg_.*|traefik_.*)'
          action: keep
    # Per-tenant remoteWrite: each Capsule tenant's series into its own Mimir org (the
    # tenant's Grafana datasource reads that org). Generated — do not name a tenant here.
    # >>> per-tenant: prometheus-remote-write (generated, see scripts/render-tenant-telemetry.py)
    # <<< per-tenant
