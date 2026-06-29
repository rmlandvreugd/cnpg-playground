# External edge Traefik for host services

Status: planned 2026-06-29. Epic; folds in `cnpg-playground-yt4` (SeaweedFS admin-UI auth).

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
  `vault`, `authelia`, `seaweedfs` (S3), `seaweedfs-admin`, `rustfs`. Backends **stay on
  the `kind` network**. Each container's published host port stays for direct
  debug/break-glass access.
- **Responsibilities — TLS + forward-auth + observability.** Terminate TLS at the edge
  (step-ca / vault-pki certs on the host filesystem), centralize human-facing SSO via
  Authelia forward-auth, and export metrics + traces to the in-cluster observability stack.
- **yt4 folded in.** The admin-UI forward-auth is implemented on this external Traefik.
  Admin-UI policy: `one_factor` + group `seaweedfs-admin`/`admin`.
- **Dynamic config via file provider.** Traefik file provider watching a config directory
  (`watch: true`); setup drops one dynamic config file per backend ("triggers on files
  placed in the config folder").
- **Addressing — one pinned IP, on the `kind` network.** Only the **edge** gets a static
  IP, and it must be on the **`kind`** network (`172.18.0.0/16`) — the cluster lives there
  and cannot route to the default `bridge` (`172.17.0.0/16`). Reserve a slot **below** the
  MetalLB pool and clear of node/host-container IPs and Docker's dynamic range — target
  `172.18.0.250` (confirm free at build). The edge's IP is what gets encoded into every
  `*.sslip.io` hostname (and thus OIDC issuer URLs + S3 endpoints), so it must be
  restart-stable. **Backends are NOT pinned** — on the user-defined `kind` network Docker's
  embedded DNS resolves them by container name (`http://vault:8200`,
  `https://seaweedfs-admin:23646`), so the edge routes by name. Note: the default `bridge`
  network rejects `--ip` anyway (*"supported only when connecting to networks with user
  configured subnets"*), so static IPs there are not an option. `authelia`,
  `seaweedfs-admin`, and `rustfs` are currently bridge-only and must be
  `network connect kind`'d as part of this work.
- **step-ca stays in-cluster-fronted, out of the edge.** step-ca is the trust anchor that
  issues the edge's own TLS cert (`step ca certificate …`); putting it behind the edge
  creates a bootstrap cycle (edge needs a cert to start → must reach step-ca → through the
  edge that isn't up). It's a machine ACME/API endpoint (no browser, no forward-auth value;
  re-terminating TLS would fight ACME identity). It keeps its existing in-cluster Traefik
  IngressRoute at `step-ca.<in-cluster-LB>.sslip.io`, so cert-manager's ClusterIssuer ACME
  URL is unchanged and needs no re-bootstrap. step-ca is therefore the **one** host service
  still routed by the in-cluster Traefik; vault/authelia/seaweedfs/rustfs move to the edge.

## Architecture

```
                       *.sslip.io  (host = external-traefik IP)
   in-cluster pods ─┐
                    ├─►  EXTERNAL TRAEFIK (host container, on `kind` net)
   external users ──┘     • entrypoints web:80→443, websecure:443, +metrics
                          • file provider (watch=true) on a mounted config dir
                          • TLS termination (step-ca / vault-pki certs on host FS)
                          • forward-auth middleware → Authelia (human surfaces only)
                          • OTLP traces + Prometheus metrics
                                 │ routes by Host/SNI to kind-IP backends
            ┌──────────────┬─────┴────────┬───────────────┬───────────┐
          vault         authelia       seaweedfs        seaweed-       rustfs
        (:8200)         (:9091)        S3 (:8333)        admin         (:…)
                                                        (:23646)
        (all backends remain on the kind network; host ports still published)
```

**Forward-auth selectivity (critical):** attach the forward-auth middleware only to
**human/browser** surfaces — the `seaweedfs-admin` UI. Do **not** forward-auth machine/API
surfaces: the `authelia` route itself (would create an auth loop), `vault` API, `seaweedfs`
S3 API, `rustfs` S3 API — these authenticate with their own tokens / access keys / OIDC-STS.

## Work breakdown (reuse existing patterns)

1. **External Traefik container — new `traefik-edge/`.** Static `traefik.yaml` (entrypoints,
   file provider `directory: /etc/traefik/dynamic` `watch: true`, `metrics.prometheus`,
   `tracing.otlp`), plus a `dynamic/` dir populated at setup. Run block in
   `scripts/setup.sh` mirrors the seaweedfs-admin run block; `--network kind --ip
   172.18.0.250` (the one pinned IP — confirm free); mount config + cert dirs; publish
   :443/:80. Add `TRAEFIK_EDGE_*` vars to `scripts/common.sh` (incl. `TRAEFIK_EDGE_IP` /
   `TRAEFIK_EDGE_IP_DASHED`). `network connect kind` for the bridge-only backends
   (`authelia`, `seaweedfs-admin`, `rustfs`).
2. **Per-service dynamic config** dropped into the watched dir: router (Host rule + TLS +
   optional forward-auth) + service (loadBalancer to the backend **by container name** via
   `kind` embedded DNS, e.g. `https://seaweedfs-admin:23646` — no IP inspection needed);
   `serversTransport.insecureSkipVerify` for HTTPS backends — mirror
   `capsule-proxy/serverstransport.yaml`.
3. **Host TLS certs** via the established pattern (`scripts/authelia-setup.sh`,
   `scripts/vault-setup.sh`): `step ca certificate "<host>" cert.pem key.pem` →
   `docker cp` out → into `traefik-edge/certs/` (gitignored). Reference in a dynamic `tls`
   block.
4. **Cluster-side replace.** Service hostnames for vault/authelia/seaweedfs/rustfs become
   `*.172-18-0-250.sslip.io` (the pinned edge IP). Retire the in-cluster IngressRoutes +
   per-service Services/Certs for those four; **step-ca keeps its in-cluster route
   unchanged**. **Audit + update** hardcoded `*.sslip.io` issuer/endpoint references
   (Authelia/Vault OIDC issuer URLs, S3 endpoints) across `authelia/`, `vault*`,
   `seaweedfs/config/`, `scripts/*.sh`, `monitoring/` — step-ca's URL is excluded from the
   churn.
5. **Authelia forward-auth.** Ensure
   `server.endpoints.authz.forward-auth.implementation: ForwardAuth`; add the
   seaweedfs-admin `access_control` rule (one_factor + group restrict). Edge middleware
   `forwardAuth.address: https://authelia.<edge-ip>.sslip.io/api/authz/forward-auth` with
   `authResponseHeaders: [Remote-User,Remote-Groups,Remote-Name,Remote-Email]`. Remove the
   dead `AUTHELIA_SEAWEEDFS_ADMIN_CLIENT_SECRET` (`scripts/common.sh`).
6. **Observability.** Metrics scraped via the external-target pattern (headless
   Service+Endpoints at the edge `kind` IP + ServiceMonitor — mirror
   `monitoring/platform/calico-metrics-services.yaml` + `calico-servicemonitors.yaml`).
   Traces via `tracing.otlp` → in-cluster OTel collector (:4317/:4318) over a
   host-reachable endpoint; mind the collector service-name fix (otel-collector helm name).
   Optional Traefik GrafanaDashboard (same pattern as the kyverno/argocd dashboards).
7. **yt4 admin UI.** Dynamic file routing `seaweedfs-admin.<edge-ip>.sslip.io` →
   admin `:23646` (https, insecureSkipVerify) + forward-auth. Keep `-adminUser/-adminPassword`.
8. **Teardown + docs.** `scripts/teardown.sh` stops/removes the edge container + retired
   resources; update `docs/architecture-overview.md` once built (it documents current
   state — do **not** add the edge there until it exists).

## Resolved (decided)

- **Edge address** — one pinned IP on the `kind` network (`172.18.0.250`, confirm free);
  backends unpinned, routed by container name. See Decisions. (Not the default `bridge`:
  wrong network for the cluster, and `--ip` is rejected there anyway.)
- **step-ca** — stays in-cluster-fronted, out of the edge (trust-anchor bootstrap +
  unchanged ClusterIssuer URL). See Decisions.

## Open items to resolve during implementation

1. **Edge IP free-slot check** — confirm `172.18.0.250` is outside Docker's dynamic
   allocation and unused at build time; fall back to another reserved slot below the
   MetalLB pool if taken.
2. **OTLP reachability** from a host container to the in-cluster collector (NodePort /
   MetalLB / existing path).
3. **Access-log shipping** (Traefik→Loki push vs OTLP logs) — secondary to metrics/traces.
4. **Issuer/endpoint churn** — moving vault/authelia/seaweedfs/rustfs to the edge IP
   changes their OIDC issuer URLs and S3 endpoints; requires full grep+update and
   re-bootstrap of dependent OIDC trust (step-ca excluded).

## Verification (local region)

1. `docker ps` shows `traefik-edge` on the `kind` network; dynamic dir has one file per
   service; certs present.
2. `curl -kIL https://vault.<edge-ip>.sslip.io` and the seaweedfs S3 host reach backends
   **without** forward-auth (API surfaces).
3. `curl -kIL https://seaweedfs-admin.<edge-ip>.sslip.io` with no session → `302` to
   Authelia; login as `seaweedfs-admin`/`admin` → UI; other user → `403`.
4. In-cluster consumers still work through the new edge: ESO→Vault, CNPG/Loki→S3 backups,
   Authelia OIDC login flows.
5. Prometheus shows the `traefik-edge` target UP; edge-route traces appear in Tempo;
   (optional) Traefik dashboard renders.
6. Direct host-port access (`:23646`, `:8200`, …) still works (debug).

## Tracking

- New epic: **External edge Traefik for host services** (to be created in beads).
- `cnpg-playground-yt4` → child / blocked-by the epic (admin-UI forward-auth).
- Children: container + file-provider; host certs; cluster replace + hostname/issuer audit;
  forward-auth; observability; teardown + docs.
