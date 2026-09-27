# Tenant-owned Grafana dashboards

Bead `bd3d.11`. A Capsule tenant owns its Grafana **dashboards**; the platform owns its
**datasources**.

| Object | Namespace | Owner | Delivered by |
|---|---|---|---|
| Tenant Grafana instance `grafana-rbr-ver` | `grafana` | platform | onboarding |
| Datasources (`loki-rbr-ver`, `tempo-rbr-ver`, ...) | `grafana` | platform | ArgoCD `grafana-rbr-ver`, project `rbr-grafana` (datasources only) |
| Dashboards | `rbr-ops` | **tenant** | ArgoCD `grafana-dashboards-rbr`, project `rbr` — or `kubectl` as tenant owner |

Datasources stay platform-owned because each one carries the tenant's `X-Scope-OrgID`:
a tenant who could edit one could point it at `platform` and read everything, undoing the
per-tenant log/metric/trace isolation (bd3d.1–3).

## Adding a dashboard

Put a `GrafanaDashboard` in `demo/yaml/self-service/rbr-ops/` (or `kubectl apply` it into
`rbr-ops` as a member of `oidc:rbr-db-admin`):

```yaml
apiVersion: grafana.integreatly.org/v1beta1
kind: GrafanaDashboard
metadata:
  name: my-dashboard
  namespace: rbr-ops
spec:
  allowCrossNamespaceImport: true          # the instance lives in namespace grafana
  instanceSelector:
    matchLabels:
      dashboards: grafana-rbr-ver           # exactly this, nothing else
  json: |
    { "title": "My dashboard", "uid": "my-dashboard", "panels": [] }
```

Query the tenant datasources by name/uid (`loki`, `tempo`, `mimir-tempo`, `DS_PROMETHEUS`).

## What is enforced, and where

The grafana-operator watches every namespace and acts with platform privileges, and ArgoCD
applies as its own privileged account — so RBAC alone cannot be the guard.
`manifests/kyverno/restrict-tenant-grafana-objects.yaml` (Enforce) applies to every
namespace with the `capsule.clastix.io/tenant` label, on every path:

- **Only `GrafanaDashboard`.** Every other `grafana.integreatly.org` kind is refused —
  notably `GrafanaDatasource` and `GrafanaServiceAccount` (which would mint an admin token
  into the tenant namespace).
- **Own instance only.** `instanceSelector` must be exactly
  `matchLabels: {dashboards: grafana-<tenant>-<env>}` — no extra labels, no
  `matchExpressions`, so it cannot reach the platform instance or another tenant's.
- **Inline content only.** `json`, `gzipJson` or `configMapRef`. `url`, `grafanaCom`, `oci`,
  `jsonnet`, `jsonnetLib`, `envs`/`envFrom`, `plugins` and `publicSharing` are refused: they
  make the platform operator fetch arbitrary URLs from inside the `grafana` namespace,
  evaluate code, install plugins or publish a dashboard without authentication.

RBAC is the outer layer: `capsule/clusterrole-tenant-grafana-dashboards.yaml`, bound through
the Tenant's `additionalRoleBindings`, grants dashboards only.

Network policy needs nothing extra: `rbr-ops` runs no pods (the operator reads dashboards
through the API server), and like every `rbr-*` namespace it is covered by the generated
per-tenant Calico policy and the Kyverno default NetworkPolicy, both selected by the tenant
label.

## Verified (2026-09-27)

- 16 attack/accept cases as cluster-admin with server dry-run (the ArgoCD-equivalent path).
- Live as the tenant owner in `rbr-ops`: own dashboard created and synced into the tenant
  Grafana; dashboard targeting the platform instance and a URL-fetching dashboard denied by
  Kyverno; datasource denied by RBAC.
- The three existing tenant dashboards moved from `grafana` to `rbr-ops`, appear in the
  tenant Grafana, and none in the platform Grafana. No denied flows during rollout.
