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
          regex: '(up|scrape_.*|kube_.*|node_.*|kubelet_.*|apiserver_.*|cnpg_.*|pg_.*)'
          action: keep
    # Capsule tenant rbr: its namespaces' series only, into Mimir org "rbr" (the tenant
    # Grafana datasource reads that org). Capsule forces the rbr- prefix on the tenant.
    - url: ${MIMIR_PUSH_URL}
      headers:
        X-Scope-OrgID: rbr
      writeRelabelConfigs:
        - sourceLabels: [namespace]
          regex: 'rbr-.+'
          action: keep
