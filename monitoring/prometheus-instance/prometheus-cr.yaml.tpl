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
    # Capsule tenant rbr: its namespaces' series only, into Mimir org "rbr" (the tenant
    # Grafana datasource reads that org). Capsule forces the rbr- prefix on the tenant.
    - url: ${MIMIR_PUSH_URL}
      headers:
        X-Scope-OrgID: rbr
      writeRelabelConfigs:
        # Either the series comes from a tenant namespace, or it is a Traefik series the
        # ServiceMonitor tagged tenant="rbr" (those live in namespace "traefik", bd3d.10).
        # One keep with a combined regex: separate keeps would AND, not OR.
        - sourceLabels: [namespace, tenant]
          separator: ';'
          regex: '(rbr-.+;.*|.*;rbr)'
          action: keep
