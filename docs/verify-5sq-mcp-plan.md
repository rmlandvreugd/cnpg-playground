# Verifying epic `cnpg-playground-5sq` with MCP (Playwright + k8s + radar)

Goal: run the 6-item **Verification (local region)** checklist from
`docs/plan-external-edge-traefik.md` using MCP tools instead of ad-hoc curl, so
the checks are repeatable and evidence is captured.

## Topology recap (local region)

| Surface | Host | Reaches |
|---|---|---|
| Edge Traefik (host container) | `172.18.0.250` → `*.172-18-0-250.sslip.io` | vault, authelia, seaweedfs S3, seaweedfs-admin |
| In-cluster Traefik (metallb LB) | `172.18.255.200` → `*.172-18-255-200.sslip.io` | grafana, argocd, gangplank, radar, in-cluster authelia portal |
| Authelia edge portal | `authelia.172-18-0-250.sslip.io` | host containers |
| Authelia in-cluster portal | `authelia.172-18-255-200.sslip.io` | in-cluster clients (hub → edge → Authelia) |

Test users (`authelia/config/users_database.yml`, password = `password` for all):
- `admin` — in `seaweedfs-admin` group → **allowed** to admin UI.
- `authuser` — groups `[]` → **denied** (expect 403 / not-authorized).

Both `172.18.0.250` and `172.18.255.x` are on the docker/kind network and are
reachable from the host (Linux/WSL), and `sslip.io` resolves the dashed IP
publicly — so no `/etc/hosts` edits are needed.

## ⚠️ Blocker to clear first — Playwright MCP must ignore TLS errors

All host/cluster surfaces present **step-ca–signed certs**, which the browser
does not trust. The Playwright MCP server is currently configured with **no**
`--ignore-https-errors` flag (`~/.claude.json` → `mcpServers.playwright.args =
["@playwright/mcp@latest"]`). Without it every `browser_navigate` fails on
`net::ERR_CERT_AUTHORITY_INVALID`.

Fix (one-time, requires MCP restart to take effect):
```jsonc
"playwright": {
  "command": "npx",
  "args": ["@playwright/mcp@latest", "--ignore-https-errors"]
}
```
(Equivalent config-file form: `browser.contextOptions.ignoreHTTPSErrors: true`.)

Everything below assumes that flag is live.

## Checklist → MCP tool mapping

### 1. Edge is the single front on the kind network
- **radar** `list_helm_releases` / `get_topology` — confirm in-cluster per-service
  routes for vault/authelia/seaweedfs are **gone** (retired), edge is the front.
- **Bash** (supporting): `docker inspect traefik-edge` shows it joined the kind
  network; `docker ps` shows it Up.

### 2. S3 (seaweedfs) works through the edge
- **Bash/mc**: `mc alias set edge https://seaweedfs.172-18-0-250.sslip.io ...`
  then `mc ls` / `mc mb` against the edge host (browser can't do S3 sigv4).
- **Playwright** is *not* used here — S3 is an API, not a human surface.

### 3. Human surfaces: unauth → 302 to Authelia, wrong user → 403  ← **core Playwright work**
For `seaweedfs-admin.172-18-0-250.sslip.io` (edge, forward-auth middleware):
1. `browser_navigate` to the admin URL **unauthenticated**.
2. `browser_network_requests` → assert a **302** whose redirect lands on
   `authelia.172-18-0-250.sslip.io` (the edge portal), and that the final page is
   the Authelia login (`browser_snapshot` shows the login form).
3. `browser_fill_form` / `browser_type` username=`authuser`, password=`password`,
   submit → assert **403 / "not authorized"** (authuser has no group).
   Check via `browser_network_requests` status + `browser_snapshot` text.
4. New context (`browser_close` then navigate, or a fresh tab) → log in as
   `admin`/`password` → assert the **seaweedfs-admin UI renders**
   (`browser_snapshot` shows admin dashboard, not the Authelia page).
- Repeat the unauth→302 probe against `vault.172-18-0-250.sslip.io` to confirm
  the edge portal fronts vault too.

### 4. In-cluster portal login works
- **Playwright**: `browser_navigate` to an in-cluster human surface behind the
  in-cluster portal — e.g. `argocd.172-18-255-200.sslip.io` (or grafana).
- Assert redirect to `authelia.172-18-255-200.sslip.io` (the **in-cluster**
  portal, *not* the edge host) via `browser_network_requests`, log in as
  `admin`/`password`, land back on the app.
- **k8s**: `resources_get` the `authelia-tls-cert` Certificate (ns `authelia`)
  → `Ready=True`; `resources_list` IngressRoute → the in-cluster `authelia`
  route + `authelia-backend` ExternalName Service exist.
- **k8s**: confirm the per-request OIDC issuer — `pods_exec` a curl to
  `https://authelia.172-18-255-200.sslip.io/.well-known/openid-configuration`
  from an in-cluster pod and assert `issuer` == the in-cluster host (this closes
  the loop that failed at end of the last session).

### 5. Traces + logs land in Loki (edge observability)
- **radar** `get_workload_logs` for the in-cluster otel-collector / traefik, and
  **k8s** `pods_log` on the collector — confirm edge OTLP is being received.
- **Grafana MCP** (best signal): `query_loki_logs` for
  `{service_name="traefik-edge"}` (or the label the edge ships under) over the
  last 15m → non-empty; `list_loki_label_values` to confirm the edge service
  label exists. Traces: check the collector received spans from `traefik-edge`.
- Note the fixed OTel service name gotcha (`otel-collector-opentelemetry-collector`)
  when locating the collector.

### 6. Direct host-port debug access still works
- **Bash**: `curl -sk https://127.0.0.1:8200/v1/sys/health` (vault) and
  `curl -sk https://127.0.0.1:23646/` (seaweedfs-admin) return without going
  through the edge — proves the debug bypass survived.

## Supporting cluster-health sweep (radar + k8s)
Run once up front so failures in 1–6 are easy to attribute:
- **radar** `issues` and `diagnose` — surface any crash-looping / unhealthy
  workloads (traefik-edge OTLP mTLS, authelia, gangplank).
- **radar** `get_helm_releases` — traefik in-cluster chart is the expected v41.
- **k8s** `pods_list_in_namespace` for `authelia`, `traefik`, `argocd`,
  `monitoring` — all Running/Ready.

## Execution order
1. Add `--ignore-https-errors` to Playwright MCP, restart MCP.
2. radar `issues`/`diagnose` + k8s pod sweep (baseline health).
3. Bash: edge on kind network (#1), S3 (#2), host-port debug (#6).
4. Playwright: edge forward-auth 302/403/login (#3), in-cluster portal login (#4).
5. k8s: in-cluster authelia cert/route + issuer check (#4).
6. Grafana/radar/k8s: Loki logs + traces (#5).
7. Record pass/fail per item; file beads for any regression, linked to `5sq`.

## Notes / gotchas
- `browser_network_requests` is how you read status codes (302/403) — the
  browser silently follows redirects, so assert on the request list, not just the
  final rendered page.
- Use a fresh browser context between the `authuser` (403) and `admin` (200)
  runs so the Authelia session cookie from one doesn't leak into the other.
- Cookie scope: the edge portal issues cookies for `172-18-0-250.sslip.io`, the
  in-cluster portal for `172-18-255-200.sslip.io` — a login on one does **not**
  authenticate the other; test each portal independently.
