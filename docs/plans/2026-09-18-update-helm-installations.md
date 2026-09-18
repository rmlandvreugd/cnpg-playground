# Plan: update all outdated helm chart installations

Tracking: epic **cnpg-playground-u9n0** (P1). One bead per tier; see
[Bead map](#bead-map).

## Goal

Bring every chart in `scripts/common.sh` from its current `*_CHART_VERSION` to the
ArtifactHub-latest stable release.

Source data: `helm-diff.log`, produced by
`uv run scripts/check-helm-versions.py --diff-values`. The log is **not committed**
(ANSI-coloured, ~4.3k lines); regenerate it in tier 0 and keep it at the repo root
of the working tree for the final comparison.

Status snapshot (run 2026-09-18):

```
Summary: 6 up-to-date  24 update(s) available  0 newer (out of constraint range)
         1 error(s)  0 skipped  1 local (Chart.yaml)
```

Six charts already current: metallb, gangplank, loki, tempo, caretta, reloader.
demo-app is local-path (skipped). CILIUM is registered in the checker but absent
from `common.sh` (error row, out of scope — cnpg-playground-2he9).

### Source-data defects (fixed)

The first 2026-09-18 run had no values diff for 7 charts. All three causes are
fixed, and a re-run for those 7 charts produced a diff for each one, with the
target versions listed below:

| Defect | Fix | Bead |
|---|---|---|
| `TRUST_MANAGER_CHART_VERSION` was defined twice in `common.sh`. The first `${VAR:-default}` (`0.17.1`) won; the checker read the dead `v0.12.2` line. | One pin in the version block, set to the effective `0.17.1`. | cnpg-playground-u9n0.1 |
| Checker registered MIMIR as chart `mimir`; installer uses `mimir-distributed`. | Registry chart name → `mimir-distributed`. | cnpg-playground-ounx |
| `helm show values` failed with `repo chk-XXXX not found` / `no cached repo found`. | Registry URLs for kyverno-policies and radar returned 404 (they now match the installers). Pre-registered repos with no cached index are now refreshed. `helm repo add/update` failures are reported instead of swallowed. | cnpg-playground-7zdn |

---

## Version-prefix rule

Keep the existing prefix of each pin. If the current pin has a `v`, the new pin
has a `v` too (`v1.20.2` → `v1.21.2`, `v3.32.0` → `v3.32.2`). The checker strips
`v` when it resolves versions (`clean_version()`), but `setup.sh` passes the raw
value to `helm upgrade --version`. Keeping the prefix avoids a mixed-style
`common.sh`.

---

## Risk-tier classification

The 24 outdated pins fall into five groups by jump size and whether anything
installs them. Same-tier charts ship together. Crossing a tier boundary needs a
`helm diff` review and a fresh-cluster smoke test.

### Pin-only — declared but never installed (no smoke test possible)

`ARGO_WORKFLOWS_CHART_VERSION`, `ARGO_EVENTS_CHART_VERSION` and
`ARGO_ROLLOUTS_CHART_VERSION` (`common.sh:250-252`) are not installed by any
script (only `mise.toml` installs the argo-rollouts **CLI**). Bump the pins in the
tier-1 commit so the checker stays green. Deleting them instead is an open
decision: cnpg-playground-u9n0.2.

| Chart | From → To |
|---|---|
| argo-rollouts | 2.41.0 → 2.43.2 |
| argo-events | 2.4.22 → 2.4.27 |
| argo-workflows | 1.0.17 → 2.0.6 (chart major, but inert) |

### Tier 1 — single patch/minor jump (low risk)

Batch apply, one fresh-cluster smoke test at the end.

| Chart | From → To | Notes |
|---|---|---|
| kubelet-csr-approver | 1.2.14 → 1.2.15 | patch |
| tigera-operator | v3.32.0 → v3.32.2 | patch; also drives the `helm template calico-crds` CRD apply in `setup.sh:220` |
| metrics-server | 3.13.1 → 3.14.0 | minor |
| traefik | 41.0.1 → 41.6.0 | minors within v41; new `safeNaming` value is opt-in, default unchanged |
| cert-manager | v1.20.2 → v1.21.2 | minor |

### Tier 2 — multi-minor / large gap (medium risk)

Review each chart's diff first. The `--rendered` mode needs helm ≥ 3.18 and the
helm-diff plugin:

```bash
uv run scripts/check-helm-versions.py --diff-values --rendered \
    --chart <KEY> --from <KEY>=<old> --to <new>
```

| Chart | From → To | Notes |
|---|---|---|
| trust-manager | **0.17.1** → 0.25.0 | 8 minors. Pre-condition: tier 1 cert-manager applied; u9n0.1 dedupe done. |
| capsule | 0.13.6 → 0.14.6 | minor. API-version change claims are unverified — check release notes. |
| capsule-proxy | 0.13.5 → 0.14.1 | minor; ship with capsule. |
| kyverno | 3.8.1 → 3.9.1 | minor. |
| kyverno-policies | 3.8.1 → 3.9.1 | ship with kyverno (same app version). |
| policy-reporter | 3.7.4 → 3.10.0 | 3 minors. |
| ESO | 2.4.1 → 2.10.0 | 6 minors; installed by `scripts/eso-setup.sh`. |
| cloudnative-pg | 0.28.0 → 0.29.0 | minor; installed by `install_cnpg_operator` (`common.sh`). |
| plugin-barman-cloud | 0.6.0 → 0.8.0 | 2 minors; ship with cloudnative-pg. Chart warns only the `Recreate` update strategy is supported. |
| grafana-operator | 5.22.2 → 5.25.0 | 3 minors; installed by `monitoring/setup.sh`. |
| mimir (mimir-distributed) | 6.0.6 → 6.2.0 | 2 minors. |
| alloy | 1.8.0 → 1.12.1 | 4 minors. |
| otel-collector | 0.158.2 → 0.173.1 | 15 minors. **Bump `OTEL_COLLECTOR_IMAGE_TAG` with it** — see below. |
| radar | 1.7.9 → 1.14.1 | 7 minors. |

**otel-collector image exception.** `OTEL_COLLECTOR_IMAGE_TAG=0.153.0`
(`common.sh:265`) is forced through `--set image.tag` (`monitoring/setup.sh:175`).
The new chart defaults `rewriteDeprecatedComponentNames: true`, which renames
`k8sattributes` → `k8s_attributes` and `k8snode` → `k8s_api` in the generated
config. The chart notes older collector images don't know the new names. So move
`OTEL_COLLECTOR_IMAGE_TAG` to the chart's `appVersion` in the same commit, and
update the trailing comment. This is the one image tag in scope. Our
`monitoring/otel-collector/otel-collector-values.yaml` uses neither old name, so no
values rewrite is needed.

### Tier 3 — chart-major bump (high risk)

One chart per branch and PR. Each gets a fresh rebuild and smoke test. No
in-place upgrade: `helm rollback` doesn't revert CRDs.

| Chart | From → To | Notes |
|---|---|---|
| argocd | 9.7.0 → 10.9.2 | Chart major. Adds an **opt-in** application-controller `livenessProbe` (disabled by default, per argoproj/argo-cd#9557) — no change unless enabled. Read the 10.0 upgrade notes for removed/renamed values. |
| kube-prometheus-stack | 86.2.3 → 91.4.1 | 5 chart majors; Prometheus-operator CRD changes; rule churn. Biggest blast radius — every dashboard, alert and rule depends on it. Installed by `monitoring/setup.sh:50` as release `prometheus-operator`. |

### Up to date — lineage false-positive (no action)

These show `✓ ok` because the current pin is numerically **above** the version
ArtifactHub reports as latest. AH tracks a different lineage for them.

| Chart | Current | AH "latest" |
|---|---|---|
| loki | 13.5.0 | 7.3.0 |
| tempo | 2.25.2 | 1.24.4 |

Auto-classifying this in the checker: cnpg-playground-dats (out of scope).

---

## Install order (actual call order)

Order follows `scripts/setup.sh`, which calls `scripts/eso-setup.sh`,
`install_cnpg_operator` / `install_barman_plugin` (`common.sh`) and, last,
`monitoring/setup.sh`. Rebuilding a fresh cluster applies everything in this order,
so no manual sequencing is needed.

| # | Installer | Chart | Tier |
|---|---|---|---|
| 1 | `setup.sh:217` | tigera-operator | 1 |
| 2 | `setup.sh:248` | kubelet-csr-approver | 1 |
| 3 | `setup.sh:261` | metallb | current |
| 4 | `setup.sh:635` | cert-manager | 1 |
| 5 | `setup.sh:649` | trust-manager | 2 |
| 6 | `setup.sh:743` → `eso-setup.sh` | ESO | 2 |
| 7 | `setup.sh:757` | traefik | 1 |
| 8 | `setup.sh:796` | metrics-server | 1 |
| 9 | `setup.sh:814` → `common.sh` | cloudnative-pg | 2 |
| 10 | `setup.sh:815` → `common.sh` | plugin-barman-cloud | 2 |
| 11 | `setup.sh:820` | reloader | current |
| 12 | `setup.sh:828` | capsule | 2 |
| 13 | `setup.sh:836` | capsule-proxy | 2 |
| 14 | `setup.sh:871` | kyverno | 2 |
| 15 | `setup.sh:892` | kyverno-policies | 2 |
| 16 | `setup.sh:899` | argocd | 3 |
| 17 | `setup.sh:1209` | gangplank | current |
| 18 | `setup.sh:1313` | caretta | current |
| 19 | `setup.sh:1332` | radar | 2 |
| 20 | `setup.sh:1363` | policy-reporter | 2 |
| 21 | `monitoring/setup.sh:50` | kube-prometheus-stack | 3 |
| 22 | `monitoring/setup.sh:89` | mimir | 2 |
| 23 | `monitoring/setup.sh:149` | tempo | current |
| 24 | `monitoring/setup.sh:173` | otel-collector | 2 |
| 25 | `monitoring/setup.sh:214` | grafana-operator | 2 |
| 26 | `monitoring/setup.sh:291` | loki | current |
| 27 | `monitoring/setup.sh:298` | alloy | 2 |

Not installed: argo-workflows, argo-events, argo-rollouts (pin-only). Skipped:
cilium (not in `common.sh`), demo-app (local chart). Line numbers are as of commit
`e89e801`.

---

## Execution procedure

### Tier 0 — prep (cnpg-playground-u9n0.3)

Blockers u9n0.1, ounx and 7zdn are fixed (see "Source-data defects").

1. Regenerate the full log:
   ```bash
   uv run scripts/check-helm-versions.py --diff-values 2>&1 | tee helm-diff.log
   ```
   Every outdated chart should have a values diff and there should be no
   `helm show values failed` lines.
2. Check the "unverified" tier-2 notes (capsule API versions) against upstream
   release notes.

### Tier 1 + pin-only (cnpg-playground-u9n0.4)

```bash
# One branch, one PR.
$EDITOR scripts/common.sh   # 5 tier-1 pins + 3 pin-only argo pins; keep v-prefixes
bash -n scripts/common.sh
uv run scripts/check-helm-versions.py --diff-values --chart <KEY>   # per chart; expect image-tag/default churn only

./scripts/teardown.sh
./scripts/setup.sh --with-tenant && ./scripts/info.sh
```

### Tier 2 (cnpg-playground-u9n0.5)

1. For each chart, review the `--rendered` diff (command above). If it touches CRDs,
   apiVersions or RBAC, read the upstream release notes for every skipped minor and
   record any needed values override in the PR.
2. Bump the pins in `common.sh`, one commit per chart or chart pair (capsule +
   capsule-proxy, kyverno + kyverno-policies, cnpg + barman, otel chart + image).
3. **One** fresh rebuild for the whole batch, then chart-specific smoke tests:
   - trust-manager: a `Bundle` syncs to its target ConfigMap.
   - kyverno: apply a Policy, see a PolicyReport.
   - ESO: an `ExternalSecret` syncs from Vault.
   - cnpg + barman: a tenant `Cluster` is healthy, and an on-demand backup succeeds.
   - otel-collector: demo-app traces show up in Tempo.
   - alloy / mimir: pod logs in Loki; metrics are queryable in Mimir.
4. If one chart fails, revert that chart's commit and rebuild. Don't hold up the
   rest of the batch.

### Tier 3 (cnpg-playground-u9n0.6 argocd, cnpg-playground-u9n0.7 kube-prometheus-stack)

1. One branch and PR per chart. They touch different charts, so they can land in
   either order.
2. Full values diff plus upstream upgrade notes for every chart major crossed.
3. Fresh rebuild, tier-2 gates, plus:
   - argocd: all Applications `Synced/Healthy`; UI login via Dex works.
   - kube-prometheus-stack: every Grafana dashboard renders; `ALERTS` shows only
     expected alerts; the Prometheus PVC fits the kind disk (set
     `prometheus.prometheusSpec.retentionSize` if not).

---

## Validation gates

| Tier | Gate |
|---|---|
| 1 | `helm list -A` shows every release `deployed`; all pods Ready within 2 min of `setup.sh` finishing. |
| 2 | Tier 1 gate + the smoke tests listed for the chart. |
| 3 | Tier 2 gate + the chart-specific checks above. |

After all tiers:

```bash
uv run scripts/check-helm-versions.py 2>&1 | tee helm-diff-after.log
# Expect: 0 "⬆ update" rows. Remaining non-ok rows: cilium (missing), demo-app (local).
rg -c '⬆' helm-diff-after.log
```

---

## Rollback strategy

This is a kind playground, so **rebuild beats rollback**:
`./scripts/teardown.sh && ./scripts/setup.sh --with-tenant` on the previous
commit.

`helm rollback <release> <rev> -n <ns>` is fine for a quick in-place check on
charts without CRD changes. `helm_upgrade_install()` in `common.sh` also recovers
from stuck `pending-*` / `failed` releases. Don't use `helm rollback` for
trust-manager, ESO, kyverno, grafana-operator or kube-prometheus-stack: CRDs stay
at the new version.

---

## Scope discipline

- **Don't** touch the `cilium` registry row (cnpg-playground-2he9).
- **Don't** touch `loki` / `tempo` pins (lineage false-positive).
- **Don't** touch container `*_IMAGE` / `*_IMAGE_TAG` vars, **except**
  `OTEL_COLLECTOR_IMAGE_TAG`, which moves with its chart (see tier 2).
- **Don't** touch `tmp/check-helm-versions.py`. It's the predecessor of
  `scripts/check-helm-versions.py`.
- Checker fixes are limited to the two tier-0 blockers (ounx, 7zdn). Lineage-drift
  classification stays out (dats).

## Out of scope (deferred)

- `cilium` registry row — cnpg-playground-2he9.
- Checker lineage-drift classification — cnpg-playground-dats.
- Install-or-delete the argo sub-project pins — cnpg-playground-u9n0.2.
- ArgoCD `targetRevision` tracking and container image bumps (AUTHELIA_IMAGE,
  GRAFANA_IMAGE, TRAEFIK_IMAGE, TRAEFIK_VERSION, VAULT_IMAGE, STEP_CA_IMAGE,
  RUSTFS_IMAGE, MC_IMAGE, REVOCATION_EXPORTER_IMAGE), per
  `docs/plans/2026-09-17-check-helm-versions.md` "Out of scope".

---

## Bead map

| Bead | Pri | Scope | Blocked by |
|---|---|---|---|
| cnpg-playground-u9n0 | P1 | Epic | — |
| cnpg-playground-u9n0.1 | P1 | BUG: duplicate trust-manager pin | — |
| cnpg-playground-ounx | P1 | BUG: checker mimir chart name | — |
| cnpg-playground-7zdn | P1 | BUG: checker `helm show values` repo flake | — |
| cnpg-playground-u9n0.3 | P1 | Tier 0 prep | u9n0.1, ounx, 7zdn |
| cnpg-playground-u9n0.4 | P1 | Tier 1 + pin-only | u9n0.3 |
| cnpg-playground-u9n0.5 | P1 | Tier 2 | u9n0.4 |
| cnpg-playground-u9n0.6 | P1 | Tier 3 argocd | u9n0.5 |
| cnpg-playground-u9n0.7 | P1 | Tier 3 kube-prometheus-stack | u9n0.5 |
| cnpg-playground-u9n0.2 | P3 | Decision: argo sub-project pins | — |
| cnpg-playground-dats | P3 | Checker lineage drift (deferred) | — |
| cnpg-playground-2he9 | P4 | Decision: cilium registry row (deferred) | — |
