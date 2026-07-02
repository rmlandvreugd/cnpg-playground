# Plan: Adopt official Kyverno charts (engine 3.8.1, kyverno-policies 3.8.1, policy-reporter 3.7.4)

Beads: **`cnpg-playground-4p8`** (epic) → **`6w2`** engine upgrade → **`1pk`**
policies-chart adoption, **`k0e`** policy-reporter (1pk + k0e depend on 6w2).
Research via deepwiki (kyverno/kyverno, kyverno/policies, kyverno/policy-reporter),
2026-07-02.

## Context
Today the cluster runs the **kyverno engine chart `3.4.2`** (pinned in
`scripts/common.sh:203`, installed imperatively in `scripts/setup.sh`), plus **5
hand-written ClusterPolicies** delivered by the `kyverno-policies` ArgoCD app
(`manifests/kyverno/`):

| policy | type | official-chart equivalent? |
|---|---|---|
| `disallow-privileged` | validate | ✅ PSS Baseline `disallow-privileged-containers` |
| `require-resources-probes` | validate | ✅ `require-pod-probes` + `require-requests-limits` |
| `restrict-image-registries` | validate | ✅ `restrict-image-registries` |
| `generate-default-networkpolicy` | generate | ❌ none (bundle is validate-only) |
| `generate-tenant-rolebindings` | generate | ❌ none (custom tenant automation) |

There is no `policy-reporter` today — PolicyReports exist (kyverno emits them) but
there is no UI/aggregation/alerting over them.

**Goal:** move the generic guardrails onto the upstream, CEL-based, maintained
policy bundle; upgrade the engine; and add reporting/visibility — while keeping the
two bespoke `generate-*` policies that encode this repo's tenant model.

## Research findings (deepwiki)

### kyverno engine 3.4.2 → 3.8.1  *(DONE — see verification below)*
- **Both 3.4.2 and 3.8.1 are v3 charts** (CRDs at apiVersion `v1`). `upgrade.fromV2`
  is a **v2→v3-only flag and must NOT be set** within the v3 series — the chart's
  own validation rejects it. Existing `kyverno.io/v1` ClusterPolicy manifests admit
  and work unchanged, so our 5 policies do not need rewriting.
- Stored-version migration is handled automatically by the chart default
  **`crds.migration.enabled=true`**, which runs a post-upgrade
  `kyverno-migrate-resources` Job. No `--set` needed; the scripted install keeps
  chart defaults.
- Minimum Kubernetes **`>=1.25.0`** (live cluster is 1.36 → fine).
- 3.8.x **enables `--generateValidatingAdmissionPolicy` / `--validatingAdmissionPolicyReports`
  by default**. Our validate policies are JMESPath (foreach/deny), not CEL, so they
  are not VAP-convertible → no VAPs are generated (verified: none). No new RBAC gaps.
- Several engine minors crossed; the background-controller RBAC fix from `anu`
  (`kyverno/background-controller-rbac.yaml`, label
  `rbac.kyverno.io/aggregate-to-background-controller`) survives the upgrade —
  `generate-tenant-rolebindings` still produces all 4 tenant RoleBindings.

### kyverno-policies chart 3.8.1
- **Correction (verified via `helm template`):** the chart ships **only Pod
  Security Standards** — `podSecurityStandard: baseline` (11 ClusterPolicies) or
  `restricted`. It does **not** ship `require-pod-probes`, `require-requests-limits`,
  or `restrict-image-registries` equivalents. So it overlaps exactly **1** of our
  custom policies: the hand-written `disallow-privileged` (whose intent is a subset
  of PSS baseline's `disallow-privileged-containers` + `disallow-host-namespaces` +
  `disallow-host-path`).
- `policyType` selects `ClusterPolicy` (default) or `ValidatingPolicy` (CEL / VAP,
  kyverno ≥1.17). `validationFailureAction` (Audit vs Enforce) is configurable.
- Does **not** cover our other four customs → `require-resources-probes`,
  `restrict-image-registries`, `generate-default-networkpolicy`, and
  `generate-tenant-rolebindings` all stay hand-written in `manifests/kyverno/`.

### policy-reporter chart 3.7.4
- Watches `PolicyReport`/`ClusterPolicyReport`, exposes **Prometheus metrics**, an
  optional **UI** (`ui.enabled`), the **Kyverno plugin** (`plugin.kyverno.enabled`
  — policy details/live results in the UI), and push **targets** (Loki, Slack,
  Elasticsearch, …). Creates its own RBAC (ClusterRole/binding) and a TargetConfig
  CRD. Works with current-era Kyverno; no engine upgrade strictly required, but
  sequence it after the upgrade for a single validated end state.

## Phased plan (3 beads, ordered)

### Phase 1 — Engine upgrade 3.4.2 → 3.8.1 *(DONE, `cnpg-playground-6w2`)*
- Bumped `KYVERNO_CHART_VERSION` default `3.4.2 → 3.8.1` in `scripts/common.sh`
  (with a comment on the v3/migration/k8s-floor facts). **No** `--set` changes: the
  chart's default `crds.migration.enabled=true` migrates stored versions on upgrade,
  and `upgrade.fromV2` is deliberately not set (v2→v3 only). Install stays
  chart-defaults; `background-controller-rbac.yaml` re-apply already lives in setup.sh.
- **Verified live** (in-place `helm upgrade` on `kind-k8s-local`, chart 3.8.1 /
  kyverno v1.18.1): migration Job `Complete`; CRD stored version `["v1"]`; all 5
  ClusterPolicies `Ready=True`; `generate-tenant-rolebindings` produced all 4 tenant
  RoleBindings (rbr-ver + rbr-ver-db → admin/edit); no background/admission-controller
  errors; no VAPs generated; `kyverno-policies` ArgoCD app `Synced`/`Healthy`.

### Phase 2 — Adopt kyverno-policies chart 3.8.1 *(DONE, `cnpg-playground-1pk`)*
- **Scope corrected mid-flight** (see analysis above): the chart is PSS-only, so it
  supersedes just `disallow-privileged`, not three customs. Per user decision:
  *adopt PSS baseline in Audit cluster-wide, exclude platform/system namespaces,
  retire only `disallow-privileged`, keep the other four customs.*
- **Delivery — imperative `helm_upgrade_install` in setup.sh** (not ArgoCD): the
  `rbr` AppProject restricts `sourceRepos` to this git repo (no external helm-repo
  sources), and PSS is platform infra like the engine + capsule-proxy already
  installed imperatively. `KYVERNO_POLICIES_CHART_VERSION=3.8.1` (chart lives in the
  `https://kyverno.github.io/kyverno/` repo, not the ghcr OCI registry).
- **Values** (`kyverno/policies-values.yaml`): `podSecurityStandard: baseline`,
  `policyType: ClusterPolicy`, `validationFailureAction: Audit`.
  - `ClusterPolicy` (not `ValidatingPolicy`): the CEL `ValidatingPolicy` +
    `vpolExclude.excludeNamespaces` path throws `no such key: namespace` **error**
    results during background scans (chart bug); `ClusterPolicy` background-scans
    cleanly and matches the remaining custom policies' kind.
  - **Namespace exclusion via `policyExclude`** (keyed by policy name, applies to all
    of a policy's rules) — *not* engine `resourceFilters`, which only gate the
    admission webhook and do **not** stop background PolicyReport generation. A YAML
    anchor lists the 23 platform namespaces once and reuses it across all 11 baseline
    policies, so PSS evaluates only tenant/app workloads (`rbr-*`, `default`).
- **Retired** `manifests/kyverno/disallow-privileged.yaml` (pruned by the
  `kyverno-policies` ArgoCD app after commit+push). Kept the four other customs.
- **Verified live** (chart 3.8.1, ClusterPolicy): reports exist **only** in tenant
  namespaces (`rbr-ver`, `rbr-ver-db`) — **zero** PolicyReports in all platform
  namespaces; `rbr-ver` shows 24 `pass` PSS results; no orphaned reports.
- **Out of scope, filed as follow-up:** pre-existing JMESPath **error** results in
  the kept customs `require-resources-probes` (`length(@)` on nil `resources`) and
  `restrict-image-registries` (`containers + initContainers` — invalid `+` in
  JMESPath) when background-scanning workload controllers (Deployment/ReplicaSet).
  Surfaced now that reporting is clean; unrelated to PSS adoption.

### Phase 3 — Add policy-reporter 3.7.4 *(depends on Phase 1)*
- Install policy-reporter (ArgoCD Application or setup.sh) with `ui.enabled=true`,
  `plugin.kyverno.enabled=true`, Prometheus `metrics`/ServiceMonitor on (repo has a
  monitoring stack), and optionally a Loki target (cluster already runs Loki).
- Expose the UI behind Traefik + Authelia forward-auth, consistent with the other
  edge services (see the 5sq SSO work).
- **Verify:** UI lists PolicyReports across namespaces; Kyverno plugin shows policy
  detail; Prometheus scrapes `policy_report_*` metrics; a deny/audit shows up.

## Risks / notes
- **CRD stored-version migration** (not v2→v3 — both are v3 charts) is auto-run by
  `crds.migration.enabled=true`. Back up ClusterPolicies before upgrade and validate
  the migration Job completed / `kubectl get crd policies.kyverno.io
  -o jsonpath='{.status.storedVersions}'` is `["v1"]`. *(Phase 1 confirmed clean.)*
- **Policy-name collisions**: don't leave a custom policy and its chart equivalent
  both enforcing — retire the custom one in the same change that enables the chart one.
- **CEL prerequisites**: the 3.8.1 bundle is CEL-based; confirmed fine on the 3.8.1
  engine (Phase 1 first).
- Keep `Audit` first, flip to `Enforce` per-policy only after reviewing PolicyReports
  in policy-reporter.
