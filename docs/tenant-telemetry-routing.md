# Per-tenant telemetry routing

Bead `bd3d.7`. The platform's observability config names no tenant: every tenant-dependent
block is generated from the live Capsule Tenant objects.

## Why generated

Loki, Mimir and Tempo are multi-tenant, and a tenant is identified by an **anchored name
prefix**: Capsule's `forceTenantPrefix` makes each tenant namespace start `<tenant>-`, and
Traefik names its routers/services after the *namespace*
(`<namespace>-<ingressroute>-<hash>@kubernetescrd`). Before this change the tenant `rbr`
appeared literally in five platform files, so onboarding a second tenant meant editing
platform config by hand.

Tenants stay an **explicit list**, never a generic `^([a-z0-9]+)-` capture: with a generic
capture a platform namespace would mint a Loki/Mimir tenant of its own name, and the
tenant's own platform-hosted Grafana route (`grafana-grafana-rbr-ver-...`) would be misfiled
to the tenant.

## How it works

Each template carries a marked region that the renderer replaces:

```
# >>> per-tenant: <block-name> (generated, see scripts/render-tenant-telemetry.py)
# <<< per-tenant
```

| Template | Block | What it produces |
|---|---|---|
| `monitoring/prometheus-instance/prometheus-cr.yaml.tpl` | `prometheus-remote-write` | one remoteWrite per tenant into its Mimir org |
| `monitoring/grafana/grafana_datasource_{loki,tempo,mimir_tempo}.yaml.tpl` | `grafana-org-header` | `X-Scope-OrgID: platform\|<tenants>` |
| `monitoring/otel-collector/otel-collector-values.yaml.tpl` | `otel-org-filters`, `otel-exporters`, `otel-pipelines` | whole-trace routing per tenant |
| `monitoring/alloy/alloy-config.river.tpl` | `alloy-traefik-tenant`, `alloy-events-tenant` | Traefik access logs and Kubernetes events |
| `monitoring/platform/traefik-servicemonitor.yaml.tpl` | `traefik-metric-relabelings` | `tenant=` on Traefik series |

Rendered output goes to `k8s/rendered/tenant-telemetry/` (gitignored).

```bash
scripts/tenant-telemetry.sh render local   # render only, print the directory
scripts/tenant-telemetry.sh apply  local   # render + apply (datasources, ServiceMonitor,
                                           # Prometheus CR, otel-collector, Alloy)
```

`monitoring/setup.sh` renders inline where it installs each component.
`demo/self-service-setup.sh` re-runs `apply` after creating the tenant namespaces, because
monitoring ran before the tenant existed — the same hook point as `scripts/netpol.sh`
(which already generated its per-tenant policies this way, see `docs/network-policy-allowlist.md`).

## Traces: whole-trace routing

Tenancy belongs to the request, not the span (`bd3d.9`). A request through `traefik-local`
produces entrypoint, `Metrics` and `ReverseProxy` spans with no tenant attribute, between the
tenant's `Router`/`Service` spans and its app's spans. So the collector does not route spans:

```
receivers → k8s_attributes → tail_sampling (THE sampling decision) → forward/orgs
                                                                        ├─ traces/platform: tail_sampling/platform → Tempo org platform
                                                                        └─ traces/<tenant>: tail_sampling/<tenant> → Tempo org <tenant>
```

- `tail_sampling/<tenant>` keeps a trace if **any** span has resource `capsule.tenant ==
  <tenant>` or `traefik.router.name` / `traefik.service.name` =~ `^<tenant>-` (anchored, so
  the platform-hosted `grafana-grafana-rbr-ver-*` stays platform).
- `tail_sampling/platform` is `always_sample` plus a `drop` policy for any tenant's trace.
  All tenants' conditions sit in **one** drop sub-policy: sub-policies are ANDed, so one per
  tenant would drop nothing (measured on collector 0.160.0).
- The org filters are 100% filters, never probabilistic: sampling happens once, upstream,
  so two orgs cannot disagree about a trace.
- The upstream sampler releases a trace's spans together, so the org filters wait only 2s;
  their decision cache routes spans that arrive later the same way as their trace.

Cost: about 2s more before spans reach Tempo, plus one small trace buffer per org. With no
tenant, `tail_sampling/platform` is a plain `always_sample`.

## Adding a tenant

Create the Capsule Tenant and its namespaces, then `scripts/tenant-telemetry.sh apply local`.
Nothing in `monitoring/` or `traefik/` needs editing. What still needs per-tenant work is the
tenant's *own* Grafana instance, datasources and dashboards (`demo/yaml/self-service/grafana/`)
and its identity/RBAC (Authelia groups, ArgoCD AppProjects) — that is tenant onboarding, not
platform routing.

## Note on the Traefik ServiceMonitor

It is deliberately **not** rendered by the Traefik chart. Regenerating it through the chart
would mean re-running `helm upgrade traefik` with its exact install-time `--set` flags on
every tenant change; a ServiceMonitor is a plain object that is simply re-applied. Its
selector must include `app.kubernetes.io/component: metrics` — without it the selector also
matches the main Traefik LoadBalancer Service and, since `targetPort` resolves by pod port
name, Prometheus scrapes the same pod twice under two job labels. `apply` also deletes the
chart-managed ServiceMonitor left behind on clusters installed before this change.
