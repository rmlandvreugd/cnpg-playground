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

Metrics and log lines with no router or service — entry-point metrics, 404s, redirects —
stay platform: they aggregate across tenants. Traces are different: a trace goes to the
tenant whole, entrypoint span included, as soon as one of its spans is the tenant's
(`bd3d.9`, below).

## The three signals

| Signal | Where | Tenant split |
|---|---|---|
| Access logs | `monitoring/alloy/alloy-config.river`, `loki.process "traefik_access"` | `stage.regex` on the line's `ServiceName`; `stage.labels` sets `tenant`, which `loki.process "tenant"` turns into the Loki `X-Scope-OrgID` |
| Traces | `traefik/values.yaml` + `monitoring/otel-collector/otel-collector-values.yaml.tpl` | per-org `tail_sampling/<org>` trace filter: the whole trace goes to the tenant if any span has `traefik.router.name` / `traefik.service.name` =~ `^<tenant>-` (or comes from a tenant namespace) |
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

Because all Traefik spans share the platform pod's resource, only the `Router` and
`Service` spans name the tenant; the entrypoint, `Metrics` middleware and `ReverseProxy`
spans carry nothing tenant-specific, yet sit between them and the app's spans. Routing span
by span (the original `bd3d.10` design) therefore left the tenant three orphan fragments with
no root. Since `bd3d.9` the collector routes **whole traces**: every sampled trace is fanned
out to one pipeline per Tempo org, and each org keeps or drops it as a unit — see
[Tenant telemetry routing](tenant-telemetry-routing.md#traces-whole-trace-routing). The
tenant sees its requests end to end, the platform org no longer stores them, and the platform
Grafana (`platform|rbr`) still shows them complete.

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
