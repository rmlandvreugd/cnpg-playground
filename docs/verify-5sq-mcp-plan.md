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

---

# Execution results — 2026-07-02 (clean recreate: cluster `verstappen`, tenant `rbr-ver`)

Run via MCP (radar + k8s + grafana) and Bash/mc/curl. Live LB IPs this run: edge
`172.18.0.250`, in-cluster Traefik `172.18.255.200`, tenant DB `172.18.255.210`.
Playwright `--ignore-https-errors` was already set in `~/.claude.json` (blocker
pre-cleared). Browser login steps (#3/#4/#7-grafana) were **not** run because the
Authelia SSO backend is down at the HTTP layer (see headline finding) and a
browser would only reproduce the 500/504 — proven more cheaply with curl.

## 🔴 Headline finding — Authelia SSO is fully down (edge→authelia 504)
`traefik-edge` returns **HTTP 504** for every path to the authelia backend, on
both the edge portal (`authelia.172-18-0-250.sslip.io`) and the in-cluster portal
(`authelia.172-18-255-200.sslip.io`, which proxies to the edge via the
`authelia-backend` ExternalName). Cascade: `seaweedfs-admin` forward-auth → **500**;
grafana / argocd / tenant-grafana SSO cannot complete.

- **Root cause:** the `authelia` host container is on the docker **`bridge`**
  network only (`172.17.0.4`), **not `kind`**. `traefik-edge` is on `kind` only
  (`172.18.0.250`) → cannot reach `authelia:9091`. vault (`172.18.0.13`) and
  seaweedfs-admin (`172.18.0.15`) are on **both** and route fine. Authelia itself
  is healthy (docker healthcheck green; `curl https://127.0.0.1:9091/api/health` → 200).
- **Why:** `scripts/authelia-setup.sh` creates the container with `--network bridge`
  (line 166) and is invoked twice from `scripts/setup.sh` (lines 82 and 921). The
  lone `docker network connect kind authelia` (setup.sh line 552, guarded by
  `2>/dev/null || true`) runs *between* them, so the late re-run at 921 recreates
  the container bridge-only and drops the kind attachment; nothing reconnects it.
- **Filed:** `cnpg-playground-o2r` (P1, under epic `5sq`, **blocks `1xa`**).

## Per-item results
| # | Item | Verdict | Evidence |
|---|---|---|---|
| 0 | Baseline health | ⚠️ PASS w/ caveats | in-cluster traefik chart v41 (`41.0.1`); all Helm releases deployed. Pre-existing **critical unrelated**: argocd `kyverno-policies` sync fails (kyverno webhook RBAC). Benign warnings: PDB `verstappen-primary`, `tempo-memcached` endpoints, calico `goldmane`. |
| 1 | Edge is single front | ✅ PASS | `traefik-edge` Up 10h, `:443`, IP `172.18.0.250` on kind net; vault routes through edge → 200. |
| 2 | S3 through edge | ✅ PASS | `mc ls` (via `--insecure` for step-ca) shows `backups/`, `loki/`, `verstappen-backups/`; `mc mb edge/verify-5sq` succeeded. |
| 3 | Edge human surfaces 302/403/login | ❌ FAIL | `seaweedfs-admin` through edge = **500** (forward-auth → authelia 504), not 302. Blocked by `o2r`. |
| 4 | In-cluster portal login + OIDC issuer | ❌ FAIL | Plumbing OK: `authelia-tls-cert` `Ready=True` (CN `authelia.172-18-255-200.sslip.io`), `authelia` IngressRoute + `authelia-backend` ExternalName → edge exist. But `/.well-known/openid-configuration` = **504** from an in-cluster pod (pgadmin) *and* host. Issuer unverifiable. Blocked by `o2r`. **→ resolves bead `1xa`? NO.** |
| 5 | Traces + logs in Loki | ⚠️ PARTIAL | Pipeline up: collector `otel-collector-opentelemetry-collector` (ns `otel`) Running, `traefik-edge-metrics` svc in ns `otel`, Loki (`loki.grafana:3100`) live with ~60 `service_name` values. But **no distinct `traefik-edge` service_name** in Loki (only `traefik`); Grafana MCP is TLS-blocked (won't skip step-ca) so deeper trace/log confirmation was not possible. |
| 6 | Host-port debug bypass | ✅ PASS | vault `127.0.0.1:8200/v1/sys/health` → 200; seaweedfs-admin `127.0.0.1:23646/` → 307. |
| 7 | Tenant URLs (added) | ⚠️ MIXED | **pgAdmin** `http://pgadmin-rbr-ver.172-18-255-200.sslip.io` → 301→**200** (own login, Authelia-independent) ✅. **tenant Grafana** `https://grafana-rbr-ver.172-18-255-200.sslip.io` → 302 `/login` (page loads) but "Sign in with Authelia" hits the dead portal ⚠️. |

## Bead `cnpg-playground-1xa` — NOT resolved
Title: *"Two-domain Authelia fatals: in-cluster clients need in-cluster portal
restored."* The in-cluster-portal plumbing that 1xa added is all correctly in
place (cert `Ready`, IngressRoute, `authelia-backend` ExternalName), so its
original cookie-scope bug appears fixed — **but its live acceptance test cannot
pass**: the in-cluster portal 504s because the upstream edge Authelia is
unreachable from `traefik-edge`. Root cause is the **new** regression `o2r`
(authelia not on kind net), not 1xa's original issue. **Keep `1xa` open, now
blocked by `o2r`.** Re-run #3/#4/#7-grafana (incl. the Playwright login flows)
once `o2r` is fixed and authelia is on both `bridge`+`kind`.

---

# Re-verification after `o2r` fix — 2026-07-02

**Fix applied:**
- Code (durable): `scripts/authelia-setup.sh` now runs
  `${CONTAINER_PROVIDER} network connect kind "${AUTHELIA_CONTAINER_NAME}" 2>/dev/null || true`
  immediately after the container is (re)created, so the kind attachment survives
  the second `authelia-setup.sh` invocation (`setup.sh:921`).
- Live hot-fix (current cluster): `docker network connect kind authelia`
  → `docker inspect` now shows **`bridge kind`**.

**Results (all previously-failing items now pass):**
| # | Item | Before | After |
|---|---|---|---|
| 1 | edge Authelia `/api/health` | 504 | **200** ✅ |
| 4 | in-cluster portal OIDC issuer | 504 | **`https://authelia.172-18-255-200.sslip.io`** (in-cluster host) ✅ |
| 3 | edge forward-auth (seaweedfs-admin) | 500 | **302 → authelia login** ✅ |
| — | both portals render app HTML | 504 | **200 + Authelia SPA** (edge & in-cluster) ✅ |

**`1xa` acceptance criterion met:** the in-cluster portal serves OIDC discovery
with `issuer == in-cluster host` and both portals are live — the cookie-scope
fatal (`errFmtSessionDomainURLNotInCookieScope`) is gone. Its plumbing was already
correct; `o2r` was the sole live blocker.

**Not re-run:** Playwright browser logins — the MCP's Chrome isn't installed in
this environment (`npx playwright install chrome`). The HTTP-level chain (portal
200 + correct issuer + forward-auth 302) is conclusive for the SSO/1xa criterion.

**Status:** `o2r` fix verified on the live cluster; **clean-recreate validation of
the code fix still pending** (a fresh `teardown local && setup local` should leave
authelia on `bridge kind` with no hot-fix). `1xa` unblocked.

---

# Playwright browser flows — 2026-07-02 (now unblocked)

The Playwright MCP browser (Chrome) is now installed (`npx playwright install chrome`),
so the two login flows that were previously HTTP-only could be run for real.

**#3 — Edge forward-auth (seaweedfs-admin, edge portal):** ✅ ALL PASS
- Unauthenticated `https://seaweedfs-admin.172-18-0-250.sslip.io/`
  → 302 to edge portal `authelia.172-18-0-250.sslip.io/?rd=...seaweedfs-admin...`.
- Login `authuser` / `password` → authenticates, redirected back → **403 Forbidden**
  (not in `seaweedfs-admin` group). Correct deny.
- Logout, login `admin` / `password` → forward-auth passes → app renders its own
  `SeaweedFS Admin - Login` page (no 403). Correct allow.

**#7 — Tenant Grafana OIDC (in-cluster portal):** ✅ FULL ROUND-TRIP PASS
- `https://grafana-rbr-ver.172-18-255-200.sslip.io/` shows **"Sign in with Authelia"**.
- Click → redirects to the **in-cluster portal** `authelia.172-18-255-200.sslip.io/?flow=openid_connect`
  (the exact 1xa fix — in-cluster portal serving the OIDC flow).
- Login `rbr-ver-admin` / `password` → consent screen "Hi RBR VER Admin" for app
  "Grafana RBR VER" (scopes openid/email/profile/groups) → Accept.
- Lands on **Grafana Home, orgId=2** (tenant org), 0 console errors.
  Screenshot: `docs/tenant-grafana-rbr-ver-sso-success.png`.

Test credentials confirmed: static password is `password` (verified via
`authelia crypto hash validate`); users from `authelia/config/users_database.yml.tpl`.

**Conclusion:** every Authelia-dependent surface in the runbook now passes at the
browser level on the live cluster — edge forward-auth (allow + deny) and the tenant
OIDC login through the restored in-cluster portal. Only the clean-recreate
validation of the `authelia-setup.sh` code fix remains before closing `o2r`/`1xa`.

---

# Clean-recreate validation — 2026-07-02 (FINAL — `o2r`/`1xa` closed)

Ran a full from-scratch cycle with **no hot-fix**:
`./scripts/teardown.sh local && ./scripts/setup.sh local --with-tenant` (exit 0).

**The `authelia-setup.sh` code fix held automatically:**
- `docker inspect authelia` → networks **`bridge kind`** (no manual `network connect`).
- edge `/api/health` → **200**; edge portal `/` → **200**.
- in-cluster OIDC issuer (from pgadmin pod) → **`https://authelia.172-18-255-200.sslip.io`**
  (in-cluster host) — the `1xa` acceptance criterion, green from scratch.

**Playwright browser flows (re-run on the fresh cluster):**
- **#3 edge forward-auth:** unauth→302 to edge portal; `authuser`→**403** (deny);
  `admin`→app renders its own `SeaweedFS Admin - Login` (allow). ✅
  (One transient `error=Unable to initialize session` on the very first `admin`
  hit right after setup — the seaweedfs-admin app's own session backend still
  warming; cleared on retry. App-level, not SSO.)
- **#7 tenant Grafana OIDC:** "Sign in with Authelia" → **in-cluster portal**
  OIDC flow → `rbr-ver-admin` → consent "Grafana RBR VER" → **Grafana Home orgId=2**,
  0 console errors. ✅ Screenshot: `docs/tenant-grafana-rbr-ver-sso-recreate-verified.png`.

**Verdict:** `o2r` fix is durable across a clean teardown+setup; `1xa`'s in-cluster
portal + issuer criterion is met from scratch. **Both beads closed.**

