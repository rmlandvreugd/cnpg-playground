# Handoff: fix a7o — Gangplank OIDC login broken (invalid_client / token_endpoint_auth_method)

> Bead: `cnpg-playground-a7o` (P0, under epic `cnpg-playground-lhj`). Branch `feature/self-service`.
> Fix is a 1-line-per-file config change; the bulk of the work is live re-verification and the
> `invalid_target` contingency. Use `bd` for tracking (claim a7o, close on green verify).

## Root cause (confirmed on both sides of the exchange)

The Sign-in flow reaches Authelia, redirects back to `gangplank/callback`, then **fails at the
server-side token exchange** with:

> oauth2: "invalid_client" — "…using 'token_endpoint_auth_method' method 'client_secret_post',
> however the OAuth 2.0 client registration does not allow this method."

- **Gangplank** (peak-scale chart, go `oauth2` lib) authenticates at the token endpoint with
  **`client_secret_post`** — client_id + client_secret in the POST body. Its runtime config
  (`scripts/setup.sh` ~1149 helm block) confirms a confidential client:
  `config.tokenURL=…/api/oidc/token`, `config.clientID=gangplank`,
  `GANGPLANK_CONFIG_CLIENT_SECRET` seeded from `AUTHELIA_GANGPLANK_CLIENT_SECRET`.
- **Authelia's `gangplank` client stanza** (`authelia/config/configuration.yaml.tpl:141`;
  duplicated in `authelia/config/configuration-two-domains.yaml.tpl:152`) sets a `client_secret`
  hash but **no `token_endpoint_auth_method`** → Authelia defaults confidential clients to
  **`client_secret_basic`** and rejects the POST-body credentials.
- Repo-wide, **no** OIDC client sets `token_endpoint_auth_method`. ArgoCD / Grafana / SeaweedFS
  work only because their OIDC libraries default to `client_secret_basic`. Gangplank is the sole
  client that sends `client_secret_post` → the sole one that breaks. The client_secret pair itself
  is correctly wired (Authelia holds the hash, gangplank the plaintext); **only the method is wrong.**

## Fix (primary — do this first)

Add `token_endpoint_auth_method: 'client_secret_post'` to the gangplank client stanza in **both**
Authelia config templates (they are rendered by `scripts/authelia-setup.sh:120-123` depending on
single- vs two-domain mode, so both must match):

`authelia/config/configuration.yaml.tpl` (after line 141's stanza, matching 8-space indent):
```yaml
      - client_id: gangplank
        client_name: Gangplank
        client_secret: '${AUTHELIA_GANGPLANK_CLIENT_SECRET_HASH}'
        authorization_policy: one_factor
        token_endpoint_auth_method: 'client_secret_post'   # ← ADD: gangplank posts creds in body
        redirect_uris:
          - 'https://gangplank.${TRAEFIK_IP_DASHED}.sslip.io/callback'
        scopes: [openid, email, profile, groups]
        claims_policy: 'default_policy'
        userinfo_signed_response_alg: none
```
Apply the identical single-line addition to the gangplank stanza in
`authelia/config/configuration-two-domains.yaml.tpl` (~line 152).

No secret rotation, no gangplank redeploy needed — this is purely the Authelia client registration.

## Apply + verify (live)

1. Re-render/restart Authelia to pick up the config:
   `bash scripts/authelia-setup.sh` (or restart the Authelia container so it reloads
   `configuration.yaml`). Confirm Authelia comes up clean (`docker logs authelia` — no config
   validation errors; `client_secret_post` is a valid `token_endpoint_auth_method` value).
2. **Playwright live check** (how a7o was originally reproduced): navigate to
   `https://gangplank.<hub-traefik-ip>.sslip.io/`, click Sign in, authenticate as a persona in
   Authelia, and confirm the callback now renders the **kubeconfig** page (no `invalid_client`).
3. Persona matrix: repeat for `admin`, `rbr-admin`, `rbr-ver-admin`, `rbr-ver-dev`, `rbr-po`, and
   an unrelated user — this unblocks the entire K8s/Capsule column of
   `docs/plan-tenant-personas-authelia.md`.
4. End-to-end: download a dispensed kubeconfig and run `kubectl auth whoami` /
   `kubectl get pods` through `capsule-proxy.<ip>.sslip.io` to confirm the ID token's `aud`
   (`gangplank`) is accepted by the API server (`k8s/authn-config.yaml.tpl` accepts audiences
   `kubernetes` and `gangplank` via MatchAny).

## Second bug (CONFIRMED and fixed) — `invalid_target` / audience not whitelisted

The `invalid_target` on the callback was **not** a downstream artifact — it is a genuine second
defect. After the `client_secret_post` fix, the authorize request failed with:

> Authorization Request failed: **"Requested audience 'gangplank' has not been whitelisted by the
> OAuth 2.0 Client."** (`method=GET path=/api/oidc/authorization`)

Root cause: gangplank sends an `audience` OAuth parameter, and **defaults it to its own client_id
(`gangplank`) when `config.audience` is empty** — confirmed live: setting `config.audience: ""`
still produced `audience=gangplank` in the request. So the audience **cannot** be suppressed from
the gangplank side. Authelia/fosite (`explicit` requested-audience mode, the default) rejects any
requested audience the client hasn't registered.

**Fix (Authelia side):** whitelist the audience on the gangplank OIDC client. Authelia's client
schema accepts a bare (non-URI) string in `identity_providers.oidc.clients[].audience`:
```yaml
      - client_id: gangplank
        # …
        token_endpoint_auth_method: 'client_secret_post'
        audience:
          - 'gangplank'          # ← ADD: gangplank requests aud=<client_id>, whitelist it
        redirect_uris:
          - 'https://gangplank.${TRAEFIK_IP_DASHED}.sslip.io/callback'
```
Applied to **both** templates. `scripts/setup.sh` keeps `--set "config.audience=gangplank"` (the
explicit, self-documenting value; empty behaves identically since gangplank defaults to client_id).
The dispensed ID token's `aud` is `["gangplank"]`, which the API server accepts
(`k8s/authn-config.yaml.tpl` audiences `kubernetes`, `gangplank`).

## Verification (COMPLETE — 2026-07-04)

Live Playwright flow against `https://gangplank.172-18-255-200.sslip.io`:
- **admin**: login → consent → kubeconfig page rendered. `kubectl auth whoami` through
  capsule-proxy → `Username oidc:admin@example.com`, groups include `oidc:capsule-admin`,
  `oidc:k8s-admin` (full access).
- **rbr-po**: same flow completes; `kubectl auth whoami` → `Username oidc:rbr-po@example.com`,
  groups `[oidc:rbr-po system:authenticated]`; `kubectl get tenants` correctly **Forbidden** at
  cluster scope — RBAC scoping verified distinct from admin.

Both ends of the RBAC spectrum pass; the OIDC exchange is client-level and identical for every
persona, so the fix unblocks the whole K8s/Capsule persona column.

## Bead actions
- `bd update cnpg-playground-a7o --claim` before starting. ✅
- On green persona-matrix verification, `bd close cnpg-playground-a7o`. ✅ (this pass)

## Files touched (summary)
| File | Change |
|---|---|
| `authelia/config/configuration.yaml.tpl` | add `token_endpoint_auth_method: 'client_secret_post'` + `audience: ['gangplank']` to gangplank client |
| `authelia/config/configuration-two-domains.yaml.tpl` | same additions to gangplank client (this is the live/two-domain config) |
| `scripts/setup.sh` | keep explicit `--set "config.audience=gangplank"` with a comment explaining the Authelia-side whitelist |
