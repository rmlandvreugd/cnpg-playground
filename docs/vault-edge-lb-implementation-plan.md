# Implementation plan: traefik-edge as Vault's reverse-proxy / LB

> Implements `docs/vault-externalname-traefik-edge.md` (v2, grilled). Source of truth for the
> *why*; this doc is the *how* — grounded against the tree on branch `feature/self-service`.
> Self-contained for a handoff (all paths, line numbers, and the `envsubst`-allowlist gotcha are
> verified). Do the changes in numbered order; run the Verification section against a full recreate.
> Use `bd` for all task tracking (no TodoWrite).

## Context

The k8s→Vault path today relies on a hand-built `Service` + `Endpoints` pair
(`vault/traefik/service.yaml.tpl`) that hardcodes Vault's dynamic docker IP at setup time
(`scripts/setup.sh` "Wire Vault into K8s" block). A `docker restart vault` changes that IP and
silently breaks cert-manager + ESO. The design doc (grilled, v2) resolves this by making
**traefik-edge Vault's official load balancer**, per the HashiCorp Raft reference architecture:
clients → edge:443 (TLS terminate) → **verified re-encrypt** → `https://vault:8200`, with an
LB health check on `/v1/sys/health`. Every in-cluster consumer then dials one canonical URL
(`https://vault.172-18-0-250.sslip.io`) and the in-cluster Service disappears entirely.

**Confirmed during exploration (grounding the doc):**
- Vault's cert already carries the SAN `vault.172-18-0-250.sslip.io` **and**
  `vault.vault.svc.cluster.local` (`scripts/vault-setup.sh:83,86`) → the verified re-encrypt
  hop (`serverName: vault.172-18-0-250.sslip.io`) will pass x509.
- `/etc/traefik/certs/step-ca-chain.pem` is already mounted in the edge (used for OTLP TLS in
  `traefik-edge/traefik.yaml:57`) → `rootCAs` path is valid with no new mount.
- **New finding not in the doc:** the ClusterIssuer and ESO templates are rendered with
  *restricted* `envsubst` allowlists (`setup.sh:695` = `'${VAULT_PORT} ${VAULT_APPROLE_ROLE_ID}
  ${VAULT_CA_BUNDLE}'`; `eso-setup.sh:72` = `'${ESO_NAMESPACE}'`). Switching their URLs to
  `${TRAEFIK_EDGE_IP_DASHED}` requires adding that var to each allowlist. Both scripts already
  `source common.sh`, which sets `TRAEFIK_EDGE_IP_DASHED` (default `172-18-0-250`), so the value
  is in scope — only the allowlist needs widening.
- The two demo stores (`demo/self-service-setup.sh:180,206`) currently use **plain HTTP:8202 with
  no `caProvider`**, so HTTPS migration must add a CA reference.

**Decisions locked with the user for this pass:**
- **Full environment recreate** afterward (not an in-place upgrade) → no manual
  `kubectl delete svc,endpoints vault` migration step needed; a fresh `setup.sh` simply never
  creates the Service. (Keep an `--ignore-not-found` delete only as an optional idempotency note.)
- **Demo store CA:** reuse the existing `vault-pki-bundle` ConfigMap via `caProvider` (same
  pattern as `vault/eso/clustersecretstore.yaml.tpl`), not an inlined base64 `caBundle`.
- **Host ports stay:** do **not** drop Vault's `-p 8200:8200` / `:8202` host publish. Keep them
  permanently as the admin/unseal escape hatch. This overrides doc decision #4's "drop host
  publish"; the follow-up issue is reworded accordingly.

## Changes

### 1. Edge LB config — `traefik-edge/dynamic/vault.yaml`
Replace the `insecure-backend` service with a verifying transport + health check (inline in this
file; leave the shared `traefik-edge/dynamic/transports.yaml` `insecure-backend` untouched — the
other 3 services still use it):
```yaml
http:
  serversTransports:
    vault-verified:
      serverName: vault.172-18-0-250.sslip.io
      rootCAs:
        - /etc/traefik/certs/step-ca-chain.pem
  routers:
    vault:            # unchanged
      rule: "Host(`vault.172-18-0-250.sslip.io`)"
      entryPoints: [websecure]
      service: vault
      tls: {}
  services:
    vault:
      loadBalancer:
        serversTransport: vault-verified          # was: insecure-backend
        healthCheck:
          path: /v1/sys/health?standbyok=true
          interval: 10s
        servers:
          - url: "https://vault:8200"
```
Accepted single-node caveat: a **sealed** Vault returns 503 on `/v1/sys/health` → edge marks the
only backend down → UI unreachable *through the edge* during a seal. Unseal still works via
`docker exec` (how the scripts do it) and the retained host-published `127.0.0.1:8200`.

### 2. Delete the stale Service — `vault/traefik/service.yaml.tpl` + `scripts/setup.sh`
- Delete the file `vault/traefik/service.yaml.tpl`.
- In `scripts/setup.sh`, remove the Vault Service-rendering lines in the "Wire Vault into K8s"
  block (the `VAULT_IP=$(... inspect ...)` + `envsubst '${VAULT_IP}' < .../vault/traefik/service.yaml.tpl | kubectl apply`).
  Keep `kubectl create ns vault` only if another manifest still targets that namespace — verify
  during implementation; drop it if nothing else uses `-n vault`.

### 3. cert-manager ClusterIssuer — `vault/cert-manager/clusterissuer.yaml.tpl` + render site
- `server: https://vault.${TRAEFIK_EDGE_IP_DASHED}.sslip.io` (drop `:${VAULT_PORT}`); `caBundle`
  unchanged (`${VAULT_CA_BUNDLE}` = step-ca chain, verified shared root).
- `scripts/setup.sh:695`: add `${TRAEFIK_EDGE_IP_DASHED}` to the `envsubst` allowlist (and export
  it on the same line, e.g. `TRAEFIK_EDGE_IP_DASHED="${TRAEFIK_EDGE_IP_DASHED}" envsubst '...'`).
  `${VAULT_PORT}` may be dropped from the allowlist since the template no longer uses it.

### 4. ESO ClusterSecretStore — `vault/eso/clustersecretstore.yaml.tpl` + render site
- `server: "https://vault.${TRAEFIK_EDGE_IP_DASHED}.sslip.io"` (was hardcoded
  `https://vault.vault.svc.cluster.local:8200`); `caProvider` unchanged.
- `scripts/eso-setup.sh:72`: widen allowlist to
  `envsubst '${ESO_NAMESPACE} ${TRAEFIK_EDGE_IP_DASHED}'` and export `TRAEFIK_EDGE_IP_DASHED`.

### 5. Demo stores — `demo/self-service-setup.sh:180,206`
Both heredoc stores: `http://vault.vault.svc.cluster.local:${VAULT_HTTP_PORT}` →
`https://vault.${TRAEFIK_EDGE_IP_DASHED}.sslip.io` and add a `caProvider` block reusing the
existing bundle ConfigMap (mirror `vault/eso/clustersecretstore.yaml.tpl:11-15`):
```yaml
      server: "https://vault.${TRAEFIK_EDGE_IP_DASHED}.sslip.io"
      caProvider:
        type: ConfigMap
        name: vault-pki-bundle
        namespace: ${ESO_NAMESPACE}
        key: ca-certificates.crt
```
`TRAEFIK_EDGE_IP_DASHED` is already in scope (script sources `common.sh`).

### 6. PKI AIA/CRL/OCSP URLs — `scripts/vault-pki-setup.sh:98-100`
Drop `:${VAULT_PORT}` from the three URLs → portless
`https://${VAULT_HOST}/v1/pki_int/{ca,crl,ocsp}` (`VAULT_HOST` is already
`vault.172-18-0-250.sslip.io`). Only newly issued certs embed these; nothing validates CRL/OCSP
here yet, so no reissue urgency.

### 7. Audit XFF — `vault/config/vault-config.hcl`
Add to the `0.0.0.0:8200` TLS listener block:
`x_forwarded_for_authorized_addrs = ["172.18.0.250"]` so Vault's audit log records the real client
pod IP from Traefik's `X-Forwarded-For` instead of the edge IP for every caller.

### 8. Runbook — `docs/vault-pki-clusterissuer-runbook.md`
- Rewrite **§6 "Make Vault Reachable From Kubernetes"** (line 177) from the Service+Endpoints
  pattern to the edge-LB pattern (canonical `https://vault.<edge-ip-dashed>.sslip.io`, verified
  re-encrypt, health check).
- Update the **§Inputs** `VAULT_K8S_ADDR` default (line 17) to the sslip URL.
- Add two **Troubleshooting** rows: (a) x509 SAN mismatch on the re-encrypt hop (serverName must
  be a SAN on Vault's cert), (b) `503 from edge` = health check failing = Vault sealed.

### 9. Sweep for lingering Service/Endpoints references
`scripts/vault-teardown.sh` and `scripts/info.sh` (doc change #10) — remove/adjust any
`svc/endpoints vault` printing or cleanup that assumed the deleted Service.

### 10. bd follow-up (file ONE, per user)
Create a single issue: **network-isolate Vault behind the edge** — move Vault to a private docker
network with only traefik-edge dual-homed so in-cluster/pod traffic reaches Vault *exclusively*
through the edge LB. **Explicitly retain** the host port publish (`127.0.0.1:8200` / `:8202`) as
the permanent admin/unseal escape hatch (user override of doc decision #4). Note in the issue body
that the doc's other two ideas (remove the 8202 listener; give step-ca the same edge-LB treatment)
are deferred and not filed this pass. Relate it to `cnpg-playground-i23` (see below).

## Related open beads (state at planning time — none are *resolved* by this plan)

This plan implements a design doc, not an existing bead, so it closes nothing directly. Cross-refs:

| Bead | Relationship to this plan |
|---|---|
| **`cnpg-playground-i23`** — P2 Phase 10: NetworkPolicy allow-list + ingress default-deny flip | **Adjacent, coordinate.** The new bead (§10) is docker-network isolation of the Vault *container*; i23 is in-cluster Calico policy. After this change, pods reach Vault via **egress** to the edge IP `172.18.0.250:443` (sslip.io) — the ingress default-deny flip won't block that, but whoever executes i23 must keep pod egress to the edge open. `relate` the new isolation bead to i23. |
| **`cnpg-playground-8ct`** — P3 SeaweedFS S3 roleMapping (its correction note: "Vault/SeaweedFS are edge-fronted, not in-cluster") | **Corroborating, not resolved.** 8ct's note is the authoritative confirmation of the exact edge-fronting topology (`vault.<edge-ip>.sslip.io`, native OIDC, no forward-auth) this plan builds on. This plan does **not** touch SeaweedFS roleMapping. |
| **`cnpg-playground-lhj`** — P1 epic: Self-service setup | The `demo/self-service-setup.sh` store migration (§5) falls under this epic's surface. The new isolation bead (§10) is standalone infra — file it top-level (or under the vault/edge area), **not** under lhj. |
| a7o (P0 Gangplank OIDC), 6b6 / s6j (P1 Grafana RBAC), 727 (P3 Barman RustFS→SeaweedFS) | Unrelated to the Vault edge-LB path. No interaction. |

**Net bead actions for this work:** file 1 new issue (§10) + `relate` it to i23. Nothing to close.

## Files touched (summary)
| File | Change |
|---|---|
| `traefik-edge/dynamic/vault.yaml` | verified transport + health check (replaces insecure-backend) |
| `vault/traefik/service.yaml.tpl` | **delete** |
| `scripts/setup.sh` | remove Vault Service render block; widen ClusterIssuer envsubst allowlist |
| `vault/cert-manager/clusterissuer.yaml.tpl` | server → sslip URL |
| `vault/eso/clustersecretstore.yaml.tpl` | server → sslip URL |
| `scripts/eso-setup.sh` | widen envsubst allowlist |
| `demo/self-service-setup.sh` | 2 stores → https + caProvider |
| `scripts/vault-pki-setup.sh` | portless AIA/CRL/OCSP URLs |
| `vault/config/vault-config.hcl` | `x_forwarded_for_authorized_addrs` on 8200 listener |
| `docs/vault-pki-clusterissuer-runbook.md` | §6 rewrite + §Inputs + troubleshooting |
| `scripts/vault-teardown.sh`, `scripts/info.sh` | drop stale svc/endpoints refs |

## Verification (against the post-change full recreate)
1. Recreate the environment. `docker logs traefik-edge` clean; Traefik dashboard
   (`traefik.172-18-0-250.sslip.io`) shows the `vault` service **healthy** (health check green).
2. `kubectl get clusterissuer vault-pki` → Ready; all ClusterSecretStores (main + the two migrated
   demo stores `vault-approle-rbr`, `vault-approle-rbr-db`) → Ready.
3. Debug pod:
   `curl -sv https://vault.172-18-0-250.sslip.io/v1/sys/health --cacert <step-ca-chain>` →
   edge cert presented, 200 body from Vault, and Vault's audit log shows the **pod** IP (XFF works).
4. Force a Certificate renewal → reissues through the edge; the new cert's AIA/CRL URLs show the
   portless https form; `curl https://vault.172-18-0-250.sslip.io/v1/pki_int/ca` returns the CA.
5. `docker restart vault` → the old Endpoints-staleness failure is gone; edge health check recovers
   automatically once Vault is unsealed (unseal via `docker exec` / `127.0.0.1:8200`).
6. Negative (SPOF) check: `docker stop traefik-edge` → ClusterIssuer/stores degrade with clear
   errors (documents the new single-edge SPOF); `docker start` recovers.

## Notes / risks
- **Edge becomes critical path** for cert issuance, secret sync, PKI metadata (intended LB tier,
  but a new SPOF in a single-edge playground). Documented, accepted.
- **Edge sees plaintext Vault traffic** — ref-arch-sanctioned for an LB; the verified re-encrypt
  hop is the required mitigation and is a strict upgrade over today's `insecure-backend`.
- **sslip.io DNS now on the in-cluster path** too. Offline fallback if ever needed: CoreDNS
  rewrite/hosts entry for `vault.172-18-0-250.sslip.io`.
