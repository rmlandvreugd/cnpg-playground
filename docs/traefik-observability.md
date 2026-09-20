# In-cluster Traefik observability (platform vs tenant)

Bead `bd3d.10`. Access logs, traces and metrics for `traefik-local`, each split so the
platform sees every request and a Capsule tenant sees only requests routed to its own
IngressRoutes.

## How a request is attributed to a tenant

The Traefik pod runs in the platform namespace `traefik`, so its own namespace says nothing
about tenancy. The only per-request signal is the router/service name, which Traefik renders
as `<namespace>-<ingressroute>-<hash>@kubernetescrd`, e.g.
`rbr-ver-demo-app-adca40d2faf2d9248807@kubernetescrd`. Capsule's `forceTenantPrefix` makes
every tenant namespace start with `<tenant>-`, so an **anchored** `^rbr-` match identifies the
tenant.

Anchoring is not optional: the tenant's own Grafana is
`grafana-grafana-rbr-ver-...@kubernetescrd` — namespace `grafana`, platform-hosted — and an
unanchored `rbr` match would hand it to the tenant. Tenants are listed explicitly rather than
captured with a generic `^([a-z0-9]+)-`, so a platform namespace can never mint a tenant
(`bd3d.7` will generate the list from the Capsule Tenants).

Data with no router or service — entry-point metrics, 404s, redirects, the EntryPoint span —
stays platform: it aggregates across tenants.

## The three signals

| Signal | Where | Tenant split |
|---|---|---|
| Access logs | `monitoring/alloy/alloy-config.river`, `loki.process "traefik_access"` | `stage.regex` on the line's `ServiceName`; `stage.labels` sets `tenant`, which `loki.process "tenant"` turns into the Loki `X-Scope-OrgID` |
| Traces | `traefik/values.yaml` + `monitoring/otel-collector/otel-collector-values.yaml` | routing connector entry with `context: span` on `traefik.router.name` / `traefik.service.name` |
| Metrics | `traefik/values.yaml` (`metrics.prometheus`) + `monitoring/prometheus-instance/prometheus-cr.yaml.tpl` | ServiceMonitor `metricRelabelings` derive `tenant=`; the tenant remoteWrite keeps by namespace **or** that label |

### Traces needed two fixes

1. **Transport.** Traefik pointed at the collector's `:4317`, which is mTLS
   (`client_ca_file`), and sent plaintext without a client certificate. Every span was
   dropped and Tempo held no `traefik-local` traces at all. It now uses `:4319`, the
   plaintext in-cluster receiver.
2. **Verbosity.** `traceVerbosity` (v3.5+) defaults to `minimal`, which emits only a server
   span named after the method and a `ReverseProxy` client span — neither names the router.
   The internal `Router` and `Service` spans that carry `traefik.router.name` and
   `traefik.service.name` require `detailed`, set per entrypoint in `traefik/values.yaml`.
   A tenant can turn it down per route with `spec.routes[].observability.traceVerbosity`.

Because all Traefik spans share the platform pod's resource, routing happens in span context.
With move semantics the tenant's `Router`/`Service` spans go to the tenant's Tempo org while
the entrypoint and `ReverseProxy` spans stay platform — the platform Grafana reads
`platform|rbr`, so an admin still sees the whole trace, and the tenant sees a partial one
(`bd3d.9`).

### Metrics gotcha

Traefik's own `service` label collides with the ServiceMonitor's target label, so Prometheus
renames it to `exported_service` — the relabeling matches on that, not on `service`. Also,
the platform remoteWrite keeps an allow-list of metric names; `traefik_*` had to be added or
nothing reached Mimir.

## Verified (2026-09-20)

| | Tenant Grafana (rbr) | Platform Grafana |
|---|---|---|
| Traefik routers in metrics | `rbr-ver-demo-app-…` only | all 6, incl. `grafana-grafana-rbr-ver-…`, `authelia@file`, `vault@file`, `zot@file` |
| Traefik access-log routes | `rbr-ver-demo-app-…` only | all 3 in-cluster routes |
| Traefik spans | `Router` + `Service` for its own route | entrypoint, `ReverseProxy`, middleware spans, plus the tenant's via `platform|rbr` |
| Entry-point series | none | all |

Span metrics follow: Mimir org `rbr` has `traces_spanmetrics_calls_total{service="traefik-local"}`
for the tenant's route only, which is what the tenant's Traefik RED dashboard uses.
