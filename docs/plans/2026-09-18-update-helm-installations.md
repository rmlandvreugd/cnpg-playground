# Plan: update all outdated helm chart installations

## Goal

Bring every chart in `scripts/common.sh` from its current `*_CHART_VERSION` to the
ArtifactHub-latest stable release. Source data: `helm-diff.log` (4337 lines, captured
2026-09-17 by `uv run scripts/check-helm-versions.py --diff-values`).

Status snapshot at log capture:

```
Summary: 6 up-to-date  24 update(s) available  0 newer (out of constraint range)
         1 error(s)  0 skipped  1 local (Chart.yaml)
```

Six charts already current: metallb, gangplank, loki, tempo, caretta, reloader.
demo-app is local-path (skipped). CILIUM is registered but absent from `common.sh`
(error row, out of scope).

---

## Risk-tier classification

The 24 outdated charts are split into four tiers by jump magnitude and chart-major
break risk. Same-tier updates can be batched; tier boundaries force a `helm diff`
review and a fresh cluster smoke test before continuing.

### Tier 1 — single patch/minor jump (low risk)

Batch apply, single cluster smoke test at the end.

| Chart | From → To | Notes |
|---|---|---|
| kubelet-csr-approver | 1.2.14 → 1.2.15 | patch |
| tigera-operator | v3.32.0 → 3.32.2 | patch (existing `v` prefix preserved) |
| metrics-server | 3.13.1 → 3.14.0 | minor |
| traefik | 41.0.1 → 41.6.0 | 5 patches within v41 (helm-diff warns `safeNaming` opt-in — default safe) |
| argo-rollouts | 2.41.0 → 2.43.2 | patches |
| argo-events | 2.4.22 → 2.4.27 | patches |
| cert-manager | v1.20.2 → 1.21.2 | minor (existing `v` prefix dropped) |

### Tier 2 — multi-minor / large gap (medium risk)

Each gets a `helm-diff --rendered` review (`scripts/check-helm-versions.py
--diff-values --rendered --from <key>=<old>`) before applying. Smoke test after
each chart's apply, not batched.

| Chart | From → To | Notes |
|---|---|---|
| trust-manager | v0.12.2 → 0.25.0 | 13 minor bumps — `trust-manager` saw several CRD changes; review every diff hunk. **Pre-condition**: cert-manager tier-1 already applied. |
| capsule | 0.13.6 → 0.14.6 | minor; CapsuleController v1beta1→v1 API promoted. |
| capsule-proxy | 0.13.5 → 0.14.1 | minor; tracks capsule. |
| kyverno | 3.8.1 → 3.9.1 | minor; `ValidatingPolicy` GA. |
| kyverno-policies | 3.8.1 → 3.9.1 | minor; tracks kyverno (must upgrade together with helm-diff image-tag sync). |
| policy-reporter | 3.7.4 → 3.10.0 | 3 minors; CRD additions. |
| ESO | 2.4.1 → 2.10.0 | 6 minors; CRD additions; api-version promotions. |
| cloudnative-pg | 0.28.0 → 0.29.0 | minor; operator-side only, no app schema change. |
| plugin-barman-cloud | 0.6.0 → 0.8.0 | 2 minors; tracks cloudnative-pg. |
| grafana-operator | 5.22.2 → 5.25.0 | 3 minors; GrafanaDashboard CRD changes. |
| mimir | 6.0.6 → 6.2.0 | 2 minors; storage schema additions. |
| alloy | 1.8.0 → 1.12.1 | 4 minors; config format changes likely. |
| otel-collector | 0.158.2 → 0.173.1 | 15 minors; **breaking**: deprecated `k8sattributes`/`k8snode` processor names must be rewritten (new `OpenTelemetry.Collector.Processor.RewriteDeprecatedComponentNames` flag) |
| radar | 1.7.9 → 1.14.1 | 7 minors; CRD additions. |

### Tier 3 — chart-major bump (high risk)

One chart at a time. Each requires its own branch + cluster rebuild + smoke test +
extend hold-back window (24 h on hub + 24 h on at least one spoke) before
promoting to the next tier-3 chart.

| Chart | From → To | Notes |
|---|---|---|
| argocd | 9.7.0 → 10.9.2 | Helm chart major bump; `ApplicationSet` CRD additions; intentional removal of liveness probe on controller (per `argoproj/argo-cd#9557` — see helm-diff log); rollout strategy pinned to `Recreate` only (operator limitation, see `values.yaml` WARNING in log). |
| argo-workflows | 1.0.17 → 2.0.6 | Helm chart major bump; controller v3 server-side apply; workflow CRD additions. |
| kube-prometheus-stack | 86.2.3 → 91.4.1 | 5 chart majors; Prometheus operator major; alerting rule & recording rule churn; CRD storage version promotions; **biggest blast radius** — every dashboard / alert / rule touches this. |

### Tier 4 — chart-major-reset / false-positive (no action)

These show ✓ ok in the summary because `current > latest_abs` numerically, but the
"latest" ArtifactHub returns is from a *different chart lineage* in the same repo.
Listed here so future runs don't flag them again.

| Chart | Current | AH "latest" | Diagnosis |
|---|---|---|---|
| loki | 13.5.0 | 7.3.0 | AH indexes the new `loki-single-binary` package's lineage; the project pins the monolithic `loki` chart at v13. Confirm via `https://artifacthub.io/packages/helm/grafana/loki` (we are on `grafana/loki`, the monolithic chart). No update needed. |
| tempo | 2.25.2 | 1.24.4 | Same situation: `grafana/tempo` monolithic chart is at v2.x; AH's "latest" appears to be a re-numbered package. Verify before touching. |

**Fix the script later** (separate PR): when `find_latest` finds a version
*lower* than the current pin for an AH-tracked chart, treat as "ok, lineage drift"
rather than re-checking. Out of scope here.

---

## Install order (respects `scripts/setup.sh` sequencing)

The setup script applies charts in dependency order. The plan follows the same
order so we don't have to tear down / rebuild between charts.

| # | Phase | Chart | Tier | Pre-conditions |
|---|---|---|---|---|
| 1 | 1 | tigera-operator | 1 | none (pre-cluster bootstrap) |
| 2 | 2 | kubelet-csr-approver | 1 | cluster up |
| 3 | 3 | metallb | (no-op) | already at 0.16.1 |
| 4 | 4 | cert-manager | 1 | pre-cluster bootstrap done |
| 5 | 4 | trust-manager | 2 | cert-manager 1.21.x up |
| 6 | 5 | traefik | 1 | cert-manager up |
| 7 | 6 | metrics-server | 1 | cluster networking up |
| 8 | 6 | reloader | (no-op) | already at 2.2.17 |
| 9 | 7 | capsule | 2 | traefik up (gateway) |
| 10 | 7 | capsule-proxy | 2 | capsule up |
| 11 | 7 | kyverno | 2 | cluster up |
| 12 | 7 | kyverno-policies | 2 | kyverno up |
| 13 | 8 | argocd | **3** | cert-manager + traefik up |
| 14 | 9 | cloudnative-pg | 2 | cluster up |
| 15 | 9 | plugin-barman-cloud | 2 | cloudnative-pg up |
| 16 | 9 | grafana-operator | 2 | cert-manager up |
| 17 | 10 | kube-prometheus-stack | **3** | cert-manager up |
| 18 | 10 | mimir | 2 | object storage up |
| 19 | 10 | alloy | 2 | mimir/loki/tempo up |
| 20 | 10 | otel-collector | 2 | cluster up |
| 21 | 11 | radar | 2 | traefik up |
| 22 | 11 | policy-reporter | 2 | kyverno up |
| 23 | 11 | caretta | (no-op) | already at 0.0.16 |
| 24 | 11 | ESO | 2 | cert-manager up |

`gangplank` (no update), `loki`, `tempo` (no update, lineage false-positive),
`cilium` (not in `common.sh`), `demo-app` (local) — skipped.

---

## Execution procedure per tier

### Tier 1 (7 charts)

```bash
# All in one branch — single PR, single review.
# Per chart, just bump the *_CHART_VERSION in common.sh (preserves v-prefix where present).
cd .claude/worktrees/wt-update-helm-tier1
$EDITOR scripts/common.sh   # bump 7 lines
bash -n scripts/common.sh

# For each chart: re-run helm-diff for inspection (no --rendered needed for tier 1):
uv run scripts/check-helm-versions.py --diff-values --chart <key>
# Sanity-check: diff hunks are limited to image-tag bumps / defaults; no schema breaks.

# Smoke test on a fresh cluster:
./scripts/setup.sh --with-tenant && ./scripts/info.sh
./scripts/teardown.sh
```

### Tier 2 (14 charts)

Per chart:

```bash
# 1. Inspect via helm-diff --rendered (structured JSON, easier to skim than diff -u):
uv run scripts/check-helm-versions.py --diff-values --rendered \
    --from TRUST_MANAGER_CHART_VERSION=0.12.2 --to 0.25.0 2>&1 | jq '.[].changes[]?'

# 2. If the diff is non-trivial (CRD additions, apiVersion changes, RBAC changes):
#    read upstream CHANGELOG / release notes for the jumped minor(s).
#    Document any required values.yaml override in the PR.

# 3. Bump common.sh, run bash -n, run uv py_compile on the script.

# 4. Apply on a fresh cluster, smoke-test the affected workload
#    (e.g. trust-manager → create a test Certificate, verify issuance;
#     kyverno → apply a Policy, verify ClusterPolicyReport).

# 5. Commit per chart (14 small commits) or batched into one tier-2 PR if all smoke
#    tests pass within the same cluster run.
```

### Tier 3 (3 charts — argocd, argo-workflows, kube-prometheus-stack)

```bash
# 1. Each chart on its own branch + PR (3 separate reviews).
# 2. Per chart: full helm-diff inspection + upstream release-notes review
#    + at minimum 24 h hold on hub cluster before applying to spokes.
# 3. For kube-prometheus-stack: also re-validate every dashboard JSON
#    in demo-app/grafana against the new Prometheus rules output.
# 4. Update common.sh + setup.sh together if any chart pins needed adjusting
#    (kube-prometheus-stack 91.x typically needs `prometheus.prometheusSpec.retentionSize`
#    cap to stay under kind disk budget — check after first apply).
```

---

## Validation gates

After each chart apply on the cluster:

| Tier | Gate |
|---|---|
| 1 | `helm list -n <ns>` shows the new revision Ready; `kubectl get pods -n <ns>` all Ready within 2 min. |
| 2 | tier 1 gates + run the chart's CRD smoke test from `scripts/info.sh` if applicable. |
| 3 | tier 2 gates + 24 h hold on hub cluster (no crash, dashboards rendering, alerts firing as expected). |

After all 24 charts applied:

```bash
# Re-run the version checker — every row should now be ✓ ok / ⊙ local / ✗ missing (cilium).
uv run scripts/check-helm-versions.py 2>&1 | tee helm-diff-after.log

# Diff vs. baseline helm-diff.log — should show 24 fewer ⬆ update rows.
diff <(grep '⬆' helm-diff.log) <(grep '⬆' helm-diff-after.log)
```

---

## Rollback strategy

Per chart:

```bash
# helm_upgrade_install() in common.sh self-heals pending-install/upgrade/rollback/failed
# states by rolling back to the last good revision. Manual rollback:
helm history <release> -n <ns>              # find previous revision
helm rollback <release> <revision> -n <ns>  # restore
```

Per tier: if a tier-2 chart breaks a tier-1 chart (e.g. trust-manager 0.25.0 breaks
cert-manager 1.21.x reconciliation), roll back in reverse order (capsule-proxy →
capsule → cert-manager → kubelet-csr-approver), then re-apply the failing tier-2
chart on its own branch with a fix.

Per cluster: `./scripts/teardown.sh && ./scripts/setup.sh --with-tenant` rebuilds
from scratch in ~5 min for a hub cluster, ~3 min for a spoke. Always prefer
rebuild over partial rollback for tier-3.

---

## Scope discipline

- **Don't** touch `cilium` — it's still missing from `common.sh`. Adding a
  `CILIUM_CHART_VERSION=` line is a separate decision (does the project install
  Cilium or is Calico the chosen CNI?). Out of scope here.
- **Don't** touch `loki` / `tempo` versions — false-positive lineage drift (tier 4).
- **Don't** touch chart `*_IMAGE` env-vars (plan `docs/plans/2026-09-17-…md` §13 out-of-scope).
- **Don't** touch `tmp/check-helm-versions.py` — it's the predecessor, will be
  removed when `scripts/check-helm-versions.py` ships.

---

## Out of scope (deferred to follow-up plans)

- `cilium` chart decision (separate PR).
- Fix `find_latest()` in `scripts/check-helm-versions.py` so loki/tempo lineage drift
  is auto-classified (separate PR).
- Update ArgoCD `targetRevision` to a non-`vault` branch ref (per
  `docs/plans/2026-09-17-…md` §13 out-of-scope; the four Application manifests
  reference git branch `vault`, not chart versions).
- Container image tag bumps (AUTHELIA_IMAGE, GRAFANA_IMAGE, TRAEFIK_IMAGE,
  TRAEFIK_VERSION, VAULT_IMAGE, STEP_CA_IMAGE, RUSTFS_IMAGE, MC_IMAGE,
  REVOCATION_EXPORTER_IMAGE).

---

## Lane assignment when executing

| Lane | Scope | Branch |
|---|---|---|
| `@fixer-1` | Tier 1 batch (7 charts) | `wt-update-helm-tier1` |
| `@fixer-2` | Tier 2 batch (14 charts, one chart per commit) | `wt-update-helm-tier2` |
| `@fixer-3a/b/c` | Tier 3 one chart per branch (3 PRs) | `wt-update-helm-argocd` / `wt-update-helm-argo-workflows` / `wt-update-helm-kps` |
| `@oracle` (optional) | Review tier-3 breaking-change notes, especially kube-prometheus-stack 91.x | post-fix |

No parallelism needed within a tier (single cluster rebuild per tier); tier-3 PRs
can land in parallel since they touch disjoint charts.
