# External edge Traefik for host services

Status: planned 2026-06-29. Epic (`cnpg-playground-5sq`); folds in `cnpg-playground-yt4`
(SeaweedFS admin-UI auth).

> **Rollout model — clean rebuild.** This plan is executed against a **freshly destroyed +
> rebuilt** cluster (`teardown.sh` → `setup.sh`), not migrated in place. That collapses the
> OIDC "re-bootstrap" cost: there is no live trust to migrate — a single `setup.sh` run
> renders every hostname/issuer from the new tokens and bootstraps the new trust from
> scratch. The work below is therefore mostly **templating + correct `setup.sh` ordering**,
> not stateful migration.

## Context

Several services run as **host Docker containers** (not in kind): `vault` (:8200),
`authelia` (:9091), `step-ca` (:8443), `seaweedfs` S3/filer/master (:8333/:8889/:9333),
`seaweedfs-admin` (:23646, HTTPS), `seaweedfs-webdav/worker`, `rustfs`.

Today each is joined to the `kind` network and fronted **by the in-cluster Traefik** via a
per-service Service/Endpoints (or ExternalName) + IngressRoute + cert-manager Certificate
at `*.sslip.io` (e.g. `vault/traefik/service.yaml.tpl`, `authelia/ingressroute.yaml.tpl`,
`step-ca/traefik/service.yaml.tpl`, `seaweedfs/traefik/`). This couples host-service edge
routing to the cluster, scatters wiring across many template dirs, and leaves the SeaweedFS
admin UI without SSO (OSS `weed admin` has no OIDC path — `auth_middleware.go` only checks
`-adminUser`/`-adminPassword`).

**Goal:** introduce a standalone **external Traefik** reverse-proxy (host container) as the
single front for these host services, owning TLS termination, Authelia forward-auth, and
observability. The in-cluster Traefik keeps only in-cluster apps.

## Decisions

- **Routing model — Replace.** The external Traefik replaces in-cluster routing for
  `vault`, `authelia`, `seaweedfs` (S3), `seaweedfs-admin`. (`rustfs` descoped — stays
  in-cluster-fronted this pass.) Backends **stay on the `kind` network**. Each container's
  published host port stays for direct debug/break-glass access.
- **Responsibilities — TLS + forward-auth + observability.** Terminate TLS at the edge
  (step-ca / vault-pki certs on the host filesystem), centralize human-facing SSO via
  Authelia forward-auth, and export metrics + traces to the in-cluster observability stack.
- **yt4 folded in.** The admin-UI forward-auth is implemented on this external Traefik.
  Admin-UI policy: `one_factor` + group `seaweedfs-admin`/`admin`.
- **Authelia moves to the edge (confirmed).** Authelia is fronted by the external edge, so
  its OIDC issuer becomes `https://authelia.172-18-0-250.sslip.io`. Because issuer is pinned
  in every OIDC client, this forces a **full re-bootstrap of OIDC trust** — but the clean
  rebuild makes that a fresh `setup.sh` bootstrap, not a live migration. (Considered keeping
  Authelia in-cluster-fronted like step-ca for issuer stability; rejected in favour of full
  decoupling from the cluster.)
- **Two Authelia session cookie domains.** Moving some surfaces to `172-18-0-250.sslip.io`
  while others (grafana, argocd, gangplank, kubernetes) stay on `172-18-255-200.sslip.io`
  splits the cookie scope. Authelia must register **both** as session cookie domains (use the
  existing `authelia/config/configuration-two-domains.yaml.tpl` scaffolding). SSO works via the
  portal; a user re-authenticates once per domain on first hit. Acceptable for the playground.
- **Observability addressing — shared `ext-svc-lb` LoadBalancer.** The edge cannot reach a
  ClusterIP from a host container. A single reusable LB IP **`172.18.255.240`** (named
  `ext-svc-lb`) carries all o11y ingest from the edge (and any future external→cluster o11y
  traffic). It is pinned + made shareable with the repo's annotation namespace:
  `metallb.universe.tf/loadBalancerIPs: 172.18.255.240` and
  `metallb.universe.tf/allow-shared-ip: ext-svc-lb` (constraints: non-overlapping ports +
  `externalTrafficPolicy: Cluster` across all sharing Services). `.240` is inside `kind-pool`
  (`.200–.250`), so MetalLB allocates it — distinct mechanism from the edge's Docker static IP
  `172.18.0.250`. First consumer: a `LoadBalancer` Service in front of the OTel collector
  (gRPC :4317 / HTTP :4318). The edge exports **traces and logs** to `172.18.255.240:4317`.
- **Edge → collector hop is gated with mTLS** (step-ca client cert), since the LB exposes an
  otherwise-unauthenticated OTLP ingest endpoint. The edge gets a client cert from step-ca;
  the collector OTLP receiver requires + verifies it (`tls.client_ca_file` + `cert/key`).
- **Edge logs → Loki via OTLP (new pipeline).** Edge ships **both access logs and Traefik app
  logs** over OTLP (`experimental.otlpLogs: true`, `accesslog.otlp.grpc` + `log.otlp.grpc`),
  with `accesslog.dualOutput: true` so `docker logs traefik-edge` still works for break-glass.
  This requires **new infra**: (a) a `logs` pipeline + `otlphttp/logs` exporter on the OTel
  collector → Loki's `/otlp` endpoint; (b) enabling OTLP ingestion on Loki. Today the collector
  has only `traces→Tempo` and Loki's OTLP path is off.
- **Edge TLS — per-service multi-SAN certs.** Mirror the existing per-service `step ca
  certificate` (x5c provisioner) pattern; one cert per backend hostname under
  `*.172-18-0-250.sslip.io` (no wildcard dependency).
- **Metrics scrape uses a selector-less Service + manual Endpoints** at `172.18.0.250:<metrics
  port>` + ServiceMonitor (the calico ServiceMonitor uses a pod selector, which does not apply
  to a non-pod host target). Human-facing o11y UIs (Grafana) stay on the in-cluster Traefik.
- **rustfs descoped from this pass.** Only vault, authelia, and seaweedfs (S3 + admin) move
  behind the edge now; rustfs keeps its current in-cluster route + static kind IP, revisited
  later.
- **Dynamic config via file provider.** Traefik file provider watching a config directory
  (`watch: true`); setup drops one dynamic config file per backend ("triggers on files
  placed in the config folder").
- **Addressing — one pinned IP, on the `kind` network.** Only the **edge** gets a static
  IP, and it must be on the **`kind`** network (`172.18.0.0/16`) — the cluster lives there
  and cannot route to the default `bridge` (`172.17.0.0/16`). Reserve a slot **below** the
  MetalLB pool and clear of node/host-container IPs and Docker's dynamic range — target
  `172.18.0.250`. **Confirmed clear:** the only MetalLB pool is `kind-pool`
  = `172.18.255.200-172.18.255.250` (top of the /16); Docker IPAM allocates sequentially from
  the low end (nodes `.0.2-.0.9`, host containers `.0.10-.0.13`, current high-water `.0.13`),
  so `.0.250` is unused and far from both. Re-confirm at build. The edge's IP is what gets encoded into every
  `*.sslip.io` hostname (and thus OIDC issuer URLs + S3 endpoints), so it must be
  restart-stable. **Backends are NOT pinned** — on the user-defined `kind` network Docker's
  embedded DNS resolves them by container name (`http://vault:8200`,
  `https://seaweedfs-admin:23646`), so the edge routes by name. Note: the default `bridge`
  network rejects `--ip` anyway (*"supported only when connecting to networks with user
  configured subnets"*), so static IPs there are not an option. **Network audit (corrected):**
  `authelia` is already `network connect kind`'d in `setup.sh` (~L549-551); `rustfs`/objectstore
  already joins kind with a static IP. Only **`seaweedfs-admin`** is bridge-only today and must
  be `network connect kind`'d as part of this work.
- **step-ca stays in-cluster-fronted, out of the edge.** step-ca is the trust anchor that
  issues the edge's own TLS cert (`step ca certificate …`); putting it behind the edge
  creates a bootstrap cycle (edge needs a cert to start → must reach step-ca → through the
  edge that isn't up). It's a machine ACME/API endpoint (no browser, no forward-auth value;
  re-terminating TLS would fight ACME identity). It keeps its existing in-cluster Traefik
  IngressRoute at `step-ca.<in-cluster-LB>.sslip.io`, so cert-manager's ClusterIssuer ACME
  URL is unchanged and needs no re-bootstrap. step-ca (and `rustfs`, descoped this pass) stay
  routed by the in-cluster Traefik; vault/authelia/seaweedfs move to the edge.

## Architecture

```
                       *.sslip.io  (host = external-traefik IP)
   in-cluster pods ─┐
                    ├─►  EXTERNAL TRAEFIK (host container, on `kind` net)
   external users ──┘     • entrypoints web:80→443, websecure:443, +metrics
                          • file provider (watch=true) on a mounted config dir
                          • TLS termination (step-ca / vault-pki certs on host FS)
                          • forward-auth middleware → Authelia (human surfaces only)
                          • OTLP traces + access/app logs (mTLS) + Prometheus metrics
                                 │ routes by Host/SNI to kind-IP backends
            ┌──────────────┬─────┴────────┬───────────────┐
          vault         authelia       seaweedfs        seaweed-
        (:8200)         (:9091)        S3 (:8333)        admin
                                                        (:23646)
        (all backends remain on the kind network; host ports still published)
        (rustfs descoped this pass — stays in-cluster-fronted)
```

**Forward-auth selectivity (critical):** attach the forward-auth middleware only to
**human/browser** surfaces — the `seaweedfs-admin` UI. Do **not** forward-auth machine/API
surfaces: the `authelia` route itself (would create an auth loop), `vault` API, `seaweedfs`
S3 API — these authenticate with their own tokens / access keys / OIDC-STS.

## Work breakdown (reuse existing patterns)

1. **External Traefik container — new `traefik-edge/`.** Static `traefik.yaml` (entrypoints,
   file provider `directory: /etc/traefik/dynamic` `watch: true`, `metrics.prometheus`,
   `tracing.otlp`), plus a `dynamic/` dir populated at setup. Run block in
   `scripts/setup.sh` mirrors the seaweedfs-admin run block (`scripts/setup.sh` ~L498-528);
   `--network kind --ip 172.18.0.250` (the one pinned IP — confirm free); mount config + cert
   dirs; publish
   :443/:80. Add `TRAEFIK_EDGE_*` vars to `scripts/common.sh` (incl. `TRAEFIK_EDGE_IP` /
   `TRAEFIK_EDGE_IP_DASHED`) following the `SEAWEEDFS_ADMIN_*`/`AUTHELIA_*` var conventions.
   `network connect kind` the one bridge-only backend (`seaweedfs-admin`); `authelia` and
   `rustfs` are already kind-connected.
2. **Per-service dynamic config** dropped into the watched dir: router (Host rule + TLS +
   optional forward-auth) + service (loadBalancer to the backend **by container name** via
   `kind` embedded DNS, e.g. `https://seaweedfs-admin:23646` — no IP inspection needed);
   `serversTransport.insecureSkipVerify` for HTTPS backends — mirror
   `capsule-proxy/serverstransport.yaml`.
3. **Host TLS certs** via the established pattern (`scripts/authelia-setup.sh`,
   `scripts/vault-setup.sh`): `step ca certificate "<host>" cert.pem key.pem` →
   `docker cp` out → into `traefik-edge/certs/` (gitignored). Reference in a dynamic `tls`
   block.
4. **Cluster-side replace (templating).** Add a `TRAEFIK_EDGE_IP` / `TRAEFIK_EDGE_IP_DASHED`
   token to `scripts/common.sh`. Service hostnames for vault/authelia/seaweedfs become
   `*.${TRAEFIK_EDGE_IP_DASHED}.sslip.io`; everything else keeps `${TRAEFIK_IP_DASHED}`
   (in-cluster LB). Retire the in-cluster IngressRoutes + per-service Services/Certs for the
   moved services (vault, authelia, seaweedfs S3 + admin); **step-ca and rustfs keep their
   in-cluster routes unchanged**. Audit `*.sslip.io`
   references across `authelia/`, `vault*`, `seaweedfs/config/`, `scripts/*.sh`, `monitoring/`,
   `demo/` and switch only the four moved services + Authelia issuer to the edge token.

4b. **OIDC re-bootstrap (fresh, via `setup.sh`).** Authelia's issuer becomes
   `https://authelia.${TRAEFIK_EDGE_IP_DASHED}.sslip.io`; every OIDC client's issuer/redirect
   must reference it. On the clean rebuild this is template-render + ordered bootstrap, no live
   migration:
   - **kube-apiserver** structured authn (`k8s/authn-config.yaml.tpl`) — re-render issuer; the
     apiserver must resolve the new issuer for discovery (reachable on the kind net). Highest-
     risk surface; verify OIDC login post-build (kubeconfig cert auth is the fallback).
   - **vault** (`scripts/vault-oidc-setup.sh`) — `oidc_discovery_url` + redirect to edge issuer;
     vault's own UI/redirect host also moves to the edge.
   - **grafana ×2**, **argocd**, **gangplank** — issuer/auth/token URLs re-rendered. (Grafana
     retains its known quirks: CA init-container injection, `GF_`-prefixed client secret,
     `role_attribute_strict: false`.)
   - **step-ca OIDC provisioner** — step-ca stays in-cluster but **trusts Authelia**, so its
     provisioner issuer must point at the edge issuer.
   - **seaweedfs-s3** STS/OIDC issuer trust → edge issuer; S3 endpoint host also moves.
   - **seaweedfs-admin** — delete the now-dead Authelia OIDC client + the
     `AUTHELIA_SEAWEEDFS_ADMIN_CLIENT_SECRET[_HASH]` vars (replaced by forward-auth).
   - **Session cookie domains** — switch Authelia to the two-domain config registering both
     `${TRAEFIK_IP_DASHED}.sslip.io` and `${TRAEFIK_EDGE_IP_DASHED}.sslip.io`.
   - Data-plane S3 endpoint consumers — CNPG barman ObjectStore, Loki storage, ESO — re-point
     to the edge S3 host.
   - **`setup.sh` ordering:** step-ca (in-cluster) up → edge cert + Authelia cert issued → edge
     container + Authelia up → kube-apiserver authn applied → vault/seaweedfs STS OIDC bootstrap
     → grafana/argocd/gangplank/step-ca-provisioner render. No bootstrap cycle exists because
     step-ca is excluded from the edge.
5. **Authelia forward-auth.** Ensure
   `server.endpoints.authz.forward-auth.implementation: ForwardAuth`; add the
   seaweedfs-admin `access_control` rule (one_factor + group restrict). Edge middleware
   `forwardAuth.address: https://authelia.<edge-ip>.sslip.io/api/authz/forward-auth` with
   `authResponseHeaders: [Remote-User,Remote-Groups,Remote-Name,Remote-Email]`. Remove the
   dead `AUTHELIA_SEAWEEDFS_ADMIN_CLIENT_SECRET` (`scripts/common.sh`).
6. **Observability.**
   - **Metrics** — `metrics.prometheus` on the edge, scraped via a **selector-less Service +
     manual Endpoints** at `172.18.0.250:<metricsport>` + a ServiceMonitor (the calico
     ServiceMonitor uses a pod selector, inapplicable to a host target; reuse the Service/
     ServiceMonitor *shape* from `monitoring/platform/calico-*`). No LB needed — Prometheus pods
     reach the edge kind IP directly.
   - **`ext-svc-lb` shared LoadBalancer** — new `LoadBalancer` Service for the OTel collector,
     `metallb.universe.tf/loadBalancerIPs: 172.18.255.240` +
     `metallb.universe.tf/allow-shared-ip: ext-svc-lb`, `externalTrafficPolicy: Cluster`, ports
     4317(grpc)/4318(http) → `otel-collector-opentelemetry-collector.otel` (real helm service
     name, per the known service-name fix).
   - **Traces** — `tracing.otlp.grpc.endpoint: 172.18.255.240:4317` on the edge (mTLS client
     cert).
   - **Logs (new pipeline)** — edge `experimental.otlpLogs: true`, `accesslog.otlp.grpc` +
     `log.otlp.grpc` → `172.18.255.240:4317` (mTLS), `accesslog.dualOutput: true`. Add to
     `monitoring/otel-collector/otel-collector-values.yaml` a `logs` pipeline + `otlphttp/logs`
     exporter → Loki `/otlp`; enable OTLP ingestion in `monitoring/loki/loki-values.yaml`
     (`allow_structured_metadata` already true). Decide which resource attrs become Loki stream
     labels (e.g. `service.name=traefik-edge`) to bound cardinality.
   - **mTLS** — issue an edge OTLP client cert from step-ca; collector OTLP receiver requires +
     verifies it.
   - Optional Traefik GrafanaDashboard (same pattern as the kyverno/argocd dashboards).
7. **yt4 admin UI.** Dynamic file routing `seaweedfs-admin.<edge-ip>.sslip.io` →
   admin `:23646` (https, insecureSkipVerify) + forward-auth. Keep `-adminUser/-adminPassword`.
8. **Teardown + docs.** `scripts/teardown.sh` stops/removes the edge container (check-and-remove
   pattern ~L105-154) + retired resources; update `docs/architecture-overview.md` once built
   (it documents current state — do **not** add the edge there until it exists).

## Files touched (representative)

- **New:** `traefik-edge/traefik.yaml`, `traefik-edge/dynamic/*.yaml` (one per backend),
  `traefik-edge/certs/` (gitignored).
- **Scripts:** `scripts/common.sh` (`TRAEFIK_EDGE_*` + `ext-svc-lb` vars), `scripts/setup.sh`
  (edge run block + `network connect kind seaweedfs-admin` + bootstrap ordering),
  `scripts/teardown.sh` (edge removal), `scripts/vault-oidc-setup.sh` (issuer).
- **Auth/OIDC:** `authelia/config/configuration*.yaml.tpl` (issuer, forward-auth, two cookie
  domains; drop dead seaweedfs-admin client), retire `authelia/ingressroute.yaml.tpl` +
  per-service Service/Cert templates for the moved services; `k8s/authn-config.yaml.tpl`
  (kube-apiserver structured authn issuer).
- **Observability:** `monitoring/otel-collector/otel-collector-values.yaml` (new `logs`
  pipeline + `otlphttp/logs` → Loki + OTLP receiver mTLS), `monitoring/loki/loki-values.yaml`
  (enable OTLP ingestion), new `monitoring/platform/ext-svc-lb*.yaml` + edge ServiceMonitor
  (mirror `monitoring/platform/calico-*`).
- **Endpoint consumers:** vault/seaweedfs/grafana/argocd/gangplank issuer refs; S3-endpoint
  refs in CNPG barman ObjectStore, Loki storage, ESO.

## Resolved (decided)

- **Edge address** — one pinned IP on the `kind` network (`172.18.0.250`, confirm free);
  backends unpinned, routed by container name. See Decisions. (Not the default `bridge`:
  wrong network for the cluster, and `--ip` is rejected there anyway.)
- **step-ca** — stays in-cluster-fronted, out of the edge (trust-anchor bootstrap +
  unchanged ClusterIssuer URL). See Decisions.

## Resolved during planning (2026-06-29)

1. **Edge IP free-slot** — `172.18.0.250` confirmed clear (pool `kind-pool`
   = `172.18.255.200-250`; Docker high-water `.0.13`). Re-confirm at build.
2. **OTLP reachability** — shared `ext-svc-lb` `LoadBalancer` pinned to `172.18.255.240`
   (reusable for future external→cluster o11y traffic); edge exports traces + logs to that
   IP:4317 over mTLS. See Decisions / item 6.
3. **Authelia placement** — moves to the edge (full OIDC re-bootstrap), executed as a fresh
   `setup.sh` bootstrap on the clean rebuild. See Decisions / item 4b.
4. **Issuer/endpoint churn** — no live migration; clean rebuild renders all hostnames/issuers
   from `${TRAEFIK_EDGE_IP_DASHED}` and bootstraps trust from scratch in `setup.sh` order.

## Open items to resolve during implementation

1. **Loki stream-label mapping** — which OTLP resource attributes get promoted to Loki labels
   (keep low-cardinality: `service.name`, maybe `host.name`); rely on structured metadata for
   the rest.
2. **Re-confirm `172.18.0.250` (Docker static) + `172.18.255.240` (`ext-svc-lb`, in `kind-pool`)**
   free at build time.
3. **mTLS plumbing** — confirm Traefik's `otlp.grpc.tls` (client cert) config keys for
   tracing/log/accesslog all accept the step-ca-issued client cert + CA.
4. **Loki OTLP enable** — confirm exact `loki-values.yaml` keys for the installed chart/version
   to turn on `/otlp/v1/logs` (structured metadata already enabled).

## Verification (local region)

1. `docker ps` shows `traefik-edge` on the `kind` network; dynamic dir has one file per
   service; certs present.
2. `curl -kIL https://vault.<edge-ip>.sslip.io` and the seaweedfs S3 host reach backends
   **without** forward-auth (API surfaces).
3. `curl -kIL https://seaweedfs-admin.<edge-ip>.sslip.io` with no session → `302` to
   Authelia; login as `seaweedfs-admin`/`admin` → UI; other user → `403`.
4. In-cluster consumers still work through the new edge: ESO→Vault, CNPG/Loki→S3 backups,
   Authelia OIDC login flows. **OIDC trust against the new edge issuer**: kube-apiserver OIDC
   login (highest-risk — kubeconfig cert auth is the fallback), Grafana/ArgoCD/gangplank SSO,
   step-ca provisioner, seaweedfs-s3 STS. Both cookie domains issue valid sessions.
5. Prometheus shows the `traefik-edge` target UP; edge-route traces appear in Tempo; **edge
   access/app logs appear in Loki** (`{service_name="traefik-edge"}`); the `ext-svc-lb` Service
   has EXTERNAL-IP `172.18.255.240` and the collector receives over mTLS (handshake succeeds;
   a cert-less client is rejected); (optional) Traefik dashboard renders.
6. Direct host-port access (`:23646`, `:8200`, …) still works (debug).

## Tracking

- Epic: **`cnpg-playground-5sq` — External edge Traefik for host services**.
- Children filed (deps wired, no cycles; `bd ready` surfaces `.1` and `.3` first):
  | Bead | Scope | Plan item |
  |---|---|---|
  | `cnpg-playground-5sq.1` | Edge container `traefik-edge/` + setup.sh run block + `network connect kind seaweedfs-admin` | 1 |
  | `cnpg-playground-5sq.2` | Per-service dynamic config + host TLS certs | 2 |
  | `cnpg-playground-5sq.3` | Cluster-side replace: `TRAEFIK_EDGE_IP*` token, retire in-cluster routes | 4 |
  | `cnpg-playground-5sq.4` | **OIDC re-bootstrap** (Authelia issuer, kube-apiserver authn, vault/grafana/argocd/gangplank/step-ca-provisioner/seaweedfs-s3, two cookie domains, `setup.sh` ordering) | 4b |
  | `cnpg-playground-5sq.5` | Forward-auth (Authelia ForwardAuth + seaweedfs-admin rule) | 5 |
  | `cnpg-playground-5sq.6` | Observability: `ext-svc-lb` shared LB (.240), metrics external-target, traces + OTLP logs pipeline (collector `logs` + Loki OTLP) + step-ca mTLS | 6 |
  | `cnpg-playground-yt4` | Admin-UI forward-auth (linked child) | 7 |
  | `cnpg-playground-5sq.7` | Teardown + docs | 8 |
- Dependency edges: `.1`→`.2/.5/.6/yt4`; `.3`→`.4`; `.1`→`.4`; `.2`→`.5/yt4`; `.4`→`.5`;
  `.5`→`yt4`; all → `.7`.
