# Plan: adapt `tmp/check-helm-versions.py` for cnpg-playground

## Goal

Adapt the ncsc-trails-flavoured helm-version checker to:

1. Read chart versions from `scripts/common.sh` (this repo's source of truth).
2. Add `--from CHART=VER` (repeatable) — diff a pinned version against the current one.
3. Migrate the CLI from `argparse` to `typer` (typed params, Rich-styled errors).
4. Add `--rendered` opt-in flag for `helm-diff local` rendered-manifest comparison.

Out of scope: ArgoCD `targetRevision` tracking (the four Application manifests reference a git branch, not a chart version), and container image tags without a `*_CHART_VERSION` / `*_VERSION` suffix.

---

## Locked decisions

| Concern | Decision |
|---|---|
| `--from` syntax | repeatable `--from CHART=VER` per chart |
| `--from` without `--diff-values` | error out with `BadParameter` (exit 2) |
| Registry source | scan `scripts/common.sh` for `*_CHART_VERSION` / `*_VERSION`; per-chart explicit `artifacthub_slug` table (auto-derivation is unreliable — see Research note 1) |
| `--from` + `--update` | inspection-only; `--update` needs `--to` or falls back to ArtifactHub latest |
| API for value lookup | ArtifactHub `/api/v1/packages/{id}/{version}/values` fast path → `helm show values` fallback for non-AH charts |
| CLI framework | Typer 0.27.2 with Rich Console for output, vendored Click (no separate pin, no `import click`) |
| helm-diff | opt-in `--rendered` flag; default stays `helm show values` |
| OCI invocation | `helm show values oci://... --version X` (no `--repo`); pull-progress stripping requires helm-diff v3.15.11+ |
| Helm version gate | require helm ≥ 3.18 in `common.sh` if `--rendered` is added |

---

## Code changes

### 1. PEP 723 deps

```python
# /// script
# requires-python = ">=3.11"
# dependencies = [
#   "httpx",
#   "rich",
#   "pyyaml",
#   "packaging",
#   "typer",
# ]
# ///
```

Typer pulls `rich` transitively — keep the explicit entry for clarity. **Do not** add `click` (vendored at `typer._click` since Typer 0.26.0; importing it directly is unsupported).

### 2. CLI structure (Typer)

Single `@app.command()`, no subcommands. One `console = Console()` for all output; **never** `typer.echo()`.

```python
from dataclasses import dataclass
from typing import Annotated, Optional
import typer
from rich.console import Console

console = Console()
app = typer.Typer(add_completion=False, rich_markup_mode="rich")


@dataclass(frozen=True)
class ChartRef:
    chart: str
    version: str


def parse_chart_ref(raw: str) -> ChartRef:
    if "=" not in raw:
        raise typer.BadParameter(f"expected CHART=VER, got {raw!r}")
    chart, version = raw.split("=", 1)
    if not chart or not version:
        raise typer.BadParameter(f"expected CHART=VER, got {raw!r}")
    return ChartRef(chart, version)


@app.command()
def main(
    update: Annotated[bool, typer.Option("--update", "-u")] = False,
    diff_values: Annotated[bool, typer.Option("--diff-values", "-d")] = False,
    rendered: Annotated[bool, typer.Option(help="Use helm-diff local for rendered-manifest diff (requires plugin).")] = False,
    chart: Annotated[list[str], typer.Option("--chart", "-c", metavar="KEY")] = [],
    from_charts: Annotated[list[ChartRef], typer.Option(
        "--from", parser=parse_chart_ref, metavar="CHART=VER",
        help="Compare pinned CHART=VER against current value. Repeatable. Requires --diff-values.",
    )] = [],
    to: Annotated[Optional[str], typer.Option("--to", metavar="VER")] = None,
    include_pre: Annotated[bool, typer.Option("--include-pre")] = False,
    constraints: Annotated[bool, typer.Option("--constraints/--no-constraints")] = True,
):
    """Check Helm chart versions against ArtifactHub latest, with optional --from diff."""
    if from_charts and not diff_values:
        raise typer.BadParameter("--from requires --diff-values")
    if rendered and not diff_values:
        raise typer.BadParameter("--rendered requires --diff-values")
    # ... rest of body
```

**Typer gotchas to honour:**

- Annotate `--from` element type as `list[ChartRef]`, not bare `list` — known issue #534 (nested-list parsing).
- Detect duplicate `--from CHART=VER` keys in body and raise.
- `--no-constraints` becomes `--constraints/--no-constraints` default `True` (Typer auto-generates the negation twin).
- `raise typer.BadParameter(msg)` for CLI errors (exit 2, Rich-styled panel). `raise typer.Exit(1)` after `console.print(...)` for app errors.

### 3. Replace `load_versions()` — parse `scripts/common.sh`

```python
import re

VERSION_RE = re.compile(
    r'^\s*([A-Z][A-Z0-9_]*_(?:CHART_)?VERSION)\s*=\s*"?([^"\s#]+)"?',
    re.MULTILINE,
)


def load_versions(root: Path) -> dict[str, str]:
    """Parse scripts/common.sh for *_CHART_VERSION / *_VERSION assignments."""
    text = (root / "scripts" / "common.sh").read_text()
    seen: dict[str, str] = {}
    duplicates: list[str] = []
    for key, value in VERSION_RE.findall(text):
        # Prefer *_CHART_VERSION if both exist for the same prefix family.
        if key in seen and not key.endswith("_CHART_VERSION"):
            continue
        if key in seen:
            duplicates.append(key)
        seen[key] = value
    if duplicates:
        console.print(f"[yellow]Warning:[/yellow] duplicate keys, second wins: {', '.join(duplicates)}")
    return seen
```

**Dedup rules:**

- `FOO_CHART_VERSION` wins over `FOO_VERSION` when both exist (cert-manager, ESO, traefik).
- Skip `OTEL_COLLECTOR_IMAGE_TAG` — it's a container image tag, not a chart version.
- Warn on duplicate definitions (e.g. `TRUST_MANAGER_CHART_VERSION` at lines 144 and 224 with different defaults).

### 4. Replace `CHART_REGISTRY` with explicit table

Per-chart dataclass with explicit `artifacthub_slug`. Auto-derivation from env-var name is fragile (OTEL's AH slug is `opentelemetry-helm`, not derivable from `oci://ghcr.io/open-telemetry/...`).

```python
@dataclass(frozen=True)
class ChartEntry:
    key: str                     # env-var name in common.sh
    ah_slug: Optional[str]       # "{repo}/{package}" — ArtifactHub lookup target
    repo_url: Optional[str]      # classic https URL for `helm show values --repo`
    oci_ref: Optional[str]       # oci://... when no classic repo available
    local_path: Optional[str]    # path for in-repo charts (e.g. app/helm/demo-app)
    api_versions: str = ""       # CRD groups for helm-diff --api-versions (e.g. "monitoring.coreos.com/v1")
```

Initial registry (built from `common.sh` ~25 chart entries; fixer's first task is to validate each AH slug via `GET /api/v1/packages/search`):

```
cilium              ah: cilium/cilium                          repo: https://helm.cilium.io/
traefik             ah: traefik/traefik                        repo: https://traefik.github.io/charts
metallb             ah: metallb/metallb                        repo: https://metallb.github.io/metallb
cert-manager        ah: jetstack/cert-manager                  repo: https://charts.jetstack.io
trust-manager       ah: jetstack/trust-manager                 repo: https://charts.jetstack.io
metrics-server      ah: metrics-server/metrics-server          repo: https://kubernetes-sigs.github.io/metrics-server
kubelet-csr-approver ah: postfinance/kubelet-csr-approver      repo: https://postfinance.github.io/kubelet-csr-approver
capsule             ah: projectcapsule/capsule                 repo: https://projectcapsule.github.io/charts
capsule-proxy       ah: projectcapsule/capsule-proxy           repo: https://projectcapsule.github.io/charts
gangplank           ah: projectcapsule/gangplank               repo: https://projectcapsule.github.io/charts
kyverno             ah: kyverno/kyverno                        repo: https://kyverno.github.io/kyverno
kyverno-policies    ah: kyverno/kyverno-policies               repo: https://kyverno.github.io/kyverno-policies
policy-reporter     ah: policyreporter/policy-reporter         repo: https://policy-reporter.github.io/policy-reporter
argocd              ah: argo/argo-cd                           repo: https://argoproj.github.io/argo-helm
argo-rollouts       ah: argo/argo-rollouts                     repo: https://argoproj.github.io/argo-helm
argo-workflows      ah: argo/argo-workflows                    repo: https://argoproj.github.io/argo-helm
argo-events         ah: argo/argo-events                       repo: https://argoproj.github.io/argo-helm
external-secrets    ah: external-secrets-operator/external-secrets  repo: https://charts.external-secrets.io
cloudnative-pg      ah: cloudnative-pg/cloudnative-pg          repo: https://cloudnative-pg.github.io/charts
barman-cloud-plugin ah: cloudnative-pg/plugin-barman-cloud     repo: https://cloudnative-pg.github.io/charts
grafana-operator     ah: grafana/grafana-operator              repo: https://grafana.github.io/helm-charts
kube-prometheus-stack ah: prometheus-community/kube-prometheus-stack  repo: https://prometheus-community.github.io/helm-charts
loki                 ah: grafana/loki                          repo: https://grafana.github.io/helm-charts
mimir                ah: grafana/mimir-distributed             repo: https://grafana.github.io/helm-charts
tempo                ah: grafana/tempo                         repo: https://grafana.github.io/helm-charts
alloy                ah: grafana/alloy                         repo: https://grafana.github.io/helm-charts
otel-collector       ah: opentelemetry-helm/opentelemetry-collector  oci: oci://ghcr.io/open-telemetry/opentelemetry-helm-charts/opentelemetry-collector
tigera-operator      ah: projectcalico/tigera-operator         repo: https://projectcalico.github.io/charts
caretta              ah: caretta/caretta                       repo: https://caretta.app/charts
radar                ah: radar-team/radar                      repo: https://radar-team.github.io/charts
demo-app             local: app/helm/demo-app
```

Fixer must validate each AH slug returns 200; charts returning 404 are flagged in output and skipped, not silently dropped.

### 5. `find_project_root()` update

```python
def find_project_root() -> Path:
    candidates = [Path(__file__).parent.parent, Path.cwd()]
    for c in candidates:
        if (c / "scripts" / "common.sh").exists():
            return c
    raise FileNotFoundError("Could not find project root (expected scripts/common.sh).")
```

### 6. `helm_show_values()` rewrite — three branches

```python
def helm_show_values(entry: ChartEntry, version: str) -> str:
    """Branch by ChartEntry kind. Always pass exact semver."""
    if entry.local_path:
        # Local chart: --version silently ignored, working tree only.
        cmd = ["helm", "show", "values", entry.local_path]
    elif entry.oci_ref:
        # OCI: --repo does NOT apply; exact semver avoids tag-listing roundtrip.
        cmd = ["helm", "show", "values", entry.oci_ref, "--version", clean_version(version)]
    else:
        cmd = ["helm", "show", "values", entry.name,
               "--repo", entry.repo_url, "--version", clean_version(version)]
    # For OCI refs when OCI_PROXY is set, add --ca-file for the step-ca chain.
    # Matches helm_upgrade_install() in common.sh for consistency.
    r = subprocess.run(cmd, capture_output=True, text=True, timeout=120)
    if r.returncode != 0:
        raise RuntimeError(r.stderr.strip())
    return r.stdout
```

Add `--ca-file "${GIT_REPO_ROOT}/traefik-edge/certs/step-ca-chain.pem"` to OCI invocations when `OCI_PROXY` is set (matches `helm_upgrade_install()`).

### 7. AH `/values` fast path for `--diff-values --from`

For AH-tracked charts, skip the `helm show values` subprocess entirely — fetch raw values from the AH API:

```python
def ah_values(slug: str, version: str, client: httpx.Client, cache: dict) -> str:
    """Fetch raw values.yaml via ArtifactHub. Returns YAML text."""
    cache_key = (slug, version)
    if cache_key in cache:
        return cache[cache_key]
    repo, package = slug.split("/", 1)
    # 1. Resolve package_id from detail call.
    detail = client.get(f"https://artifacthub.io/api/v1/packages/helm/{repo}/{package}", timeout=20).json()
    package_id = detail["package_id"]
    # 2. Fetch values for the specific version.
    r = client.get(
        f"https://artifacthub.io/api/v1/packages/{package_id}/{version}/values",
        timeout=20,
    )
    if r.status_code == 404:
        raise RuntimeError(f"no AH values for {slug}@{version}")
    r.raise_for_status()
    cache[cache_key] = r.text
    return r.text
```

Falls back to `helm show values` only when `entry.ah_slug is None` (local chart or AH-untracked remote).

### 8. `--from` flow

```
uv run tmp/check-helm-versions.py --diff-values \
    --from cilium=1.16.0 \
    --from metallb=0.14.0 \
    --chart cilium,metallb
```

Behaviour:

1. For each `--from CHART=VER`:
   - Fetch `from` values (AH fast path, else `helm show values`).
   - Fetch `current` values (from `common.sh`).
   - Emit unified diff via `diff -u --label "CHART (FROM)" --label "CHART (CURRENT)"`.
   - Status: `drift` if `from != current`, `match` otherwise.
2. `--to VERSION` (optional global): when set, diff `from → to` instead of `from → current`. Useful for previewing an upgrade path. Implies `--diff-values`.
3. Summary table column `Drift`: shows `drift` / `match` per chart.
4. Exit code: 1 if any `drift`, 0 if all `match` (and no AH errors), 2 on usage error.

### 9. Output format — version update lines

Per chart with drift, print the exact `common.sh` line edit:

```diff
--- scripts/common.sh
+++ scripts/common.sh
@@ -229,1 +229,1 @@
-CAPSULE_CHART_VERSION="${CAPSULE_CHART_VERSION:-0.13.6}"
+CAPSULE_CHART_VERSION="${CAPSULE_CHART_VERSION:-0.13.7}"
```

When `--update --to 0.13.7` is passed, the script applies the right-hand side in-place. Otherwise, output is read-only.

### 10. `update_common_sh()`

```python
def update_common_sh(root: Path, updates: dict[str, tuple[str, str]]) -> None:
    """Rewrite CHART_VERSION line in common.sh, preserving whitespace + quoting."""
    path = root / "scripts" / "common.sh"
    text = path.read_text()
    for key, (_old, new_ver) in updates.items():
        new_line = f'{key}="${{{key}:-{clean_version(new_ver)}}}"'
        pattern = re.compile(rf'^(\s*){re.escape(key)}\s*=\s*"[^"]*"', re.MULTILINE)
        new_text, n = pattern.subn(rf'\g<1>{new_line}', text, count=1)
        if n == 0:
            console.print(f"  [yellow]Could not locate {key} in common.sh[/yellow]")
            continue
        text = new_text
        console.print(f"  [green]  {key}: → {clean_version(new_ver)}[/green]")
    path.write_text(text)
```

After write, the script should validate with `subprocess.run(["bash", "-n", str(path)], check=True)` to catch syntax corruption.

### 11. `--rendered` flag — helm-diff local

Opt-in only. Different question from `--diff-values`: rendered manifests, not values.

```python
def rendered_diff(entry: ChartEntry, from_ver: str, to_ver: str, timeout: int = 300) -> dict:
    if not _helm_diff_installed():
        raise typer.BadParameter(
            "helm-diff plugin missing: "
            "helm plugin install https://github.com/databus23/helm-diff --version v3.15.13"
        )
    with tempfile.TemporaryDirectory() as td:
        def pull(ver: str) -> str:
            args = []
            if entry.repo_url:
                args = ["--repo", entry.repo_url]
            ref = entry.oci_ref or entry.name
            subprocess.run(
                ["helm", "pull", ref, *args, "--version", clean_version(ver),
                 "--untar", "-d", td],
                check=True, timeout=120, capture_output=True,
            )
            return os.path.join(td, f"{entry.name}-{clean_version(ver)}")
        d1, d2 = pull(from_ver), pull(to_ver)
        r = subprocess.run(
            ["helm", "diff", "local", d1, d2,
             "--output", "structured",
             "--detailed-exitcode",
             "--include-crds",
             "--api-versions", entry.api_versions],
            timeout=timeout, capture_output=True,
        )
        return {
            "exit": r.returncode,                   # 0 none, 2 changes, 1 error
            "changes": json.loads(r.stdout) if r.returncode != 1 else None,
        }
```

**`ChartEntry.api_versions`** — new field, comma-separated CRD groups for `--api-versions`. Required for charts that gate templates on `.Capabilities.APIVersions` (kyverno, cert-manager, cilium, prometheus-operator) or resources silently drop out of the diff. Build into the registry table during initial setup; not user-facing.

### 12. Cache layer

```python
# AH API: in-process dict, TTL 24 h (server enforces max-age=300; no ETag support).
ah_cache: dict[tuple[str, float], tuple[dict, float]] = {}  # (slug, time) → (payload, ts)
AH_TTL = 86400

# helm show values OCI: disk cache keyed sha256(slug+ver); TTL 24 h.
# Classic-repo tarballs are already cached by helm at ~/.cache/helm/repository.
CACHE_DIR = Path(os.environ.get("XDG_CACHE_HOME", "~/.cache")).expanduser() / "cnpg-playground" / "helm-values"
```

Retry 429/5xx with jittered backoff; honour `Retry-After` if present.

---

## helm-diff pros/cons (for the record)

**Pros**

- Real impact view (image bumps, Service ports, RBAC, CRD schema changes).
- Native `--output structured` JSON for CI parsing (v3.15.0+, 2026-02-01).
- `--include-crds` surfaces breaking changes that values diff can't see.

**Cons**

- Plugin dependency (`helm-diff` v3.15.13) + helm ≥ 3.18 gate.
- **5–10× slower** — 2× pull + 2× template render per chart; 30 charts ≈ 4–10 min.
- Different question answered than `--diff-values` — silent semantic shift if defaulted.
- CRD-gated silent gaps require per-chart `--api-versions` curation.
- Big charts (kube-prometheus-stack / loki / mimir / tempo) drown in image-tag and operator-mutation noise.

**Verdict**: opt-in via `--rendered`, not a replacement for `--diff-values`.

---

## Validation gates

1. `uv run tmp/check-helm-versions.py --help` — Typer-rendered help, exit 0.
2. `uv run tmp/check-helm-versions.py --diff-values --from cilium=1.15.0` — fetches both, prints unified diff, exit 1.
3. `uv run tmp/check-helm-versions.py --from cilium=1.15.0` (no `--diff-values`) — `BadParameter` Rich panel, exit 2.
4. `uv run tmp/check-helm-versions.py --diff-values --from badformat` — per-occurrence parse error, exit 2.
5. `uv run tmp/check-helm-versions.py --update --to 1.16.1 --chart cilium` — rewrites `CILIUM_CHART_VERSION=` line in `common.sh`; `bash -n scripts/common.sh` parses.
6. `uv run tmp/check-helm-versions.py --diff-values --from demo-app=0.1.0 --chart demo-app` — uses local-path branch, `helm show values app/helm/demo-app`, exit 0 if working tree matches.
7. `uv run tmp/check-helm-versions.py` (no flags) — ArtifactHub latest mode, scoped to charts in `common.sh`.
8. `uv run tmp/check-helm-versions.py --diff-values --rendered --from cilium=1.15.0` — requires `helm-diff` plugin; structured JSON on stdout; exit 2 if plugin missing.

---

## Edge cases / failure modes

- `helm show values oci://...` against zot with `OCI_PROXY` set — needs `--ca-file` for step-ca-issued cert (matches `helm_upgrade_install()`).
- AH 404 for charts not yet indexed — print warning, skip; don't fail the whole run.
- AH API rate limits (undocumented, ~25 calls × 1 run = nothing) — backoff+jitter on 429/5xx.
- `--from` chart key not present in `common.sh` — error before any network calls.
- Duplicate `--from cilium=1.0.0 --from cilium=2.0.0` — raise on detection.
- OCI chart tag with `v` prefix (e.g. `v1.20.2`) — helm semver parsing breaks; warn + suggest `clean_version()` already strips leading `v` before passing to `--version`.
- helm-diff local with unvendored chart deps — fails on `helm template`; surface as a per-chart error, continue with next chart.
- `helm-diff` plugin installed but < v3.15.11 — OCI pull progress leaks into manifest parse (issue #1040). Pin v3.15.13.

---

## Out of scope

- ArgoCD Application `targetRevision` tracking — all four apps reference git branch `vault`, not a chart version.
- Container image tags without `*_CHART_VERSION` / `*_VERSION` suffix (`AUTHELIA_IMAGE`, `GRAFANA_IMAGE`, `TRAEFIK_IMAGE`, `TRAEFIK_VERSION`, `VAULT_IMAGE`, `STEP_CA_IMAGE`, `RUSTFS_IMAGE`, `MC_IMAGE`, `REVOCATION_EXPORTER_IMAGE`).
- helm-diff local rendered-manifest view as the default — opt-in via `--rendered` only.
- Disk-cache for AH values response (only `helm show values` OCI gets disk cache).

---

## Lane assignment when executing

- `@fixer` (single lane, ~400 line rewrite of one file): receive this plan + reconciled research from `lib-1` + `lib-2` as context. Use `--task-id lib-1` or fresh `fixer-1`.
- `@oracle` review (post-fix, optional): residual gotchas — duplicate-var handling, OCI `--ca-file` only when `OCI_PROXY` set, AH slug 404 fallback behaviour, helm ≥ 3.18 gate placement.
- No parallelism needed — single file, single owner.

---

## Open items to confirm before execution

1. AH slug validation: fixer iterates `GET /api/v1/packages/search` per registry entry; 404s flagged in output and skipped.
2. For `--from` against a chart with no AH entry (only `app/helm/demo-app`): fall back to `helm show values` on the path/repo — acceptable? (current plan: yes.)
3. Chart in `common.sh` but missing from registry table: log warning, skip — acceptable? (current plan: yes.)
