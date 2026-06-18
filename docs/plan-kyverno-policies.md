# Kyverno Policies Plan (local region)

Status: plan 2026-06-18. Complements Capsule (`capsule-integration-plan.md`) and the persona model
(`plan-tenant-personas-authelia.md`).

## Why Kyverno here

Capsule enforces tenancy but its grants (`owners`, `additionalRoleBindings`) are **tenant-wide**.
With one Tenant per constructor (`rbr`), the **driver-group-scoped** dev/admin RoleBindings
(`rbr-ver` + `rbr-ver-db` only) must come from elsewhere — Kyverno **generate** policies are the
clean fit, reacting to namespace labels. Kyverno also adds baseline pod governance and a default
NetworkPolicy (replacing Capsule's deprecated NetworkPolicy generator).

Install: Helm `kyverno/kyverno` in `scripts/setup.sh` Phase 0 (namespace `kyverno`, not a tenant
namespace). Cluster admin = `k8s-admin` (no dedicated `kyverno-admin` group).

## Policy set

Manifests under `manifests/kyverno/`. All start `validationFailureAction: Audit`, flip to `Enforce`
once the cluster is clean.

### Generate (the load-bearing ones)

1. **`generate-tenant-rolebindings.yaml`** — on a namespace with labels
   `capsule.clastix.io/tenant` + `cnpg.io/driver-group=<dg>`, generate per-namespace RoleBindings:
   - `<constructor>-<dg>-db-admin` (Authelia group) → ClusterRole `admin`
   - `<constructor>-<dg>-dev` (Authelia group) → ClusterRole `edit`
   - i.e. for `rbr-ver`/`rbr-ver-db`: `rbr-ver-db-admin`→admin, `rbr-ver-dev`→edit, scoped to those
     namespaces only. Subjects are `kind: Group, name: oidc:<group>`.
2. **`generate-default-networkpolicy.yaml`** — on tenant namespace create, generate a default-deny
   ingress NetworkPolicy + allow-same-namespace + allow from `traefik`, `cnpg-system`, `monitoring`,
   `external-secrets`. Keeps cross-namespace pooler→DB and Traefik TCP working while denying the rest.

### Validate (baseline governance)

3. **`disallow-privileged.yaml`** — deny `privileged`, host namespaces, `hostPath` in tenant
   namespaces (Pod Security "baseline/restricted"-style).
4. **`require-resources-probes.yaml`** — require CPU/memory requests+limits and liveness/readiness
   probes on workloads in tenant namespaces.
5. **`restrict-image-registries.yaml`** — only allow images from approved registries (local
   registry / `ghcr.io` / `docker.io/cloudnative-pg` / the demo-app image). Blocks arbitrary pulls.

### Mutate (optional, light)

6. **`add-tenant-labels.yaml`** — stamp `cnpg.io/driver-group` onto workloads from the namespace, so
   dashboards/metrics can group by driver group.

## Rollout

1. Install Kyverno; apply all policies in **Audit**.
2. Run `setup local` + `self-service-setup.sh setup local`; check PolicyReports are clean.
3. Flip generate policies are always active; flip validate policies (3–5) to **Enforce**.
4. Demo: a privileged pod / missing-limits pod is rejected; a new driver-group namespace
   auto-gets its RoleBindings + NetworkPolicy.

## Interaction notes

- **Order vs Capsule:** Capsule labels/owns the namespace; Kyverno reacts to the label. Ensure the
  namespace carries both `capsule.clastix.io/tenant` and `cnpg.io/driver-group` (set in the
  ArgoCD-managed namespace manifest).
- **ArgoCD:** Kyverno policies are reconciled by the ArgoCD app-of-apps (`plan-argocd-gitops.md`),
  so policy changes are GitOps-driven. Generated resources are owned by Kyverno, not ArgoCD —
  exclude them from ArgoCD diffing (`generators`/`ignoreDifferences`) to avoid sync loops.
- **Monitoring:** Kyverno exposes `/metrics`; add a ServiceMonitor and (optionally) the upstream
  Kyverno dashboard alongside the Capsule/Calico ones.

## Verification

- New label set on `rbr-ver` → RoleBindings `rbr-ver-db-admin`(admin)/`rbr-ver-dev`(edit) exist,
  and **not** in any non-`rbr-ver` namespace.
- Default-deny NetworkPolicy present; pooler→`verstappen-rw` and Traefik TCP still connect.
- After Enforce: `kubectl run --privileged` rejected; a pod without limits rejected.
- `kubectl get policyreport -A` clean for compliant workloads.

## Sources

- Kyverno: https://kyverno.io/docs/
- Generate (sync, data/clone): https://kyverno.io/docs/writing-policies/generate/
- Pod Security: https://kyverno.io/policies/pod-security/
- Capsule + policy engines: https://projectcapsule.dev/docs/integrations/
