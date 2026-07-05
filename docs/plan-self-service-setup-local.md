# Self-Service Setup (local region): Capsule tenancy, GitOps, OIDC everywhere

## Context

The self-service demo today provisions a CNPG database (`verstappen` in `rbr-ver-db`) with
Vault-issued dynamic DB credentials, ESO projection, pgAdmin, and a per-tenant Grafana org.
Identity moved from **Dex to Authelia** (host container, `authelia/config/users_database.yml`),
but `docs/capsule-research.md` / `docs/capsule-integration-plan.md` still describe Dex and are
stale. Capsule, capsule-proxy, Kyverno, ArgoCD, and SeaweedFS-OIDC are **planning-only — nothing
deployed**. The sample app (`app/helm/demo-app`, Litestar/Python) has a deploy-ready chart but is
not wired into the demo.

This effort turns the demo into a full self-service tenancy platform for the **local region only**
(EU/US deferred). It adds Kubernetes-native multi-tenancy (Capsule), tenant-scoped API access
(capsule-proxy + gangplank), policy enforcement (Kyverno), GitOps (ArgoCD), the running sample app,
OIDC across SeaweedFS, hardened DB credential issuance, new non-admin tenant personas, and Grafana
visibility for Capsule + Calico. The deliverable of this planning pass is the **doc set** below;
implementation follows on approval.

Tenant model: constructor = `rbr`, driver group = `ver`. Namespaces `rbr-ver-db` (database) and
`rbr-ver` (app). Future driver groups: `rbr-had`, etc.

## Locked decisions (from interview)

| # | Decision |
|---|---|
| D1 | **Personas**: `rbr-ver-dev` is **per driver-group** (K8s `edit` in `rbr-ver`+`rbr-ver-db`, Vault `app`/`readonly` DB creds, Grafana **Editor**). `rbr-po` is **per constructor** (read-only across all `rbr-*` driver groups: K8s `view` + `kubectl get` via capsule-proxy, Grafana **Viewer**, **no DB write**). |
| D2 | **Capsule: one Tenant per constructor** (`rbr` owns `rbr-ver`+`rbr-ver-db` and future pairs). `rbr-po`=`view` is tenant-wide (spans all driver groups naturally). `rbr-ver-db-admin`=`admin` and `rbr-ver-dev`=`edit` are scoped to the driver-group namespaces via **per-namespace RoleBindings** (Capsule bindings are tenant-wide, so these live outside Capsule). **Supersedes old D1/D2** in capsule-integration-plan. |
| D3 | **DB config user**: dedicated least-priv `rbr_ver_vde_config` (LOGIN, CREATEROLE, **no table ownership**) used **only** by Vault `database/config/rbr-ver-max`; enable Vault **root-credential rotation** (`rotate-root`). Separates the connection identity from issued identities; no superuser fallback anywhere. |
| D4 | **API access**: deploy **capsule-proxy** (tenant-scoped API gateway) fronted by **gangplank** (`sighupio/gangplank`, Helm `peak-scale/gangplank`) as the OIDC→kubeconfig web dispenser. `apiServerURL` → capsule-proxy ingress. Requires Kind kube-apiserver structured `AuthenticationConfiguration` accepting audiences `kubernetes`+`gangplank` (`audienceMatchPolicy: MatchAny`), `email` username claim, `groups` claim, Authelia issuer + CA. New Authelia OIDC client `gangplank`. |
| D5 | **App deploy**: `helm install demo-app` into `rbr-ver`, `credentialsMode=static` reading the Vault static-role-rotated `verstappen-app` Secret via the db `ClusterSecretStore`; Reloader restarts on rotation; migrations as **initContainer** vs `verstappen-rw` (direct), runtime via pooler. Image built from `app/Dockerfile` and `kind load`ed by the script. **Deployed by ArgoCD** (see D8). |
| D6 | **SeaweedFS**: human OIDC only. Admin UI → Authelia OIDC (`seaweedfs-admin`/`admin` → full). S3 API → OIDC via IAM config (`sts.providers` Authelia + roles + trust policies on `groups` claim): `admin`→Admin, tenant `rbr-ver-db-admin`→rw / `rbr-po`→ro on their backup bucket. **Machine identities keep static keys**, split into per-identity keys (`loki`, `barman`) — no shared `loki` key. Add per-tenant backup bucket + identity. |
| D7 | **Kyverno**: install + (a) **generate** per-driver-group RoleBindings (`rbr-ver-db-admin`=admin, `rbr-ver-dev`=edit, scoped to `rbr-ver`+`rbr-ver-db`) and a default-deny-ish NetworkPolicy on tenant-namespace create; (b) **validate** baseline (disallow privileged, require requests/limits + probes); (c) **restrict images** to allowed registries. Policies start **Audit**, then flip to **Enforce**. |
| D8 | **ArgoCD**: install now as the **GitOps engine**. App-of-apps reconciles tenant resources (demo-app chart, Capsule Tenant, Kyverno policies, Grafana org/datasources). `self-service-setup.sh` bootstraps ArgoCD, builds+`kind load`s the image, applies the root Application; ArgoCD syncs the rest (script stops direct `helm`/`kubectl` for those). **Argo Events/Workflows/Rollouts stay Phase 2** (event-driven pgAdmin). ArgoCD SSO via Authelia (`argocd-admin`). |
| D9 | **Monitoring**: ServiceMonitors for capsule-controller-manager, capsule-proxy, and Calico (felix/typha/kube-controllers; enable via Tigera `FelixConfiguration.prometheusMetricsEnabled`) into the existing kube-prometheus-stack; import upstream **Capsule + Calico** Grafana dashboards as configmaps alongside `monitoring/grafana/grafana_dashboard_*.yaml`. |
| D10 | **Admin model**: dedicated `<service>-admin` Authelia groups — add `argocd-admin`, `seaweedfs-admin`, `capsule-admin`; reuse `k8s-admin` for Kyverno/cluster. All assigned to the `admin` user. Each service maps its own admin group. |
| D11 | **Docs**: rewrite `capsule-research.md` + `capsule-integration-plan.md` to Authelia + new decisions; update the 3 named docs; add focused new docs. |

## Workstream A — Identity (Authelia)

Source of truth: `authelia/config/users_database.yml` + `authelia/config/configuration.yaml.tpl`
+ secrets/hostnames in `scripts/common.sh`; rendered by `scripts/authelia-setup.sh`.

- **New groups**: `rbr-ver-dev`, `rbr-po`, `argocd-admin`, `seaweedfs-admin`, `capsule-admin`.
  Add all `*-admin` to the `admin` user (super-admin everywhere). Add `rbr-ver-dev`/`rbr-po` to
  new sample users.
- **New users** (dev-default password hash, like existing): `rbr-ver-dev@example.com`
  (`rbr-ver-dev`), `rbr-po@example.com` (`rbr-po`). Keep `rbr-admin`, `rbr-ver-admin`, `unrelated`.
- **New OIDC clients** in `configuration.yaml.tpl`: `gangplank`, `argocd`, `seaweedfs-admin`,
  `seaweedfs-s3` (redirect URIs to the respective sslip.io hosts; `groups email profile openid`
  scopes; secrets seeded in `common.sh` and PBKDF2-hashed at render like existing clients).
- Doc: **new `docs/plan-tenant-personas-authelia.md`** — persona × service access matrix
  (the table below), group catalog, and the Authelia diff. Persona table:

  | User | Authelia groups | Capsule access | Vault DB role | Grafana | SeaweedFS |
  |---|---|---|---|---|---|
  | `admin` | all `*-admin` | tenant owner (capsule-admin) | full | Admin | Admin |
  | `rbr-admin` | `rbr-db-admin` | Tenant `rbr` owner | `rbr-db-admin` | rbr/Admin | rbr bucket rw |
  | `rbr-ver-admin` | `rbr-ver-db-admin` | admin in `rbr-ver*` (RoleBinding) | `rbr-ver-db-admin` | rbr/Editor | rbr-ver bucket rw |
  | `rbr-ver-dev` | `rbr-ver-dev` | edit in `rbr-ver*` (RoleBinding) | `app`/`readonly` | rbr/Editor | rbr-ver bucket ro |
  | `rbr-po` | `rbr-po` | view across `rbr-*` (Capsule) | — | rbr/Viewer | rbr-* buckets ro |
  | `unrelated` | — | forbidden | — | — | — |

## Workstream B — Capsule + proxy + gangplank

- **Capsule install** in `scripts/setup.sh` Phase 0 (chart `oci://ghcr.io/projectcapsule/charts/capsule`,
  pin per integration-plan; `capsuleUserGroups` = the tenant/admin OIDC groups, prefixed to match
  Authelia claims). Verify `kubectl get crd tenants.capsule.clastix.io`.
- **Kind OIDC**: replace legacy `--oidc-*` flags plan with a structured **`AuthenticationConfiguration`**
  file mounted into the control-plane (`k8s/kind-cluster.yaml.tpl` + a new authn config tpl) —
  Authelia issuer + CA (`extraMounts`), `audienceMatchPolicy: MatchAny` for `kubernetes`+`gangplank`,
  `email` username / `groups` groups claim mapping. Render in `scripts/setup.sh`.
- **Tenant manifest** (`manifests/capsule-tenant-rbr.yaml`): one Tenant `rbr`, owners =
  `oidc:capsule-admin` + `oidc:rbr-db-admin`, `additionalRoleBindings` = `oidc:rbr-po`→`view`
  tenant-wide. Namespaces `rbr-ver`/`rbr-ver-db` carry label `capsule.clastix.io/tenant: rbr`.
- **Per-driver-group RoleBindings** (`rbr-ver-db-admin`→admin, `rbr-ver-dev`→edit, in `rbr-ver`+
  `rbr-ver-db`) are **generated by Kyverno** on namespace create (Workstream D).
- **capsule-proxy** (Helm) behind a Traefik IngressRoute on a `capsule-proxy.<dashed-ip>.sslip.io`
  host; CA = its own ingress TLS.
- **gangplank** (`peak-scale/gangplank` Helm): env `GANGPLANK_CONFIG_AUTHORIZE_URL`/`_TOKEN_URL`/
  `_REDIRECT_URL` → Authelia; `apiServerURL` → capsule-proxy ingress; `clusterCAPath` → proxy CA;
  `usernameClaim=email`. Traefik IngressRoute on `gangplank.<dashed-ip>.sslip.io`.
- Doc: rewrite `docs/capsule-integration-plan.md` (Authelia, one-Tenant-per-constructor, proxy+
  gangplank, AuthenticationConfiguration) and `docs/capsule-research.md` (correct Dex→Authelia,
  mark proxy/gangplank in-scope). Personas → reference new personas doc.

## Workstream C — DB config user hardening

In `demo/self-service-setup.sh` Vault/Postgres setup:
- Create `rbr_ver_vde_config` (LOGIN, CREATEROLE, no ownership/superuser); repoint
  `database/config/rbr-ver-max` `username` to it; keep DDL owner/admin/reader roles.
- Enable Vault `database/rotate-root/rbr-ver-max` after config so the connection password is
  Vault-owned; remove the KV-stored config password from any plaintext path.
- Doc: update `docs/plan-self-service-dynamic-creds-pgadmin.md` ("config user + root rotation"
  subsection; note no superuser is ever used for role lifecycle).

## Workstream D — Kyverno

- Install Kyverno (Helm) in `scripts/setup.sh` Phase 0.
- Policies (`manifests/kyverno/`): `generate-tenant-rolebindings.yaml` (driver-group dev/admin
  RoleBindings keyed off the `capsule.clastix.io/tenant` label + a driver-group label),
  `generate-default-networkpolicy.yaml`, `require-resources-probes.yaml`,
  `disallow-privileged.yaml`, `restrict-image-registries.yaml`. `validationFailureAction: Audit`
  initially; flip to `Enforce` once clean.
- Doc: **new `docs/plan-kyverno-policies.md`** — policy catalog, generate vs validate rationale,
  Audit→Enforce rollout, interaction with Capsule.

## Workstream E — Sample app

- Parameterize `app/helm/demo-app` values for the tenant: namespace `rbr-ver`, DB host
  `pooler-rbr-ver-rw.rbr-ver-db` (runtime) / `verstappen-rw.rbr-ver-db` (migrations), `database.name`
  per cluster, `credentialsMode=static`, `staticSecret` → the db `ClusterSecretStore` path that the
  pgAdmin plan repoints to (`database/static-creds/app`).
- Image: build `app/Dockerfile`, `kind load docker-image` in `self-service-setup.sh` (or push to a
  local registry if one exists).
- **ArgoCD owns the actual apply** (Workstream F); script only builds/loads + commits values.
- Doc: extend `docs/plan-self-service-dynamic-creds-pgadmin.md` with an "App deployment" section.

## Workstream F — ArgoCD (GitOps)

- Install ArgoCD (Helm) in `scripts/setup.sh` Phase 0; SSO via Authelia (`oidc.config` in
  `argocd-cm`, `argocd-rbac-cm` maps `argocd-admin`→`role:admin`); Traefik IngressRoute on
  `argocd.<dashed-ip>.sslip.io`.
- **App-of-apps** (`manifests/argocd/root-app.yaml` → child Applications): demo-app chart,
  Capsule Tenant + namespace labels, Kyverno policies, Grafana org/datasources. Source = this repo.
- `self-service-setup.sh setup local`: bootstrap ArgoCD → build/load image → apply root Application;
  `verify` checks Application `Synced/Healthy`; `teardown` deletes root app then namespaces/tenant.
- Argo Events/Workflows/Rollouts remain documented Phase 2 (unchanged event-driven pgAdmin).
- Doc: **new `docs/plan-argocd-gitops.md`** — install, Authelia SSO + RBAC, app-of-apps tree,
  script handoff (no double-management), Phase-2 boundary.

## Workstream G — SeaweedFS OIDC

- Admin UI: enable auth + Authelia OIDC per the linked wiki (Admin-UI / Admin-UI-OIDC) in
  `scripts/setup.sh` SeaweedFS block; `seaweedfs-admin`/`admin` → full.
- S3 API: add `-iam.config` JSON (`seaweedfs/config/iam.json`) with `sts.providers` (Authelia
  issuer/clientId/jwksUri/scopes) + roles (`S3AdminRole`, `rbr-ver-rw`, `rbr-po-ro`) + trust
  policies on `oidc:groups`; policies use `${jwt:groups}`/`${jwt:email}`.
- Split static identities in `seaweedfs/config/identities.json`: separate `loki` and `barman` keys
  (machine, static); add per-tenant backup bucket + identity. Update Loki/Barman configs to the
  split keys.
- Doc: **new `docs/plan-seaweedfs-oidc.md`** — admin-UI + S3 OIDC config, IAM roles/trust policies,
  static-vs-OIDC coexistence, per-tenant bucket map.

## Workstream H — Monitoring (Capsule + Calico)

- Tigera `FelixConfiguration`: `prometheusMetricsEnabled: true` (+ typha/kube-controllers metrics).
- ServiceMonitors (`monitoring/...`): capsule-controller-manager, capsule-proxy, calico-node (felix),
  typha, calico-kube-controllers.
- Import upstream **Capsule** + **Calico** Grafana dashboards as `grafana_dashboard_*.yaml` configmaps.
- Doc: note in `architecture-overview.md` Component Inventory + dashboards list.

## Workstream I — Demo + architecture docs

- `docs/demo-plan-eso-vault-and-self-service.md`: add Path-B steps — tenant login via gangplank →
  `kubectl get -n rbr-ver` through capsule-proxy (dev vs po vs unrelated), ArgoCD sync of demo-app,
  Kyverno enforce demo (reject a privileged pod), SeaweedFS OIDC browse, config-user/root-rotation.
- `docs/architecture-overview.md`: expand the system diagram + Component Inventory with
  capsule-system, capsule-proxy, gangplank, kyverno, argocd, SeaweedFS OIDC, Calico metrics; add a
  "Self-Service tenancy" section and the persona matrix; mark target-state vs live where they differ.

## Files (representative)

| Path | Action |
|---|---|
| `authelia/config/users_database.yml`, `authelia/config/configuration.yaml.tpl`, `scripts/common.sh` | new users/groups/OIDC clients |
| `scripts/setup.sh`, `k8s/kind-cluster.yaml.tpl` (+ new authn config tpl) | Kind AuthenticationConfiguration; install Capsule, capsule-proxy, gangplank, Kyverno, ArgoCD |
| `demo/self-service-setup.sh` | `rbr_ver_vde_config` + rotate-root; build/load app image; ArgoCD bootstrap + root app; setup/verify/teardown verbs |
| `manifests/capsule-tenant-rbr.yaml`, `manifests/kyverno/*`, `manifests/argocd/*` | new |
| `app/helm/demo-app/values-rbr-ver.yaml` | tenant values |
| `seaweedfs/config/{iam.json,identities.json}`, SeaweedFS run flags in `scripts/setup.sh` | OIDC + split keys |
| `monitoring/...` ServiceMonitors + dashboards | Capsule/Calico |
| Docs: rewrite `capsule-research.md`, `capsule-integration-plan.md`; update `plan-self-service-dynamic-creds-pgadmin.md`, `architecture-overview.md`, `demo-plan-eso-vault-and-self-service.md`; new `plan-tenant-personas-authelia.md`, `plan-kyverno-policies.md`, `plan-argocd-gitops.md`, `plan-seaweedfs-oidc.md` | docs |

## Open validation items (resolve during execution, via deepwiki/upstream)

- gangplank Helm chart values + exact `AuthenticationConfiguration` schema for the Kind K8s version.
- SeaweedFS **Admin UI** OIDC keys (deepwiki lacked the Admin-UI wiki; follow user-linked pages).
- capsule-proxy ↔ gangplank CA/audience wiring end-to-end.
- Calico (Tigera operator) exact ServiceMonitor selectors + dashboard IDs.
- Confirm Capsule chart/K8s/Kind-node version pin still current.

## Execution order (per user)

0. **Save this plan into the repo**: copy to `docs/plan-self-service-setup-local.md` (the master
   plan / index linking the per-workstream docs).
1. **Workstream I first** — author/refresh the doc set: `architecture-overview.md`,
   `demo-plan-eso-vault-and-self-service.md`, rewrite `capsule-research.md` +
   `capsule-integration-plan.md` (Dex→Authelia), update `plan-self-service-dynamic-creds-pgadmin.md`,
   and create the new docs (`plan-tenant-personas-authelia.md`, `plan-kyverno-policies.md`,
   `plan-argocd-gitops.md`, `plan-seaweedfs-oidc.md`).
2. Then implementation Workstreams A→H (identity, Capsule/proxy/gangplank, DB config user, Kyverno,
   app, ArgoCD, SeaweedFS OIDC, monitoring).

## Verification (end-to-end, local)

> **Boundary (Workstream J):** `scripts/setup.sh` installs the cluster + platform but creates **no
> tenant**; the `rbr/ver` tenant instance is owned by `demo/self-service-setup.sh`. Canonical order:
> `setup.sh local` → `monitoring/setup.sh local` → `self-service-setup.sh setup local`. One-shot:
> `setup.sh local --with-tenant`.

1. `scripts/setup.sh local` → Capsule, capsule-proxy, gangplank, Kyverno, ArgoCD installed;
   `kubectl get crd tenants.capsule.clastix.io`; ArgoCD UI loginable via Authelia (`admin`).
   **No pollution:** `kubectl get ns | grep rbr-ver` empty, no `rbr-root` Application, no `Tenant rbr`.
   **Node pool:** `kubectl get nodes -l node-role.kubernetes.io/app` shows **2** nodes (8 total).
1b. `monitoring/setup.sh local` → Grafana operator + datasources up (hard requirement for step 2).
2. `demo/self-service-setup.sh setup local` → Tenant `rbr` Active; `rbr-ver`/`rbr-ver-db` labeled;
   Kyverno-generated RoleBindings present; ArgoCD root app `Synced/Healthy`; demo-app pods Running
   in `rbr-ver` and serving (not crash-looping); `verstappen-app` secret is Vault-static-role-rotated.
   **Scheduling:** `demo-app` and `pooler-verstappen-rw` pods land on `app`-role nodes; postgres
   instances stay on `postgres` nodes. **Hard-require:** running step 2 without step 1b fails fast.
3. **Personas**: gangplank dispenses kubeconfig; `rbr-ver-dev` can `get/edit` in `rbr-ver*` but not
   other namespaces; `rbr-po` can `get` across `rbr-*` read-only; `unrelated` forbidden. Grafana
   roles match the matrix.
4. **DB config user**: `database/config/rbr-ver-max` uses `rbr_ver_vde_config`; `vault read
   database/creds/...` still mints roles; no superuser in the path; root password rotated.
5. **Kyverno**: privileged pod rejected (after Enforce); missing-limits pod flagged/blocked.
6. **SeaweedFS**: admin UI OIDC login works; S3 OIDC browse scoped by group; Loki/Barman still write
   via static keys; per-tenant backup bucket present.
7. **Monitoring**: Capsule + Calico dashboards render with live data.
8. `teardown local` removes ArgoCD root app, namespaces, and Tenant cleanly.
