# traefik-edge as Vault's reverse-proxy/load-balancer (v2)

> v1 of this document proposed an `ExternalName` Service to traefik-edge with TCP passthrough.
> Grilling reframed the goal to "edge as Vault's official LB", which supersedes that design —
> the v1 decision records are preserved in the Appendix.

## Context

The k8s→Vault connection currently uses a manual `Service` + `Endpoints` pair
(`vault/traefik/service.yaml.tpl`) hardcoding the Vault container's dynamic docker IP at setup time
(`scripts/setup.sh:589-593`) — a container recreate silently breaks cert-manager/ESO. The original
question was whether an `ExternalName` Service to traefik-edge could replace it; the reframed goal:
**traefik-edge is Vault's reverse-proxy/LB outright**, end state being *no direct access to
vault:8200 — only `https://vault.172-18-0-250.sslip.io` (via the edge) from the k8s side*, per the
[HashiCorp Raft reference architecture](https://developer.hashicorp.com/vault/tutorials/day-one-raft/raft-reference-architecture).

The reference architecture validates this exactly:
- Network table: **clients → LB:443**, **LB → Vault:8200** — the target topology verbatim.
- TLS termination at the LB is sanctioned **if** the LB→Vault hop is also TLS
  ("strongly recommended … to minimize the exposure of secret content on your network").
- The LB should poll **`/v1/sys/health`** to route traffic — only possible in Traefik when the
  service is HTTP (terminating); TCP passthrough services cannot HTTP-probe. This flipped the
  earlier passthrough recommendation.

Once every client uses the sslip.io URL on 443, pods resolve it directly and **no in-cluster
Service (of any type) is needed at all** — the ExternalName question becomes moot.

## Decisions (grilled, all resolved)

1. **LB model: terminate at edge + verified re-encrypt.** Edge terminates on 443 (existing
   `vault` HTTP router), re-encrypts to `https://vault:8200` with a **verifying**
   `serversTransport` (rootCAs = step-ca chain, `serverName: vault.172-18-0-250.sslip.io`) —
   replacing `insecure-backend` on this route — plus `healthCheck` on `/v1/sys/health`.
   Accepted cost: edge sees plaintext Vault traffic (ref-arch-sanctioned for an LB).
2. **Service fate: delete it, migrate all URLs.** Remove Service+Endpoints; point ClusterIssuer,
   the ESO ClusterSecretStore, and the two demo stores at `https://vault.172-18-0-250.sslip.io`.
   One canonical URL for pods, host, and browsers. `caBundle` stays the step-ca chain — verified:
   `VAULT_CA_BUNDLE` (= `vault/certs/vault-ca.pem`) and the edge certs share the same step-ca root.
3. **8202 plain HTTP: migrate stores, keep listener.** Both `demo/self-service-setup.sh` stores
   (lines 180, 206) move to the https URL + caBundle. The `vault-config.hcl` 8202 listener stays
   as the documented bootstrap escape hatch; **bd issue** to remove it later.
4. **Enforcement: bd follow-up.** Docker-network isolation (vault on a private network, only the
   edge dual-homed, drop the `-p 8200:8200` host publish) is a standalone change with its own
   blast radius. Until then "no direct access" is config-level, not network-level.
5. **PKI URLs: fix to 443.** `scripts/vault-pki-setup.sh:98-100` AIA/CRL/OCSP →
   `https://vault.172-18-0-250.sslip.io/v1/pki_int/{ca,crl,ocsp}` (dead today: they point at
   edge:8200 where nothing listens). Only newly issued certs embed the fixed URLs — fine, nothing
   validates CRL/OCSP here yet.
6. **Audit fidelity: wire up XFF.** Add `x_forwarded_for_authorized_addrs = ["172.18.0.250"]` to
   the 8200 listener so Vault's audit log records real client IPs from Traefik's X-Forwarded-For
   instead of the edge IP for every caller.

## Changes

1. **`traefik-edge/dynamic/vault.yaml`** — upgrade the existing router's service:
   ```yaml
   http:
     serversTransports:
       vault-verified:
         serverName: vault.172-18-0-250.sslip.io   # must match a SAN on Vault's cert
         rootCAs:
           - /etc/traefik/certs/step-ca-chain.pem
     services:
       vault:
         loadBalancer:
           serversTransport: vault-verified        # was: insecure-backend
           healthCheck:
             path: /v1/sys/health?standbyok=true
             interval: 10s
           servers:
             - url: "https://vault:8200"
   ```
   Single-node caveat (accepted): when Vault is sealed, `/v1/sys/health` returns 503 → Traefik
   marks the only backend down → the UI is unreachable through the edge during a seal. Unseal
   still works via `docker exec` (how the scripts already do it) or the host-published
   127.0.0.1:8200 (kept until the isolation follow-up).
2. **Delete `vault/traefik/service.yaml.tpl`** and its apply block in `scripts/setup.sh:585-593`;
   add a migration line: `kubectl delete svc,endpoints vault -n vault --ignore-not-found`.
3. **`vault/cert-manager/clusterissuer.yaml.tpl`** — `server: https://vault.${TRAEFIK_EDGE_IP_DASHED}.sslip.io`
   (drop `:${VAULT_PORT}`); `caBundle` unchanged.
4. **`vault/eso/clustersecretstore.yaml.tpl`** — same URL change; `caBundle` unchanged.
5. **`demo/self-service-setup.sh:180,206`** — both stores: `http://vault.vault.svc.cluster.local:8202`
   → `https://vault.${TRAEFIK_EDGE_IP_DASHED}.sslip.io` + step-ca `caBundle`.
6. **`scripts/vault-pki-setup.sh:98-100`** — AIA/CRL/OCSP URLs to the portless https form.
7. **`vault/config/vault-config.hcl`** — add to the 8200 listener:
   `x_forwarded_for_authorized_addrs = ["172.18.0.250"]`. Keep the 8202 listener (escape hatch).
8. **`docs/vault-pki-clusterissuer-runbook.md`** — rewrite §6 (Service+Endpoints was *the*
   documented pattern) to the edge-LB pattern; add troubleshooting rows: x509 SAN mismatch on the
   re-encrypt hop, and 503-from-edge = health check failing (sealed Vault).
9. **bd issues to file**: (a) network-isolate vault behind the edge + drop host port publish;
   (b) remove the 8202 listener once nothing depends on it; (c) apply the same edge-LB treatment
   to step-ca (`step-ca/traefik/service.yaml.tpl` has the identical stale-IP pattern).
10. Check `scripts/vault-teardown.sh` / `scripts/info.sh` for Service/Endpoints references.

## Trade-offs (accepted)

- **Edge is now in the critical path** for cert issuance, secret sync, and PKI metadata. If
  traefik-edge is down, everything Vault-dependent is down. That is the point of an LB tier, but
  in a single-edge playground it's a new SPOF.
- **Edge sees plaintext secrets** — sanctioned by the ref arch for LBs; the verified re-encrypt
  hop is the required mitigation (and an upgrade over today's `insecure-backend`).
- **sslip.io DNS dependency** now applies to the in-cluster path too (previously svc-DNS only).
  Offline fallback if ever needed: CoreDNS rewrite/hosts entry for `vault.172-18-0-250.sslip.io`.

## Verification

1. Recreate traefik-edge; `docker logs traefik-edge` clean; Traefik dashboard shows the vault
   service healthy (health check green).
2. `kubectl delete svc,endpoints vault -n vault`; apply updated ClusterIssuer + stores.
3. From a debug pod: `curl -sv https://vault.172-18-0-250.sslip.io/v1/sys/health --cacert <step-ca-chain>`
   → edge cert presented, 200 body from Vault, and Vault audit log shows the pod IP (XFF working).
4. `kubectl get clusterissuer vault-pki` → Ready; all ClusterSecretStores (incl. the two migrated
   demo stores) → Ready.
5. Force a cert renewal; confirm reissue through the edge. New cert's AIA/CRL URLs show the
   portless https form; `curl https://vault.172-18-0-250.sslip.io/v1/pki_int/ca` returns the CA.
6. `docker restart vault` → Endpoints-staleness failure mode gone; edge health check recovers
   automatically once Vault is unsealed.
7. Negative check: `docker stop traefik-edge` → ClusterIssuer/stores degrade with clear errors
   (documents the new SPOF); restart recovers.

---

## Appendix: v1 decision records (superseded)

### ExternalName caveats that shaped v1

An `ExternalName` Service is a bare DNS CNAME
([groundcover](https://www.groundcover.com/learn/logging/externalname-service),
[Cast AI](https://cast.ai/blog/kubernetes-external-service/),
[OneUptime](https://oneuptime.com/blog/post/2026-02-20-kubernetes-externalname-services/view)):

1. **No port remapping** — the `ports:` section is informational only; clients dial whatever port
   they specify against the CNAME target.
2. **TLS SNI/Host mismatch** — clients keep the service hostname in SNI/Host; the target must
   route and present certs for *that* name, not its own.
3. **DNS-name targets only** — an IP in `externalName` is treated as a digits-only DNS name and
   won't resolve.

### TLS design comparison (v1 table — the LB framing decided this in favor of termination)

| Aspect | TCP passthrough on :8200 | Terminate TLS at edge |
|---|---|---|
| Mechanism | TCP router, `HostSNI(vault.vault.svc.cluster.local)`, `tls.passthrough: true`, raw bytes → `vault:8200` | HTTP router terminates, re-encrypts via `serversTransport` → `vault:8200` |
| Client changes | None — Vault's cert already has the svc-name SAN (`scripts/vault-setup.sh:86`) | None to caBundle (same step-ca chain); URLs move to the sslip name |
| End-to-end TLS | Preserved pod→Vault | Broken at edge; mitigated by **verified** re-encrypt (ref-arch requirement) |
| LB health checks (`/v1/sys/health`) | **Impossible** — Traefik TCP services can't HTTP-probe | Native `healthCheck` support |
| Edge observability | TCP-level only | Full HTTP access logs, metrics, middleware |
| Vault audit log | Sees pod source IP | Sees edge IP — mitigated via `x_forwarded_for_authorized_addrs` |
| Security posture | Edge can't read secrets traffic | Edge sees decrypted tokens/secrets |
| Future mTLS to Vault | Works | Edge would terminate the client handshake |

v1's other grilled decisions (carry :8202 through the edge as a TCP catch-all; ExternalName target
`vault.${TRAEFIK_EDGE_IP_DASHED}.sslip.io`) are moot in v2: the stores migrate to https and the
Service is deleted entirely.
