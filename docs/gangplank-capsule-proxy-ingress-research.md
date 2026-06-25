# Research: gangplank + capsule-proxy Traefik ingress requirements

Bead: `cnpg-playground-0mf` (research) → unblocks `cnpg-playground-0av` (implementation).

Goal: produce concrete, implementable ingress requirements for the two URLs that
`scripts/setup.sh` prints as "success" but does **not** actually route:

- `https://gangplank.${HUB_TRAEFIK_IP_DASHED}.sslip.io` (callback `/callback`)
- `https://capsule-proxy.${HUB_TRAEFIK_IP_DASHED}.sslip.io`

All facts below were confirmed against the live hub cluster, not assumed.

---

## 1. gangplank

**What it is.** SIGHUP / peak-scale OIDC→kubeconfig dispenser. Browser-facing UI
plus an OIDC redirect/callback against Authelia. A user logs in via Authelia and
downloads a tenant-scoped kubeconfig.

**Why it must be reachable outside the cluster.** It is hit by (a) a human browser
and (b) the Authelia OIDC redirect (`config.redirectURL=…/callback`). Both are
off-cluster.

**Live backend (confirmed).**

| Field   | Value                      |
|---------|----------------------------|
| Service | `gangplank` (ns `gangplank`) |
| Type    | ClusterIP                  |
| Port    | `80` (targetPort `http`)   |
| TLS     | none — plain HTTP backend  |

**Correct exposure: HTTPS `IngressRoute` on `websecure`, Traefik-terminated.**
This is byte-for-byte the ArgoCD pattern (`argocd/ingressroute.yaml.tpl`,
`argocd-server:80`). gangplank serves plain HTTP, so Traefik terminates TLS with a
vault-pki cert and forwards HTTP to `gangplank:80`. No `scheme: https`,
no `serversTransport`.

Required artifacts (mirror `argocd/`):
- `Certificate` (issuer `vault-pki` ClusterIssuer, ECDSA/256, CN+SAN
  `gangplank.${TRAEFIK_IP_DASHED}.sslip.io`) → secret `gangplank-tls`.
- `IngressRoute` entryPoint `websecure`, `Host(\`gangplank.${TRAEFIK_IP_DASHED}.sslip.io\`)`,
  service `gangplank:80`, `tls.secretName: gangplank-tls`.

Both rendered with `envsubst '${TRAEFIK_IP_DASHED}'` in the gangplank block of
`setup.sh` (after the `helm_upgrade_install gangplank`, before the success echo).

---

## 2. capsule-proxy

**What it is.** Clastix/Projectcapsule tenant-scoped Kubernetes API gateway. Its URL
is the `apiServerURL` embedded in the kubeconfig gangplank hands out
(`config.apiServerURL=https://capsule-proxy.${HUB_TRAEFIK_IP_DASHED}.sslip.io`), so
all tenant `kubectl` traffic flows **through** capsule-proxy and its Capsule RBAC
filtering.

**Why it must be reachable outside the cluster.** It is the API endpoint the tenant's
`kubectl` client (on the user's laptop) talks to.

**Live backend (confirmed).**

| Field      | Value                                              |
|------------|----------------------------------------------------|
| Service    | `capsule-proxy` (ns `capsule-system`)              |
| Type       | ClusterIP                                          |
| Port       | `9001`                                             |
| TLS        | **HTTPS** — installed with `options.enableSSL=true` |
| Cert SANs  | `capsule-proxy`, `capsule-proxy.capsule-system.svc` |

**Auth model in THIS repo (the deciding fact).** gangplank issues **OIDC bearer-token**
kubeconfigs (`config.usernameClaim=email`, token/refresh flow) — **not** client-cert
mTLS kubeconfigs. capsule-proxy authenticates the request by the `Authorization: Bearer`
header (TokenReview against the kube-apiserver) and then applies tenant RBAC. The bearer
token survives an HTTP termination + re-encrypt hop. There is **no client-certificate
credential** that would mandate raw TLS passthrough.

### Decision: HTTPS `IngressRoute` (TLS termination at Traefik) + HTTPS re-encrypt to backend

Recommended over `IngressRouteTCP` passthrough.

**Why not passthrough.** Passthrough (`IngressRouteTCP` + `HostSNI`) would forward the
client's TLS straight to capsule-proxy, which then presents its own serving cert.
But that cert's SANs are only `capsule-proxy` / `capsule-proxy.capsule-system.svc` —
**not** `capsule-proxy.${IP}.sslip.io`. `kubectl` validates the server cert against the
URL hostname, so passthrough fails TLS validation **unless** we additionally override
the capsule-proxy serving-cert SANs to include the external sslip.io host (extra Helm
`--set` surgery on `certManager.certificate.fields.dnsNames`, and re-issue). More moving
parts for no auth benefit here.

**Why termination works and is preferred.** Traefik presents a vault-pki cert whose SAN
*is* the external hostname (kubectl trusts step-ca via the kubeconfig `certificate-authority-data`),
then re-encrypts to `capsule-proxy:9001` over HTTPS. This reuses the existing
Authelia pattern (`authelia/ingressroute.yaml.tpl`: `scheme: https` +
`serversTransport`). Bearer-token auth is preserved end to end.

Required artifacts:
- `Certificate` (vault-pki, ECDSA/256, CN+SAN `capsule-proxy.${TRAEFIK_IP_DASHED}.sslip.io`)
  → secret `capsule-proxy-ingress-tls` (distinct name; do **not** clobber the chart's
  `capsule-proxy-serving-cert`).
- `ServersTransport` (ns `capsule-system`) trusting step-ca (rootCAs via configmap/secret,
  or `insecureSkipVerify: true` for the local playground) so Traefik accepts the backend's
  internal-SAN cert on `:9001`.
- `IngressRoute` entryPoint `websecure`, `Host(\`capsule-proxy.${TRAEFIK_IP_DASHED}.sslip.io\`)`,
  service `capsule-proxy:9001` with `scheme: https` + `serversTransport: <name>`,
  `tls.secretName: capsule-proxy-ingress-tls`.

> Caveat to validate during implementation (`-0av`): confirm capsule-proxy does not reject
> a request whose TLS was terminated upstream (it shouldn't — it trusts the bearer token,
> not the client TLS). If a future kubeconfig flavor switches to **client-cert** tenant
> auth, revisit and switch capsule-proxy to `IngressRouteTCP` passthrough + extend its
> serving-cert SANs. Bearer-token flow = termination is correct.

---

## Concrete deliverable for `cnpg-playground-0av`

Create, mirroring `argocd/` and `authelia/`:

1. `gangplank/certificate.yaml.tpl` + `gangplank/ingressroute.yaml.tpl`
   (HTTP backend, Traefik-terminated, `gangplank:80`).
2. `capsule-proxy/certificate.yaml.tpl` + `capsule-proxy/serverstransport.yaml.tpl`
   + `capsule-proxy/ingressroute.yaml.tpl` (HTTPS re-encrypt, `capsule-proxy:9001`).
3. Wire both into `scripts/setup.sh` (apply Certificate, wait Ready, apply IngressRoute)
   right after each chart install, and drop the `info.sh:28` "create no IngressRoute"
   caveat once routes exist.

Entrypoint: both ride the existing `websecure` (443) entrypoint — no new Traefik
entrypoint needed (HTTP IngressRoute + HTTPS re-encrypt, no TCP passthrough).

4. **gangplank `clusterCAPath` (new requirement — surfaced by cross-check).** The
   dispensed kubeconfig's `certificate-authority-data` must trust whatever cert is
   presented at `https://capsule-proxy.${IP}.sslip.io`. With TLS termination, that is the
   **Traefik capsule-proxy ingress cert's CA** (step-ca / vault-pki root), so gangplank
   must mount that CA and set `config.clusterCAPath` (or equivalent) to it. The current
   `helm_upgrade_install gangplank` block in `setup.sh` sets `apiServerURL` but **not** the
   cluster CA, so kubectl would hit an x509 trust error against the new ingress cert. Add
   the CA mount + `clusterCAPath` when wiring the IngressRoutes.

---

## Cross-check (deepwiki + internal plan)

- deepwiki was queried for both `projectcapsule/capsule-proxy` and the gangplank upstream;
  the capsule-proxy query returned an answer (gangplank upstream is `sighupio/gangplank`,
  Helm `peak-scale/gangplank` — not separately indexed). The responses were auto-compressed
  by the runtime and not quotable inline.
- The decisive corroboration is the repo's **own** "Capsule Integration Plan": it specifies
  *"capsule-proxy: Traefik **IngressRoute** … CA = its own ingress TLS (cert-manager)"* —
  i.e. TLS **termination** at the IngressRoute with a cert-manager cert, not TCP passthrough
  — which matches the decision above and supplied the `clusterCAPath` requirement (item 4).
