# Loki-B (in-cluster SeaweedFS) — PLATFORM org datasource only.
#
# Deliberately no tenant-Grafana counterpart: the A/B arms exist to be compared
# by the platform during the storage PoC. A tenant sees only arm C (uid loki),
# so the PoC is invisible to tenants and can be torn down without touching them.
#
# The X-Scope-OrgID header still lists platform plus every Capsule tenant, so
# the platform view of arm B matches its view of arm C line-for-line — otherwise
# the parity gate (equal bytes across all three) would compare different data.
apiVersion: grafana.integreatly.org/v1beta1
kind: GrafanaDatasource
metadata:
  name: loki-seaweedfs
  namespace: grafana
spec:
  instanceSelector:
    matchLabels:
      dashboards: grafana
  allowCrossNamespaceImport: true
  datasource:
    name: DS_LOKI_SEAWEEDFS
    uid: loki-seaweedfs
    type: loki
    access: proxy
    url: http://loki-seaweedfs.grafana.svc.cluster.local:3100
    jsonData:
      tlsSkipVerify: true
      httpHeaderName1: X-Scope-OrgID
      derivedFields:
        - matcherRegex: '"traceID":"(\w+)"'
          name: TraceID
          url: '${__value.raw}'
          datasourceUid: tempo
    secureJsonData:
      # >>> per-tenant: grafana-org-header (generated, see scripts/render-tenant-telemetry.py)
      # <<< per-tenant
