# Separate self-service tenant onboarding from cluster + platform setup

> **Beads:** Workstream J = `cnpg-playground-a0l` (child of epic `cnpg-playground-lhj`).
> Tasks: J1 `cnpg-playground-0ej` (script split + resequence), J2 `cnpg-playground-bph`
> (app node pool), J3 `cnpg-playground-sxj` (monitoring preflight), J4 `cnpg-playground-tnb` (docs).

## Context

`scripts/setup.sh local` currently does **two jobs at once**: it bootstraps the core
cluster + platform, *and* it onboards the concrete `rbr/ver` demo tenant inline. This makes
it hard to bring up a clean cluster and debug the self-service slice independently, and it
introduces a real ordering bug.

What lives where today:

- **Core + platform (correct in `scripts/setup.sh`):** kind, Calico, MetalLB, RustFS/SeaweedFS,
  cert-manager/trust-manager, ESO, Traefik, CNPG operator, Caretta/Radar, **and the platform
  governance layer** — Capsule (`setup.sh:682`), capsule-proxy (`:690`), Kyverno (`:704`),
  ArgoCD (`:709`), gangplank (`:825`), ArgoCD SSO+IngressRoute (`:854-898`).
- **Tenant instance — the pollution (currently in `scripts/setup.sh`, must leave the default path):**
  Capsule `Tenant rbr` pre-seed (`:909-913`), tenant namespaces `rbr-ver`/`rbr-ver-db`
  (`:923-941`), demo-app image build + `kind load` (`:943-949`), ArgoCD app-of-apps root +
  demo-app patch (`:951-972`).
- **Tenant data plane (already in `demo/self-service-setup.sh`):** Vault DB engine, ESO
  ClusterSecretStores, KV seeding, `verstappen` CNPG cluster, pgAdmin, Grafana `rbr-ver`.

**The ordering bug:** `setup.sh` applies the ArgoCD app-of-apps (which starts `demo-app`)
*before* the `verstappen` DB and its `verstappen-app` secret exist — those are created later by
`demo/self-service-setup.sh`. On a fresh cluster `demo-app` crash-loops until the demo script
is run. Splitting the scripts and resequencing fixes this.

**Decisions (confirmed with user):**
1. Platform stays in `setup.sh` — one script yields a cluster *ready for tenant onboarding* but
   fully usable without any tenant.
2. `setup.sh` gets an **opt-in** flag (`--with-tenant`) to chain the full self-service demo;
   default run leaves zero tenant resources.
3. The self-service script **hard-requires monitoring** (Grafana operator + datasources) and
   fails fast if absent.

Canonical order: `scripts/setup.sh local` → `monitoring/setup.sh local` →
`demo/self-service-setup.sh setup local`. One-shot equivalent: `scripts/setup.sh local --with-tenant`.

**Second requirement — dedicated app node pool.** Today the kind cluster has only **one** `app`
node (`k8s/kind-cluster.yaml.tpl`: control-plane + 2 infra + 1 app + 3 postgres). The cluster
needs **two** app nodes, and the **app-tier workloads (demo-app + connection poolers) must land
only on app nodes**. Currently neither is constrained: the demo-app Deployment template
(`app/helm/demo-app/templates/deployment.yaml`) has no `nodeSelector`/`affinity`/`tolerations`
block at all, and `pooler-verstappen-rw` (`cluster-verstappen.yaml.tpl:90-104`) has no scheduling
constraints — both land on any untainted node. Postgres instances are already correctly pinned to
the tainted `postgres` pool (`cluster-verstappen.yaml.tpl:16-25`); pgAdmin and grafana-rbr-ver
are pinned to `infra` and stay there.

**Decisions (confirmed with user):**
4. Add one node → **8 total** (2 infra + **2 app** + 3 postgres + control-plane), preserving
   infra capacity for the heavy monitoring stack.
5. **nodeSelector-only** for app pinning — app nodes stay **untainted** (no `NoSchedule` taint),
   so platform/monitoring overflow can still use them; demo-app + poolers get a `nodeSelector`
   (no toleration needed).

All helpers/vars the moved code needs (`helm_upgrade_install`, `get_traefik_lb_ip`,
`get_cluster_context`, `ip_to_dashed`, `CAPSULE_*`/`KYVERNO_*`/`ARGOCD_*`/`GANGPLANK_*` chart
versions, `AUTHELIA_*_CLIENT_SECRET`) already live in `scripts/common.sh`, which
`demo/self-service-setup.sh` already sources — so relocation is mechanical, not a rewrite.

---

## Changes

### 1. `scripts/setup.sh` — strip the tenant instance, add opt-in chaining (J1)

- **Arg parsing:** accept an optional `--with-tenant` flag alongside the existing region
  positional(s) (`set_regions "$@"`). Parse the flag out before/after region parsing into a
  boolean (default false). Keep behavior identical when the flag is absent.
- **Remove from the default path (lines ~900-972):** the `Tenant rbr` pre-seed, the tenant
  namespace creation loop, the demo-app build + `kind load`, and the ArgoCD root-app apply +
  demo-app patch. Cut these blocks (they move verbatim into the self-service script, §2).
  Leave the platform installs (`682`, `690`, `704`, `709`, `825`, `854-898`) untouched.
- **End-of-script opt-in:** after `info.sh`, if `--with-tenant` was passed, chain:
  1. `"${GIT_REPO_ROOT}/monitoring/setup.sh" local`
  2. `"${GIT_REPO_ROOT}/demo/self-service-setup.sh" setup local`
  Otherwise print a short "next steps" hint (run monitoring, then `self-service-setup.sh setup local`).
- Note: `acquire_lock` is already held by `setup.sh`; the chained scripts also call
  `acquire_lock`. Verify the lock is re-entrant or release before chaining (check
  `common.sh:236` `acquire_lock` / its trap). If not re-entrant, chain by `exec`/trap-release
  rather than nested source. This is the one non-mechanical risk — resolve during impl.

### 2. `demo/self-service-setup.sh` — own tenant onboarding, in the correct sequence (J1)

Reorder the `setup` subcommand so platform-dependent tenant scaffolding comes first and the
ArgoCD app-of-apps comes **last** (after the DB + secrets exist). Target sequence:

1. **Preflight (new, J3):** hard-require monitoring — fail fast unless the `grafana` namespace and
   `grafana-operator` deployment exist. Also sanity-check the platform is present (Capsule CRD
   `tenants.capsule.clastix.io`, `argocd` namespace); if missing, error pointing at `setup.sh`.
2. **Tenant `rbr` pre-seed** — move from `setup.sh:909-913` (`manifests/capsule-tenant-rbr.yaml`,
   wait for `status.state=Active`).
3. **Tenant namespaces** — move the impersonation `create` loop from `setup.sh:923-941`
   (`--as=capsule-bot --as-group=oidc:rbr-db-admin ...` with the `capsule.clastix.io/tenant`
   label). This **replaces** the current plain `kubectl apply -f .../namespace.yaml` at
   `self-service-setup.sh:213-216`, which would be rejected by the Capsule webhook now that the
   namespaces are tenant-owned.
4. Vault policies + AppRole + both ClusterSecretStores + KV seeding (existing `:110-210`).
5. ExternalSecrets + objectstore wiring (existing `:218-265`).
6. ObjectStore CR + monitoring ConfigMap + `verstappen` Cluster/Pooler/ScheduledBackup +
   `kubectl wait Ready` (existing `:267-288`).
7. Traefik `IngressRouteTCP` (existing `:290-295`).
8. Stable PG roles, VDE roles, Vault DB engine, static role `app`, dynamic roles (existing
   `:297-390`). **Must precede step 9** so `database/static-creds/app` and the
   `vault-approle-rbr-db` store exist before `demo-app`'s ExternalSecret syncs.
9. **demo-app image build + `kind load`** — move from `setup.sh:943-949`.
10. **ArgoCD app-of-apps root + demo-app Traefik patch** — move from `setup.sh:951-972`. DB and
    `verstappen-app` secret now exist, so `demo-app` comes up healthy (fixes the crash-loop).
11. pgAdmin (existing `:392-421`).
12. Grafana `rbr-ver` + Authelia + org seed (existing `:423-555`) — monitoring guaranteed by step 1.

**Teardown:** extend the `teardown` subcommand to remove the relocated resources, in order:
delete ArgoCD `rbr-root` Application (cascade child apps) + AppProject `rbr`, then the existing
namespace/ESO/pgAdmin/Grafana cleanup, then delete `Tenant rbr` **last**. Leave platform
components (Capsule/Kyverno/ArgoCD/gangplank) intact — those are removed only by the full
`scripts/teardown.sh` (whole-cluster nuke), which needs no change.

### 3. App node pool + workload scheduling (J2)

- **`k8s/kind-cluster.yaml.tpl`:** add a second worker labeled `app.node.kubernetes.io: ""`
  (mirror the existing app worker), making 2 app nodes. Update the `# Infrastructure/Application
  nodes` count comment. No taint is added (nodeSelector-only decision). `scripts/setup.sh:168`
  already labels every `app.node.kubernetes.io` node as `node-role.kubernetes.io/app` — so both
  app nodes get the role automatically; **no labeling change needed**.
- **`app/helm/demo-app/templates/deployment.yaml`:** add a `nodeSelector` (and optional
  `affinity`/`tolerations`) block to `spec.template.spec`, rendered from values
  (`{{- with .Values.nodeSelector }}` … pattern, matching how `resources` is already templated).
- **`app/helm/demo-app/values.yaml`:** add a default `nodeSelector: {}` (generic chart stays
  schedulable anywhere by default).
- **`app/helm/demo-app/values-rbr-ver.yaml`:** set `nodeSelector: { node-role.kubernetes.io/app: "" }`
  so the rbr-ver demo-app pins to the app pool.
- **`demo/yaml/self-service/rbr-ver-db/cluster-verstappen.yaml.tpl`:** on the `pooler-verstappen-rw`
  Pooler, add `spec.template.spec.nodeSelector: { node-role.kubernetes.io/app: "" }` so both
  PgBouncer replicas land on app nodes. Optionally add a preferred `podAntiAffinity` on
  `kubernetes.io/hostname` so the 2 replicas spread across the 2 app nodes.
- **Out of scope (note for consistency):** the standalone `pg-local` pooler
  (`app/helm/demo-app/values.yaml` default host `pooler-demo-rw`, and the eso-vault demo) can get
  the same `nodeSelector` later; this plan focuses on the self-service `verstappen` path.

### 4. Docs (J4)

- `docs/architecture-overview.md` §3.1: add the platform layer (Capsule, capsule-proxy,
  gangplank, Kyverno, ArgoCD) to the `scripts/setup.sh` outcomes; §8: state that the *tenant
  instance* is owned by `demo/self-service-setup.sh`, document the run order and the monitoring
  hard-requirement, and the `--with-tenant` one-shot.
- `docs/self-service-demo.md` (and `docs/plan-self-service-setup-local.md` verification steps):
  update the boundary, the `setup → monitoring → self-service` order, and that step 1 no longer
  creates the `rbr` tenant.

---

## Verification (end-to-end, local)

1. **Clean platform cluster:** `scripts/setup.sh local`
   - `kubectl get crd tenants.capsule.clastix.io` exists; `kubectl get deploy -n argocd`,
     `-n kyverno`, `-n capsule-system`, `-n gangplank` all Available.
   - **No pollution:** `kubectl get ns | grep -E 'rbr-ver'` empty;
     `kubectl get applications -n argocd` shows no `rbr-root`; no `Tenant rbr`.
   - ArgoCD/gangplank reachable via their IngressRoutes (platform usable without a tenant).
   - **Node pool:** `kubectl get nodes -l node-role.kubernetes.io/app` shows **2** nodes (8 total).
2. `monitoring/setup.sh local` → Grafana operator + datasources up.
3. **Tenant onboarding:** `demo/self-service-setup.sh setup local`
   - `Tenant rbr` Active; `rbr-ver`/`rbr-ver-db` created with `capsule.clastix.io/tenant=rbr`;
     `verstappen` Cluster Ready; **`demo-app` Running (not crash-looping)** in `rbr-ver`;
     `grafana-rbr-ver` rollout complete.
   - **Scheduling:** demo-app pod and `pooler-verstappen-rw` pods are all on `app`-role nodes
     (`kubectl get pods -n rbr-ver -n rbr-ver-db -o wide`); postgres instances remain on
     `postgres` nodes.
   - `demo/self-service-setup.sh verify local` passes (DB connectivity + `verstappen-app` secret
     present + demo-app rollout).
4. **Hard-require check:** on a cluster without monitoring, `demo/self-service-setup.sh setup local`
   fails fast with a clear "run monitoring/setup.sh first" message.
5. **One-shot:** fresh `scripts/setup.sh local --with-tenant` reaches the same end state as
   steps 1-3 combined.
6. **Teardown isolation:** `demo/self-service-setup.sh teardown local` removes tenant + app-of-apps
   + Tenant but leaves platform (Capsule/ArgoCD/etc.) running; `scripts/teardown.sh` removes everything.
