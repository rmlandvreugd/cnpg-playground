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

### kyverno engine 3.4.2 → 3.8.1
- **CRD migration `v2` → `v3`** on the `kyverno.io` group is the headline change.
  Existing **`kyverno.io/v1` ClusterPolicy manifests still admit and work
  unchanged** (v1 is retained), so our 5 policies do not need rewriting.
- The chart provides an **`upgrade.fromV2` value** and a **post-upgrade migration
  hook** (`templates/hooks/post-upgrade-migrate-resources.yaml`) that re-stores
  existing CRs at the new stored version. This must be set/allowed when jumping a
  chart that shipped v2 CRDs to one shipping v3.
- Several engine minor releases are crossed; re-validate the background-controller
  RBAC fix from `anu` (`kyverno/background-controller-rbac.yaml`) still aggregates
  (the `rbac.kyverno.io/aggregate-to-background-controller` label is stable, but
  re-verify get/list/watch+bind land after upgrade).

### kyverno-policies chart 3.8.1
- CEL-based bundle, three categories: **PSS Baseline**, **PSS Restricted**,
  **Best Practices**. Every policy is individually enable/disable-able and each has
  a configurable `validationFailureAction` (Audit vs Enforce) via values.
- Ships equivalents for 3 of our custom policies (table above), plus extras
  (`drop-all-capabilities`, `drop-cap-net-raw`, `require-labels`, etc.).
- Does **not** cover generate policies → `generate-default-networkpolicy` and
  `generate-tenant-rolebindings` stay hand-written in `manifests/kyverno/`.

### policy-reporter chart 3.7.4
- Watches `PolicyReport`/`ClusterPolicyReport`, exposes **Prometheus metrics**, an
  optional **UI** (`ui.enabled`), the **Kyverno plugin** (`plugin.kyverno.enabled`
  — policy details/live results in the UI), and push **targets** (Loki, Slack,
  Elasticsearch, …). Creates its own RBAC (ClusterRole/binding) and a TargetConfig
  CRD. Works with current-era Kyverno; no engine upgrade strictly required, but
  sequence it after the upgrade for a single validated end state.

## Phased plan (3 beads, ordered)

### Phase 1 — Engine upgrade 3.4.2 → 3.8.1 *(depends on nothing)*
- Bump `KYVERNO_CHART_VERSION` default in `scripts/common.sh`.
- Add the `--set upgrade.fromV2=true` (and allow the post-upgrade hook) to the
  `helm_upgrade_install kyverno` call in `scripts/setup.sh`; confirm the CRD
  migration hook completes.
- Re-apply `kyverno/background-controller-rbac.yaml` (already in setup.sh after the
  install) and re-verify aggregation.
- **Verify:** all 5 existing ClusterPolicies `Ready=True`; `generate-tenant-rolebindings`
  still generates the 4 tenant RoleBindings; `kyverno-policies` app Synced/Healthy;
  no CRD-served-version errors. Validate on a clean `teardown && setup … --with-tenant`.

### Phase 2 — Adopt kyverno-policies chart 3.8.1 *(depends on Phase 1)*
- Add a `kyverno-policies` Helm release (values: enable PSS Baseline + Best
  Practices; `validationFailureAction: Audit` to start; set `restrict-image-registries`
  allowed registries to match the current custom policy). Decide delivery: ArgoCD
  Application pointing at the chart vs. `helm_upgrade_install` in setup.sh (prefer
  ArgoCD for parity with the existing app-of-apps).
- **Retire the 3 overlapping hand-written policies** (`disallow-privileged`,
  `require-resources-probes`, `restrict-image-registries`) from `manifests/kyverno/`
  once the chart equivalents are enforcing the same intent — avoid duplicate
  ClusterPolicy names / double reporting. Keep the two `generate-*` policies.
- **Verify:** chart policies admit and report; the retired behaviors still covered
  (e.g. a probe-less Pod is flagged by `require-pod-probes`); no orphaned
  PolicyReports; app(s) Synced.

### Phase 3 — Add policy-reporter 3.7.4 *(depends on Phase 1)*
- Install policy-reporter (ArgoCD Application or setup.sh) with `ui.enabled=true`,
  `plugin.kyverno.enabled=true`, Prometheus `metrics`/ServiceMonitor on (repo has a
  monitoring stack), and optionally a Loki target (cluster already runs Loki).
- Expose the UI behind Traefik + Authelia forward-auth, consistent with the other
  edge services (see the 5sq SSO work).
- **Verify:** UI lists PolicyReports across namespaces; Kyverno plugin shows policy
  detail; Prometheus scrapes `policy_report_*` metrics; a deny/audit shows up.

## Risks / notes
- **CRD v2→v3 migration** is the main risk — take a backup/export of ClusterPolicies
  before upgrade; validate the migration hook ran (`kubectl get crd policies.kyverno.io
  -o jsonpath='{.status.storedVersions}'`).
- **Policy-name collisions**: don't leave a custom policy and its chart equivalent
  both enforcing — retire the custom one in the same change that enables the chart one.
- **CEL prerequisites**: the 3.8.1 bundle is CEL-based; confirmed fine on the 3.8.1
  engine (Phase 1 first).
- Keep `Audit` first, flip to `Enforce` per-policy only after reviewing PolicyReports
  in policy-reporter.
