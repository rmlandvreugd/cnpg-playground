# Capsule Integration Plan — self-service-demo

Status: research complete 2026-05-05; integration plan ready for review

Resolves the open questions in `docs/capsule-research.md` (R1–R8) with verified data from
[projectcapsule.dev](https://projectcapsule.dev/docs/) and the [Capsule release tracker](https://github.com/projectcapsule/capsule/releases).
Output is the concrete delta to layer Capsule on top of the existing self-service demo
(`docs/self-service-demo.md`) without breaking CNPG / ESO / Traefik / Grafana / Vault.

---

## 1. Resolved research questions

### R1 — Installation + webhook conflicts

| Item | Value |
|---|---|
| Helm chart | OCI `ghcr.io/projectcapsule/charts/capsule` |
| Chart version (current) | `0.12.4` |
| Image | `ghcr.io/projectcapsule/capsule:0.10.9` |
| K8s minimum | `v1.34.0` for app `v0.10.9`; `v1.33.0` for `v0.10.8` |
| cert-manager | Recommended, **not required** (chart can self-sign via `tls.create=true`) |
| Install namespace | `capsule-system` |
| Required admission plugins | `PodNodeSelector`, `LimitRanger`, `ResourceQuota`, `MutatingAdmissionWebhook`, `ValidatingAdmissionWebhook` |

**Pin:** `0.10.7` (chart `0.10.7`) targets K8s 1.32 — confirm Kind node image once chart version is chosen, since current Kind defaults may be older. Use `kindest/node:v1.34.x` to match `0.12.4`.

**Webhook conflicts:** Capsule webhooks scope by `userGroups` (`manager.options.capsuleUserGroups` or new `users`).
Service accounts of CNPG (`cnpg-system`), ESO (`external-secrets`), Grafana Operator (`grafana`),
and cert-manager (`cert-manager-system`) are **not** in this list → bypass tenant validation entirely.
No deadlock on `failurePolicy: Fail`.

If a problematic webhook hits (e.g. node webhook), per-webhook `matchConditions` CEL expressions
exclude system service accounts:

```yaml
webhooks:
  hooks:
    namespaces:
      matchConditions:
      - name: 'exclude-cnpg'
        expression: '!("system:serviceaccounts:cnpg-system" in request.userInfo.groups)'
```

Rootless Podman + Kind: no Capsule-specific issues. Capsule webhooks talk to the operator inside the cluster — same path that already works for CNPG / ESO / cert-manager.

### R2 — Tenant model

API: `capsule.clastix.io/v1beta2`.
- One `Tenant` owns multiple namespaces — namespaces opt in via label `capsule.clastix.io/tenant=<tenant>`.
- Owner kinds: `User`, `Group`, `ServiceAccount`.
- Default cluster roles bound per owner per namespace: `admin`, `capsule-namespace-deleter`.
- Non-owner access (group-admin pattern): `spec.additionalRoleBindings[]` distributes RoleBindings to all tenant namespaces.

### R3 — CNPG / ESO / Grafana Operator compatibility

Capsule's tenant-scope check applies **only** to subjects in `userGroups`. Cluster-scoped operators
run as their own service accounts, which are not in that list → unaffected.
Confirmed for parallel projects ([NashTech blog example](https://blog.nashtechglobal.com/how-to-implement-custom-admission-policies-with-capsule/);
existing CNPG + Capsule deployments in the wild).

`ClusterSecretStore` (ESO) reads/writes Secrets in tenant namespaces from the `external-secrets`
service account — passes through Capsule.

`GrafanaDatasource` lives in `grafana` namespace (not a tenant namespace) → no Capsule involvement.

### R4 — Traefik + networking

| Subject | Behavior |
|---|---|
| `IngressRouteTCP` (Traefik CRD) | Capsule ingress class enforcement targets `networking.k8s.io/v1` `Ingress` only — Traefik CRDs pass through. |
| `IngressRoute` HTTP | Same — pass through. |
| Built-in NetworkPolicy generation | Off by default. Capsule generates only when `spec.networkPolicies.items[]` is set. **Deprecated** — leave unset. |
| TenantReplications / TenantResource | Replacement for NetworkPolicy generation. Not needed for first slice. |
| capsule-proxy | Optional. Adds tenant-scoped `kubectl get namespaces`. **Excluded from first slice** — adds component, doesn't change demo correctness. |

Net result: existing Traefik TCP passthrough on `:5432` and HTTPS on `:443` keep working unchanged.

### R5 — Kind OIDC config

Capsule docs explicitly publish a Kind OIDC example (sourced verbatim):

```yaml
apiVersion: kind.x-k8s.io/v1alpha4
kind: Cluster
nodes:
  - role: control-plane
    kubeadmConfigPatches:
     - |
       kind: ClusterConfiguration
       apiServer:
           extraArgs:
             oidc-issuer-url: https://${OIDC_ISSUER}
             oidc-username-claim: email
             oidc-client-id: kubernetes
             oidc-groups-claim: groups
             oidc-username-prefix: "oidc:"
             oidc-groups-prefix: "oidc:"
             oidc-ca-file: /etc/kubernetes/oidc/ca.crt
```

Constraints for this stack:
- Dex already issues `groups` claim from `staticPasswords.groups` (confirmed in self-service-research closure).
- API server needs Dex CA mounted into control-plane node. Kind supports `extraMounts` to bind-mount `dex/tls/ca-chain.pem`.
- `oidc-issuer-url` must be HTTPS and reachable from inside the Kind control-plane container — same `dex.<TRAEFIK_IP>.sslip.io` URL Vault already uses works.

**Trade-off:** Kind apiServer flags require **rebuild** — no live `kubectl edit` of the static control-plane. Adds ~30s to setup time. Acceptable.

**Alternative without OIDC:** use `User` kind subjects on `Tenant.spec.owners` with explicit emails, then rely on Capsule's `users` config rather than groups. Loses dynamic group membership but skips Kind rebuild. Reject — Dex groups already work, the Kind config patch is small.

### R6 — System namespaces

Distinction is automatic: only namespaces with label `capsule.clastix.io/tenant=<name>` belong to a tenant. `vault`, `traefik`, `dex`, `grafana`, `monitoring`, `cert-manager-system`, `metallb-system`, `capsule-system`, `cnpg-system`, `external-secrets` carry no such label → unmanaged.
Set `manager.options.protectedNamespaceRegex` to block tenant owners from creating namespaces named like system ones.

`GlobalTenantResource` not required for first slice.

### R7 — Vault policy boundary

Two independent layers. No mapping needed.

| Layer | Authority |
|---|---|
| K8s API access (`kubectl apply -n rbr-ver-db`) | Capsule + Dex OIDC group claim |
| DB credential issuance (`vault read database/creds/...`) | Vault userpass / OIDC + Vault policies |

Dex is the common identity provider; both layers verify the email/group claims independently.

### R8 — Teardown cascade

Default: deleting a `Tenant` deletes its namespaces (Kubernetes garbage collection via owner reference).
Existing teardown already deletes namespaces explicitly — keep that, then delete the `Tenant` last (or first; both work since GC is idempotent).

---

## 2. Decisions

| # | Decision | Rationale |
|---|---|---|
| D1 | **One Tenant per constructor+driver pair** (`rbr-ver`) | Matches existing namespace pair (`rbr-ver-db` + `rbr-ver`). Future `rbr-had` is a separate Tenant. Keeps blast radius tight. |
| D2 | **Owner subject = `Group`** with Dex `rbr-db-admin` claim | Dynamic membership; matches Vault policy naming. |
| D3 | **`additionalRoleBindings`** for `rbr-ver-db-admin` group | Non-owner group access pattern. Bind a custom ClusterRole for VDE-relevant resources. |
| D4 | **Skip capsule-proxy** in first slice | Optional UX improvement; adds component without changing demo correctness. |
| D5 | **NetworkPolicy: keep disabled** in Capsule | Existing self-service decision; out of scope. Leave `spec.networkPolicies` unset. |
| D6 | **Capsule install in `scripts/setup.sh` Phase 0** | Capsule is base infra (like cert-manager), not self-service-specific. Tenant CR is in Phase 1. |
| D7 | **OIDC via Kind apiServer extraArgs**, not legacy `User` ACL | Kind rebuild cost is small; dynamic group membership is the right primitive. |
| D8 | **Pin chart `0.12.4` + Kind node `v1.34.x`** | Matches Capsule's K8s minimum. |

---

## 3. Tenant manifest

```yaml
apiVersion: capsule.clastix.io/v1beta2
kind: Tenant
metadata:
  name: rbr-ver
spec:
  owners:
    - name: oidc:rbr-db-admin       # tenant-admin (full)
      kind: Group
  additionalRoleBindings:
    - clusterRoleName: admin         # group-admin gets admin too, but only in rbr-ver-db / rbr-ver
      subjects:
        - apiGroup: rbac.authorization.k8s.io
          kind: Group
          name: oidc:rbr-ver-db-admin
  ingressOptions:
    hostnameCollisionScope: Tenant
  resourceQuotas:
    scope: Tenant
  # networkPolicies: intentionally unset
```

Namespace patches (existing namespaces gain the label):

```yaml
metadata:
  name: rbr-ver-db
  labels:
    capsule.clastix.io/tenant: rbr-ver
```

(Same pattern for `rbr-ver`.)

---

## 4. Phase-by-phase delta

### Phase 0 — `scripts/setup.sh`

1. Patch Kind cluster config to add OIDC apiServer flags + `extraMounts` for Dex CA.
   Concrete patch lives at `k8s/kind-cluster.yaml.tpl` (new file). Wiring delta in `scripts/setup.sh`:

   ```diff
   - kind_config_path="${GIT_REPO_ROOT}/k8s/kind-cluster.yaml"
   + kind_config_tpl="${GIT_REPO_ROOT}/k8s/kind-cluster.yaml.tpl"
   + kind_config_path="${GIT_REPO_ROOT}/k8s/.kind-cluster.rendered.yaml"
   + DEX_TLS_DIR="${DEX_TLS_DIR:-${GIT_REPO_ROOT}/dex/tls}"
   + DEX_HOST="dex.$(ip_to_dashed "$(hostname -I | awk '{print $1}')").sslip.io"
   + DEX_TLS_DIR="${DEX_TLS_DIR}" DEX_HOST="${DEX_HOST}" DEX_PORT="${DEX_PORT}" \
   +   envsubst '${DEX_TLS_DIR} ${DEX_HOST} ${DEX_PORT}' \
   +   < "${kind_config_tpl}" > "${kind_config_path}"
   ```

   Constraints:
   - Dex + Vault PKI already run **before** Kind cluster create in current `setup.sh` (lines 62–65 → 105). `dex/tls/ca-chain.pem` exists at the moment Kind starts. No reorder needed.
   - `DEX_HOST` resolution: Kind control-plane container needs DNS for `dex.<IP>.sslip.io`. `sslip.io` is a public wildcard resolver — works from inside the container as long as upstream DNS reaches it (already does for Vault OIDC).
   - `.kind-cluster.rendered.yaml` belongs in `.gitignore`.
   - `DEX_HOST` must be derived from the same `HOST_IP_DASHED` that `dex-setup.sh` uses (script-internal source of truth) — re-derive identically or export it from `dex-setup.sh`.

2. After cert-manager + Vault PKI + Dex + Traefik phases, add **Capsule install**:
   ```bash
   helm upgrade --install capsule oci://ghcr.io/projectcapsule/charts/capsule \
       --version 0.12.4 \
       --namespace capsule-system --create-namespace \
       --set certManager.generateCertificates=true \
       --set tls.create=false \
       --set tls.enableController=false \
       --set 'manager.options.capsuleUserGroups[0]=oidc:rbr-db-admin' \
       --set 'manager.options.capsuleUserGroups[1]=oidc:rbr-ver-db-admin' \
       --wait
   ```
3. Verify: `kubectl get crd tenants.capsule.clastix.io`.

### Phase 1 — static manifests

- Add `manifests/capsule-tenant-rbr-ver.yaml` with the Tenant CR.
- Patch `rbr-ver-db` and `rbr-ver` Namespace manifests with the `capsule.clastix.io/tenant=rbr-ver` label.

### Phase 2 — Vault setup

No change. Vault layer unchanged; Capsule does not gate Vault access.

### Phase 3 — `demo/self-service-setup.sh`

| Verb | Change |
|---|---|
| `setup local` | After namespace creation (step 5), `kubectl apply` the Tenant manifest. Already idempotent. |
| `verify local` | Add `kubectl get tenant rbr-ver -o jsonpath='{.status.state}'` → expect `Active`. |
| `teardown local` | After namespace delete, `kubectl delete tenant rbr-ver --ignore-not-found`. |

### Phase 4 — pgAdmin

No change. pgAdmin lives in `pgadmin` namespace, not a tenant namespace.

### Phase 5 — Grafana + Dex

Already reuses the same Dex `rbr-db-admin` / `rbr-ver-db-admin` groups — Capsule consumes the **same claim**. No Dex config change. The new Kind OIDC flags simply make the API server consume what Dex already issues.

### Phase 6 — docs

Update `docs/self-service-demo.md` architecture diagram: add a `capsule-system` box with a Tenant CR overlay covering `rbr-ver-db` + `rbr-ver`. Add a "K8s API access via Capsule" row to the personas table.

---

## 5. Persona table extension

| Email | Dex groups | Vault DB role | K8s namespaces (via Capsule) | Grafana org/role |
|---|---|---|---|---|
| `rbr-admin@example.com` | `rbr-db-admin`, `rbr-ver-db-admin` | `rbr-db-admin` | `rbr-ver-db`, `rbr-ver` (admin) | `rbr` / Admin |
| `rbr-ver-admin@example.com` | `rbr-ver-db-admin` | `rbr-ver-db-admin` | `rbr-ver-db`, `rbr-ver` (admin via additionalRoleBindings) | `rbr` / Editor |
| `unrelated@example.com` | — | — | (forbidden) | — |

A tenant user logs into K8s via:

```bash
kubectl oidc-login setup --oidc-issuer-url=https://dex.<IP>.sslip.io/dex \
    --oidc-client-id=kubernetes
kubectl --kubeconfig oidc.kubeconfig get pods -n rbr-ver-db
```

(or `kubelogin` plugin).

---

## 6. Risk + open items

1. **Kind rebuild required** for OIDC flags. Existing setup.sh recreates Kind on each `setup local` already → no surprise.
2. **OIDC issuer reachability inside Kind:** Dex container runs on host. Kind control-plane container needs to resolve `dex.<TRAEFIK_IP>.sslip.io` and reach it. Already works for Vault OIDC inside the cluster — same path.
3. **`kubectl` client-side OIDC:** Demo users need `kubelogin` or equivalent to actually exercise tenant-scoped K8s access. Document in self-service-demo.md.
4. **Capsule version drift vs. Kind node image:** pin both, bump together.
5. **Future second tenant** (`rbr-had`): copy Tenant CR with new label set; no operator-level work.

---

## 7. Sources

- [Capsule docs index](https://projectcapsule.dev/docs/)
- [Permissions / ownership / additionalRoleBindings](https://projectcapsule.dev/docs/tenants/permissions/)
- [Namespaces / tenant labeling](https://projectcapsule.dev/docs/tenants/namespaces/)
- [Enforcement / IngressClass / NetworkPolicies](https://projectcapsule.dev/docs/tenants/enforcement/)
- [Authentication / OIDC + Kind example](https://projectcapsule.dev/docs/operating/authentication/)
- [Architecture / Capsule Administrators](https://projectcapsule.dev/docs/operating/architecture/)
- [Configuration / userGroups / protectedNamespaceRegex](https://projectcapsule.dev/docs/operating/setup/configuration/)
- [Installation / requirements / webhook hooks](https://projectcapsule.dev/docs/operating/setup/installation/)
- [Replications / TenantResource / GlobalTenantResource](https://projectcapsule.dev/docs/replications/)
- [Proxy](https://projectcapsule.dev/docs/proxy/)
- [Releases](https://github.com/projectcapsule/capsule/releases)
- [Artifact Hub: capsule 0.12.4](https://artifacthub.io/packages/helm/projectcapsule/capsule)
- [Kind configuration](https://kind.sigs.k8s.io/docs/user/configuration/)
- [CNPG ESO integration](https://cloudnative-pg.io/docs/1.28/cncf-projects/external-secrets/)
