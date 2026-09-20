#!/usr/bin/env python3
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
"""Helm chart version checker for cnpg-playground.

Reads chart versions from scripts/common.sh (source of truth), compares them
against ArtifactHub latest, and optionally diffs a pinned version against the
current one via --from CHART=VER.

Usage:
  uv run scripts/check-helm-versions.py [options]
  uv run scripts/check-helm-versions.py --diff-values --from cilium=1.16.0

Options:
  --update, -u        Write new versions back to scripts/common.sh
  --diff-values, -d   Show unified diff of helm show values
  --rendered          Use helm-diff local for rendered-manifest diff (requires plugin)
  --chart, -c NAME    Limit to specific charts (repeatable, comma-separated ok)
  --from CHART=VER    Compare pinned CHART=VER against current value (repeatable,
                      requires --diff-values)
  --to VER            Global target version (preview/update target)
  --include-pre       Consider pre-release versions
  --constraints       (default on) honour ~/^ pins; --no-constraints skips them
"""

import hashlib
import json
import os
import random
import re
import subprocess
import tempfile
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Annotated, Optional

import httpx
import typer
import yaml
from packaging.version import InvalidVersion, Version
from rich.console import Console
from rich.syntax import Syntax
from rich.table import Table

console = Console()
app = typer.Typer(add_completion=False, rich_markup_mode="rich")

ARTIFACTHUB_API = "https://artifacthub.io/api/v1/packages/helm"


# ── CLI types (plan section 2) ─────────────────────────────────────────────────

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


# ── Chart registry (plan section 4) ────────────────────────────────────────────

@dataclass(frozen=True)
class ChartEntry:
    key: str                     # env-var name in common.sh
    name: str                    # chart name used for helm commands
    ah_slug: Optional[str] = None
    repo_url: Optional[str] = None
    oci_ref: Optional[str] = None
    local_path: Optional[str] = None
    api_versions: str = ""       # CRD groups for helm-diff --api-versions (none curated yet)


# NOTE: plan section 6's helm_show_values() uses entry.name, which section 4's
# dataclass omits — the extra `name` field above is that chart name.
CHART_REGISTRY: dict[str, ChartEntry] = {
    "CILIUM_CHART_VERSION": ChartEntry("CILIUM_CHART_VERSION", "cilium", ah_slug="cilium/cilium", repo_url="https://helm.cilium.io/"),
    "TRAEFIK_CHART_VERSION": ChartEntry("TRAEFIK_CHART_VERSION", "traefik", ah_slug="traefik/traefik", repo_url="https://traefik.github.io/charts"),
    "METALLB_CHART_VERSION": ChartEntry("METALLB_CHART_VERSION", "metallb", ah_slug="metallb/metallb", repo_url="https://metallb.github.io/metallb"),
    "CERT_MANAGER_CHART_VERSION": ChartEntry("CERT_MANAGER_CHART_VERSION", "cert-manager", ah_slug="cert-manager/cert-manager", repo_url="https://charts.jetstack.io"),
    "TRUST_MANAGER_CHART_VERSION": ChartEntry("TRUST_MANAGER_CHART_VERSION", "trust-manager", ah_slug="cert-manager/trust-manager", repo_url="https://charts.jetstack.io"),
    "METRICS_SERVER_CHART_VERSION": ChartEntry("METRICS_SERVER_CHART_VERSION", "metrics-server", ah_slug="metrics-server/metrics-server", repo_url="https://kubernetes-sigs.github.io/metrics-server"),
    "KUBELET_CSR_APPROVER_CHART_VERSION": ChartEntry("KUBELET_CSR_APPROVER_CHART_VERSION", "kubelet-csr-approver", ah_slug="kubelet-csr-approver/kubelet-csr-approver", repo_url="https://postfinance.github.io/kubelet-csr-approver"),
    "CAPSULE_CHART_VERSION": ChartEntry("CAPSULE_CHART_VERSION", "capsule", ah_slug="projectcapsule/capsule", repo_url="https://projectcapsule.github.io/charts"),
    "CAPSULE_PROXY_CHART_VERSION": ChartEntry("CAPSULE_PROXY_CHART_VERSION", "capsule-proxy", ah_slug="projectcapsule/capsule-proxy", repo_url="https://projectcapsule.github.io/charts"),
    "GANGPLANK_CHART_VERSION": ChartEntry("GANGPLANK_CHART_VERSION", "gangplank", ah_slug="peak-scale/gangplank", repo_url="https://projectcapsule.github.io/charts"),
    "KYVERNO_CHART_VERSION": ChartEntry("KYVERNO_CHART_VERSION", "kyverno", ah_slug="kyverno/kyverno", repo_url="https://kyverno.github.io/kyverno"),
    "KYVERNO_POLICIES_CHART_VERSION": ChartEntry("KYVERNO_POLICIES_CHART_VERSION", "kyverno-policies", ah_slug="kyverno/kyverno-policies", repo_url="https://kyverno.github.io/kyverno/"),
    "POLICY_REPORTER_CHART_VERSION": ChartEntry("POLICY_REPORTER_CHART_VERSION", "policy-reporter", ah_slug="policy-reporter/policy-reporter", repo_url="https://kyverno.github.io/policy-reporter"),
    "ARGOCD_CHART_VERSION": ChartEntry("ARGOCD_CHART_VERSION", "argo-cd", ah_slug="argo/argo-cd", repo_url="https://argoproj.github.io/argo-helm"),
    "ARGO_ROLLOUTS_CHART_VERSION": ChartEntry("ARGO_ROLLOUTS_CHART_VERSION", "argo-rollouts", ah_slug="argo/argo-rollouts", repo_url="https://argoproj.github.io/argo-helm"),
    "ARGO_WORKFLOWS_CHART_VERSION": ChartEntry("ARGO_WORKFLOWS_CHART_VERSION", "argo-workflows", ah_slug="argo/argo-workflows", repo_url="https://argoproj.github.io/argo-helm"),
    "ARGO_EVENTS_CHART_VERSION": ChartEntry("ARGO_EVENTS_CHART_VERSION", "argo-events", ah_slug="argo/argo-events", repo_url="https://argoproj.github.io/argo-helm"),
    "ESO_CHART_VERSION": ChartEntry("ESO_CHART_VERSION", "external-secrets", ah_slug="external-secrets-operator/external-secrets", repo_url="https://charts.external-secrets.io"),
    "CNPG_CHART_VERSION": ChartEntry("CNPG_CHART_VERSION", "cloudnative-pg", ah_slug="cloudnative-pg/cloudnative-pg", repo_url="https://cloudnative-pg.github.io/charts"),
    "BARMAN_CLOUD_PLUGIN_CHART_VERSION": ChartEntry("BARMAN_CLOUD_PLUGIN_CHART_VERSION", "plugin-barman-cloud", ah_slug="cloudnative-pg/plugin-barman-cloud", repo_url="https://cloudnative-pg.github.io/charts"),
    "GRAFANA_OPERATOR_CHART_VERSION": ChartEntry("GRAFANA_OPERATOR_CHART_VERSION", "grafana-operator", ah_slug="grafana/grafana-operator", repo_url="https://grafana.github.io/helm-charts"),
    "KUBE_PROMETHEUS_STACK_CHART_VERSION": ChartEntry("KUBE_PROMETHEUS_STACK_CHART_VERSION", "kube-prometheus-stack", ah_slug="prometheus-community/kube-prometheus-stack", repo_url="https://prometheus-community.github.io/helm-charts"),
    "LOKI_CHART_VERSION": ChartEntry("LOKI_CHART_VERSION", "loki", ah_slug="grafana/loki", repo_url="https://grafana.github.io/helm-charts"),
    "MIMIR_CHART_VERSION": ChartEntry("MIMIR_CHART_VERSION", "mimir-distributed", ah_slug="grafana/mimir-distributed", repo_url="https://grafana.github.io/helm-charts"),
    "TEMPO_CHART_VERSION": ChartEntry("TEMPO_CHART_VERSION", "tempo", ah_slug="grafana/tempo", repo_url="https://grafana.github.io/helm-charts"),
    "ALLOY_CHART_VERSION": ChartEntry("ALLOY_CHART_VERSION", "alloy", ah_slug="grafana/alloy", repo_url="https://grafana.github.io/helm-charts"),
    "OTEL_COLLECTOR_CHART_VERSION": ChartEntry("OTEL_COLLECTOR_CHART_VERSION", "opentelemetry-collector", ah_slug="opentelemetry-helm/opentelemetry-collector", oci_ref="oci://ghcr.io/open-telemetry/opentelemetry-helm-charts/opentelemetry-collector"),
    "TIGERA_OPERATOR_CHART_VERSION": ChartEntry("TIGERA_OPERATOR_CHART_VERSION", "tigera-operator", ah_slug="projectcalico/tigera-operator", repo_url="https://docs.projectcalico.org/charts"),
    "CARETTA_CHART_VERSION": ChartEntry("CARETTA_CHART_VERSION", "caretta", ah_slug="groundcover/caretta", repo_url="https://caretta.app/charts"),
    "RADAR_CHART_VERSION": ChartEntry("RADAR_CHART_VERSION", "radar", ah_slug="skyhook/radar", repo_url="https://skyhook-io.github.io/helm-charts"),
    "RELOADER_CHART_VERSION": ChartEntry("RELOADER_CHART_VERSION", "reloader", ah_slug="stakater/reloader", repo_url="https://stakater.github.io/stakater-charts"),
    # No ah_slug: the upstream chart repo is not published on ArtifactHub. The only
    # AH package named seaweedfs-operator is the nnstd fork
    # (https://nnstd.github.io/seaweedfs-operator, versioned 1.5.x), a different
    # lineage from the chart we pin — using it as the slug would report bogus
    # "updates". Version bumps here are manual; repo_url still serves --diff-values.
    "SEAWEEDFS_OPERATOR_CHART_VERSION": ChartEntry("SEAWEEDFS_OPERATOR_CHART_VERSION", "seaweedfs-operator", repo_url="https://seaweedfs.github.io/seaweedfs-operator/"),
    # In-repo chart: no env-var in common.sh — keyed by chart name, reported as
    # "missing in common.sh" until a version variable is added.
    "demo-app": ChartEntry("demo-app", "demo-app", local_path="app/helm/demo-app"),
}


def resolve_entry(name: str) -> Optional[ChartEntry]:
    """Resolve a chart name / env-var key to a registry entry."""
    if name in CHART_REGISTRY:
        return CHART_REGISTRY[name]
    for entry in CHART_REGISTRY.values():
        if entry.name == name or entry.name.lower() == name.lower():
            return entry
    return None


# ── Project root / version loading (plans sections 3 & 5) ──────────────────────

def find_project_root() -> Path:
    """Find the project root by locating scripts/common.sh."""
    candidates = [Path(__file__).parent.parent, Path.cwd()]
    for candidate in candidates:
        if (candidate / "scripts" / "common.sh").exists():
            return candidate
    raise FileNotFoundError(
        "Could not find project root (expected scripts/common.sh). "
        "Run from the cnpg-playground directory."
    )


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
        # common.sh uses ${VAR:-default}; VERSION_RE captures the expansion
        # verbatim, so extract the default value here.
        m = re.fullmatch(r"\$\{[^}:]*:-(.+)\}", value)
        if m:
            value = m.group(1)
        seen[key] = value
    if duplicates:
        console.print(f"[yellow]Warning:[/yellow] duplicate keys, second wins: {', '.join(duplicates)}")
    return seen


# ── Version helpers (reused from predecessor) ──────────────────────────────────

def clean_version(version: str) -> str:
    """Strip leading v, ~, ^ from a version string."""
    return version.lstrip("v~^")


def parse_version(version: str) -> Optional[Version]:
    """Parse a version string safely; return None if invalid."""
    try:
        return Version(clean_version(version))
    except InvalidVersion:
        return None


def is_prerelease_item(item: dict) -> bool:
    """Check whether an available_versions entry is a pre-release."""
    if "prerelease" in item:
        return bool(item["prerelease"])
    return "-" in item.get("version", "")


def find_latest(items: list[dict], include_pre: bool) -> Optional[str]:
    """Return the highest stable (or pre-release if include_pre) version."""
    candidates: list[tuple[Version, str]] = []
    for item in items:
        if not include_pre and is_prerelease_item(item):
            continue
        v = parse_version(item["version"])
        if v is not None:
            candidates.append((v, item["version"]))
    if not candidates:
        return None
    candidates.sort(key=lambda x: x[0], reverse=True)
    return candidates[0][1]


def find_latest_compatible(current_raw: str, items: list[dict], include_pre: bool) -> Optional[str]:
    """For ~-pinned versions, find the latest version within the same major.minor range."""
    base = parse_version(current_raw)
    if base is None:
        return None
    candidates: list[tuple[Version, str]] = []
    for item in items:
        if not include_pre and is_prerelease_item(item):
            continue
        v = parse_version(item["version"])
        if v is None or v.major != base.major or v.minor != base.minor:
            continue
        candidates.append((v, item["version"]))
    if not candidates:
        return None
    candidates.sort(key=lambda x: x[0], reverse=True)
    return candidates[0][1]


# ── Cache layer (plan section 12) ──────────────────────────────────────────────

AH_TTL = 86400                                     # 24 h
ah_cache: dict[tuple[str, str], tuple[str, float]] = {}   # (slug, version) → (values_text, ts)
CACHE_DIR = (Path(os.environ.get("XDG_CACHE_HOME", "~/.cache")).expanduser()
             / "cnpg-playground" / "helm-values")


def _jitter(attempt: int) -> float:
    return min(0.5 * (2 ** attempt) + random.uniform(0, 0.5), 30.0)


def get_with_retry(client: httpx.Client, url: str, timeout: float = 20.0,
                   max_attempts: int = 4) -> httpx.Response:
    """GET with jittered backoff on 429/5xx; honour Retry-After when present."""
    for attempt in range(max_attempts):
        try:
            r = client.get(url, timeout=timeout)
        except httpx.RequestError as e:
            if attempt >= max_attempts - 1:
                raise RuntimeError(f"Network error: {e}") from e
            time.sleep(_jitter(attempt))
            continue
        if r.status_code in (429, 500, 502, 503, 504) and attempt < max_attempts - 1:
            retry_after = r.headers.get("Retry-After")
            if retry_after:
                try:
                    time.sleep(min(float(retry_after), 30.0))
                    continue
                except ValueError:
                    pass  # HTTP-date form — fall through to jittered backoff
            time.sleep(_jitter(attempt))
            continue
        return r
    raise RuntimeError(f"unreachable: max_attempts={max_attempts}")  # pragma: no cover


# ── ArtifactHub API ────────────────────────────────────────────────────────────

def fetch_artifacthub(slug: str, client: httpx.Client) -> Optional[tuple[str, list[dict]]]:
    """Fetch package metadata; return None on 404 (chart not indexed)."""
    repo, package = slug.split("/", 1)
    r = get_with_retry(client, f"{ARTIFACTHUB_API}/{repo}/{package}")
    if r.status_code == 404:
        return None
    if r.status_code >= 400:
        raise RuntimeError(f"HTTP {r.status_code} for {slug}")
    data = r.json()
    return data.get("version", ""), data.get("available_versions", [])


def ah_latest_for(entry: ChartEntry, client: httpx.Client, include_pre: bool) -> Optional[str]:
    """ArtifactHub latest for an entry; None if untracked or 404."""
    if not entry.ah_slug:
        return None
    data = fetch_artifacthub(entry.ah_slug, client)
    if data is None:
        return None
    return find_latest(data[1], include_pre)


def ah_values(slug: str, version: str, client: httpx.Client) -> str:
    """Fetch raw values.yaml via ArtifactHub. Returns YAML text."""
    cache_key = (slug, version)
    cached = ah_cache.get(cache_key)
    if cached and time.time() - cached[1] < AH_TTL:
        return cached[0]
    repo, package = slug.split("/", 1)
    # 1. Resolve package_id from detail call.
    detail = get_with_retry(client, f"{ARTIFACTHUB_API}/{repo}/{package}")
    if detail.status_code == 404:
        raise RuntimeError(f"no AH package for {slug}")
    detail.raise_for_status()
    package_id = detail.json()["package_id"]
    # 2. Fetch values for the specific version.
    r = get_with_retry(client, f"https://artifacthub.io/api/v1/packages/{package_id}/{version}/values")
    if r.status_code == 404:
        raise RuntimeError(f"no AH values for {slug}@{version}")
    r.raise_for_status()
    ah_cache[cache_key] = (r.text, time.time())
    return r.text


# ── Helm values fetch (plan section 6) ─────────────────────────────────────────

_repo_names: dict[str, str] = {}   # repo url → registered, index-refreshed repo name


def _repo_name_for(url: str) -> str:
    """Return a helm repo name serving `url`, registering it if needed.

    helm >= 4 dropped `--repo URL` for unknown URLs (regression pointing at an
    arbitrary cached index); the `--repo` flag then only works for repos already
    registered in the helm config, so fall back to the <name>/<chart> form.
    """
    if url in _repo_names:
        return _repo_names[url]
    name = None
    r = subprocess.run(["helm", "repo", "list"], capture_output=True, text=True, timeout=30)
    if r.returncode == 0:
        for line in r.stdout.splitlines()[1:]:
            parts = line.split()
            if len(parts) >= 2 and parts[1].rstrip("/") == url.rstrip("/"):
                name = parts[0]
                break
    if name is None:
        name = f"chk-{hashlib.sha256(url.encode()).hexdigest()[:8]}"
        add = subprocess.run(["helm", "repo", "add", name, url], capture_output=True, text=True, timeout=60)
        if add.returncode != 0:
            raise RuntimeError(f"helm repo add {name} {url} failed: {add.stderr.strip()}")
    # A registered repo can lack a cached index (e.g. added on another machine
    # or cache cleared), which makes `helm show values` fail with "no cached repo".
    upd = subprocess.run(["helm", "repo", "update", name], capture_output=True, text=True, timeout=120)
    if upd.returncode != 0:
        raise RuntimeError(f"helm repo update {name} failed: {upd.stderr.strip()}")
    _repo_names[url] = name
    return name


def _resolve_helm_ref_args(entry: ChartEntry) -> tuple[str, list[str]]:
    """Resolve (chart_ref, extra_args) for helm show/pull, tolerating helm >= 4.

    helm >= 4 dropped ad-hoc `--repo URL` for repos not registered in the helm
    config (the flag then resolves against an arbitrary cached index). Classic
    repos are therefore resolved to a registered `<repo-name>/<chart>` reference,
    which `_repo_name_for()` provisions on demand. OCI and local charts use
    their raw reference unchanged; extra_args carries OCI-specific flags.
    """
    if entry.local_path:
        return entry.local_path, []
    if entry.oci_ref:
        extra: list[str] = []
        # OCI via zot proxy needs --ca-file for the step-ca chain
        # (matches helm_upgrade_install()).
        if os.environ.get("OCI_PROXY"):
            ca_file = Path(__file__).parent.parent / "traefik-edge" / "certs" / "step-ca-chain.pem"
            if ca_file.exists():
                extra += ["--ca-file", str(ca_file)]
            else:
                console.print(f"  [yellow]Warning:[/yellow] OCI_PROXY set but {ca_file} missing — not adding --ca-file[/yellow]")
        return entry.oci_ref, extra
    assert entry.repo_url is not None
    return f"{_repo_name_for(entry.repo_url)}/{entry.name}", []


def _disk_cache_path(entry: ChartEntry, version: str) -> Path:
    digest = hashlib.sha256(f"{entry.name}:{version}".encode()).hexdigest()
    return CACHE_DIR / f"{digest}.yaml"


def helm_show_values(entry: ChartEntry, version: str) -> str:
    """Branch by ChartEntry kind. Always pass exact semver."""
    chart_ref, extra_args = _resolve_helm_ref_args(entry)
    if entry.local_path:
        cmd = ["helm", "show", "values", chart_ref, *extra_args]   # local: --version ignored
    else:
        cmd = ["helm", "show", "values", chart_ref, *extra_args,
               "--version", clean_version(version)]

    if entry.oci_ref:
        cache_file = _disk_cache_path(entry, version)
        if cache_file.exists() and time.time() - cache_file.stat().st_mtime < AH_TTL:
            return cache_file.read_text()

    r = subprocess.run(cmd, capture_output=True, text=True, timeout=120)
    if r.returncode != 0 and entry.repo_url and not entry.oci_ref and not entry.local_path \
            and "cached repo" in r.stderr:
        console.print(f"  [yellow]helm --repo failed ({r.stderr.strip().splitlines()[-1][:90]}) — "
                      f"retrying via registered repo[/yellow]")
        name = _repo_name_for(entry.repo_url)
        cmd = ["helm", "show", "values", f"{name}/{entry.name}",
               "--version", clean_version(version)]
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=120)
    if r.returncode != 0:
        raise RuntimeError(r.stderr.strip())
    if entry.oci_ref:
        cache_file = _disk_cache_path(entry, version)
        cache_file.parent.mkdir(parents=True, exist_ok=True)
        cache_file.write_text(r.stdout)
    return r.stdout


def get_values(entry: ChartEntry, version: str, client: httpx.Client) -> str:
    """AH /values fast path for AH-tracked charts; helm show values otherwise.

    AH only retains values for recently-indexed versions, so a 404 on the fast
    path falls back to `helm show values` (which serves any published version)
    instead of failing the chart.
    """
    if entry.ah_slug:
        try:
            return ah_values(entry.ah_slug, version, client)
        except RuntimeError as e:
            console.print(f"  [yellow]AH values unavailable ({e}) — falling back to helm show values[/yellow]")
    return helm_show_values(entry, version)


# ── Values diff / common.sh line edit (plans sections 8 & 9) ───────────────────

def unified_diff(label_from: str, label_to: str, from_text: str, to_text: str) -> str:
    """diff -u with explicit labels; returns '' when texts are identical."""
    with (
        tempfile.NamedTemporaryFile(mode="w", suffix=".yaml", delete=False) as f_old,
        tempfile.NamedTemporaryFile(mode="w", suffix=".yaml", delete=False) as f_new,
    ):
        f_old.write(from_text)
        f_new.write(to_text)
        old_path, new_path = f_old.name, f_new.name
    try:
        diff_result = subprocess.run(
            ["diff", "-u", "--label", label_from, "--label", label_to, old_path, new_path],
            capture_output=True, text=True,
        )
        return diff_result.stdout
    finally:
        Path(old_path).unlink(missing_ok=True)
        Path(new_path).unlink(missing_ok=True)


def print_line_edit(root: Path, key: str, old_line: str, new_ver: str) -> None:
    """Print the exact common.sh line edit in diff format (plan section 9)."""
    new_line = f'{key}="${{{key}:-{clean_version(new_ver)}}}"'
    line_no = next(
        (i for i, l in enumerate((root / "scripts" / "common.sh").read_text().splitlines(), 1)
         if re.match(rf'^\s*{re.escape(key)}\s*=', l)),
        1,
    )
    console.print(Syntax(
        f"--- scripts/common.sh\n+++ scripts/common.sh\n@@ -{line_no},1 +{line_no},1 @@\n"
        f"-{old_line}\n+{new_line}\n",
        "diff", theme="monokai"))


# ── common.sh update (plan section 10) ─────────────────────────────────────────

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
    subprocess.run(["bash", "-n", str(path)], check=True)   # validate syntax after rewrite


# ── helm-diff rendered manifests (plan section 11) ─────────────────────────────

def _helm_diff_installed() -> bool:
    try:
        r = subprocess.run(["helm", "plugin", "list"], capture_output=True, text=True, timeout=30)
    except (FileNotFoundError, subprocess.TimeoutExpired):
        return False
    return r.returncode == 0 and any(line.strip().startswith("diff") for line in r.stdout.splitlines())


def _check_rendered_gates() -> None:
    if not _helm_diff_installed():
        raise typer.BadParameter(
            "helm-diff plugin missing: "
            "helm plugin install https://github.com/databus23/helm-diff --version v3.15.13"
        )
    try:
        r = subprocess.run(["helm", "version", "--short"], capture_output=True, text=True, timeout=30)
        helm_ver = r.stdout.strip().split("+")[0].lstrip("v")
    except (FileNotFoundError, subprocess.TimeoutExpired):
        raise typer.BadParameter("helm not found — required for --rendered")
    if parse_version(helm_ver) is None or parse_version(helm_ver) < Version("3.18"):
        raise typer.BadParameter(f"--rendered requires helm >= 3.18 (found {helm_ver})")


def rendered_diff(entry: ChartEntry, from_ver: str, to_ver: str, timeout: int = 300) -> dict:
    if not _helm_diff_installed():
        raise typer.BadParameter(
            "helm-diff plugin missing: "
            "helm plugin install https://github.com/databus23/helm-diff --version v3.15.13"
        )
    with tempfile.TemporaryDirectory() as td:
        def pull(ver: str) -> str:
            chart_ref, extra_args = _resolve_helm_ref_args(entry)
            # helm pull --untar refuses to untar over an existing dir, so give
            # each version its own destination (d1 and d2 share `td`).
            dest = Path(td) / clean_version(ver)
            dest.mkdir(parents=True, exist_ok=True)
            subprocess.run(["helm", "pull", chart_ref, *extra_args, "--version", clean_version(ver),
                            "--untar", "-d", str(dest)], check=True, timeout=120, capture_output=True)
            # helm pull --untar names the dir after Chart.yaml's name; tolerate
            # both "<name>" and "<name>-<ver>" layouts.
            candidates = sorted(dest.glob(f"{entry.name}*"))
            if not candidates:
                raise RuntimeError(f"helm pull produced no directory for {entry.name}")
            return str(candidates[0])
        d1, d2 = pull(from_ver), pull(to_ver)
        args = ["helm", "diff", "local", d1, d2, "--output", "structured",
                "--detailed-exitcode", "--include-crds"]
        if entry.api_versions:
            args += ["--api-versions", entry.api_versions]
        r = subprocess.run(args, timeout=timeout, capture_output=True)
        return {"exit": r.returncode,                # 0 none, 2 changes, 1 error
                "changes": json.loads(r.stdout) if r.returncode != 1 else None}


# ── main (plan section 2) ──────────────────────────────────────────────────────

@app.command()
def main(
    update: Annotated[bool, typer.Option("--update", "-u", help="Write new versions back to scripts/common.sh.")] = False,
    diff_values: Annotated[bool, typer.Option("--diff-values", "-d", help="Show unified diff of helm show values.")] = False,
    rendered: Annotated[bool, typer.Option(help="Use helm-diff local for rendered-manifest diff (requires plugin).")] = False,
    chart: Annotated[list[str], typer.Option("--chart", "-c", metavar="NAME", help="Limit to specific charts (repeatable).")] = [],
    from_charts: Annotated[list[ChartRef], typer.Option(
        "--from", parser=parse_chart_ref, metavar="CHART=VER",
        help="Compare pinned CHART=VER against current value. Repeatable. Requires --diff-values.",
    )] = [],
    to: Annotated[Optional[str], typer.Option("--to", metavar="VER", help="Global target version (update/preview target).")] = None,
    include_pre: Annotated[bool, typer.Option("--include-pre", help="Consider pre-release versions.")] = False,
    constraints: Annotated[bool, typer.Option("--constraints/--no-constraints", help="Honour ~/^ version pins (default on).")] = True,
):
    """Check Helm chart versions against ArtifactHub latest, with optional --from diff."""
    if from_charts and not diff_values:
        raise typer.BadParameter("--from requires --diff-values")
    if rendered and not diff_values:
        raise typer.BadParameter("--rendered requires --diff-values")

    seen_from: set[str] = set()                     # duplicate --from keys are a usage error
    for ref in from_charts:
        if ref.chart in seen_from:
            raise typer.BadParameter(f"duplicate --from chart {ref.chart!r}")
        seen_from.add(ref.chart)

    try:
        root = find_project_root()
    except FileNotFoundError as e:
        console.print(f"[red]Error:[/red] {e}")
        raise typer.Exit(1)

    versions = load_versions(root)

    # Open item 3: charts in common.sh with no registry entry get warned + skipped.
    for key in versions:
        if key.endswith("_CHART_VERSION") and key not in CHART_REGISTRY:
            console.print(f"[yellow]Warning:[/yellow] {key} has no registry entry — skipped")

    if from_charts:
        _run_from_mode(root, versions, from_charts, update, rendered, to, include_pre)
    else:
        _run_default_mode(root, versions, update, diff_values, chart, to, include_pre, constraints)


# ── --from flow (plan section 8) ───────────────────────────────────────────────

def _run_from_mode(root: Path, versions: dict[str, str], from_charts: list[ChartRef],
                   update: bool, rendered: bool, to: Optional[str], include_pre: bool) -> None:
    if rendered:
        _check_rendered_gates()

    entries: list[tuple[ChartRef, ChartEntry]] = []
    for ref in from_charts:
        entry = resolve_entry(ref.chart)
        if entry is None:
            raise typer.BadParameter(
                f"unknown --from chart {ref.chart!r}. Valid: "
                + ", ".join(sorted({e.name for e in CHART_REGISTRY.values()}))
            )
        entries.append((ref, entry))

    old_lines: dict[str, str] = {}                  # key → first matching line in common.sh
    common_sh_text = (root / "scripts" / "common.sh").read_text()
    for key in CHART_REGISTRY:
        m = re.search(rf'^\s*{re.escape(key)}\s*=\s*"[^"]*"', common_sh_text, re.MULTILINE)
        if m:
            old_lines[key] = m.group(0)

    results: list[dict] = []
    updates: dict[str, tuple[str, str]] = {}
    drift_count = match_count = error_count = 0

    with httpx.Client(headers={"Accept": "application/json"}) as client:
        for ref, entry in entries:
            current = versions.get(entry.key)
            if current is None and to is None:
                # e.g. cilium: in the registry, but no CILIUM_CHART_VERSION in common.sh yet.
                console.print(f"[yellow]Warning:[/yellow] {entry.key} missing in common.sh — "
                              f"cannot diff current values")
                results.append({"key": entry.key, "from": ref.version, "current": "?",
                                "drift": "-", "status": "error",
                                "status_str": "[red]✗ missing in common.sh[/red]"})
                error_count += 1
                continue
            if current is None:
                current = "?"        # display placeholder; diff target comes from --to
            target_ver = to or current
            console.print(f"\n[bold cyan]── {entry.name}: {clean_version(ref.version)} → "
                          f"{clean_version(target_ver)} ──[/bold cyan]")
            try:
                if rendered:
                    dr = rendered_diff(entry, ref.version, target_ver)
                    if dr["exit"] == 1:
                        raise RuntimeError("helm diff local returned an error (unvendored chart deps?)")
                    drift = dr["exit"] == 2
                    if dr["changes"] is not None:
                        console.print(json.dumps(dr["changes"], indent=2))
                else:
                    d = unified_diff(
                        f"{entry.name} ({clean_version(ref.version)})",
                        f"{entry.name} ({clean_version(target_ver)})",
                        get_values(entry, ref.version, client),
                        get_values(entry, target_ver, client),
                    )
                    drift = bool(d)
                    console.print(Syntax(d, "diff", theme="monokai") if d
                                  else "  [green]No changes in values[/green]")
            except Exception as e:
                # Per-chart guard: one chart's failure must not abort the
                # whole --from run (helm pull/diff can fail on network, missing
                # versions, unvendored deps, …).
                console.print(f"  [red]{entry.key}: helm pull/diff failed — {e}[/red]")
                results.append({"key": entry.key, "from": ref.version, "current": current,
                                "drift": "error", "status": "error",
                                "status_str": f"[red]✗ {e}[/red]"})
                error_count += 1
                continue

            if drift:
                drift_count += 1
                if entry.key in old_lines:
                    # Section 9: read-only line edit shows current → pinned (or --to).
                    print_line_edit(root, entry.key, old_lines[entry.key], to or ref.version)
                    if update:
                        # Locked decision: --update target is --to, else ArtifactHub
                        # latest, else the pinned version as last resort.
                        new_ver = to or ah_latest_for(entry, client, include_pre) or ref.version
                        updates[entry.key] = (current, new_ver)
            else:
                match_count += 1
            results.append({"key": entry.key, "from": ref.version, "current": current,
                            "drift": "drift" if drift else "match",
                            "status": "drift" if drift else "match",
                            "status_str": "[yellow]⬆ drift[/yellow]" if drift
                                          else "[green]✓ match[/green]"})

    # Summary table with Drift column (plan section 8.3).
    table = Table(title="Helm Chart --from Status", show_header=True, header_style="bold magenta")
    for col, style in (("Key", "cyan"), ("From", ""), ("Current", ""), ("Drift", ""), ("Status", "")):
        table.add_column(col, style=style, no_wrap=True)
    for r in results:
        table.add_row(r["key"], r["from"], r["current"], r["drift"], r["status_str"])
    console.print()
    console.print(table)
    console.print(f"\n[bold]Summary:[/bold] [green]{match_count} match[/green]  "
                  f"[yellow]{drift_count} drift[/yellow]  [red]{error_count} error(s)[/red]")

    if update and updates:
        console.print(f"\n[bold]Updating {len(updates)} chart(s) in scripts/common.sh:[/bold]")
        try:
            update_common_sh(root, updates)
            console.print("[green]Done.[/green]")
        except subprocess.CalledProcessError as e:
            console.print(f"[red]bash -n failed after update — common.sh may be corrupt:[/red] {e}")
            raise typer.Exit(1)
    elif update:
        console.print("\n[green]Nothing to update.[/green]")

    if drift_count or error_count:
        raise typer.Exit(1)


# ── Default mode: ArtifactHub latest (predecessor flow, adapted) ───────────────

def _run_default_mode(root: Path, versions: dict[str, str], update: bool, diff_values: bool,
                      chart: list[str], to: Optional[str], include_pre: bool,
                      constraints: bool) -> None:
    # --chart accepts repeatable and comma-separated short names (validation gate 7).
    requested = [t.strip() for raw in chart for t in raw.split(",") if t.strip()]
    if requested:
        keys: list[str] = []
        for token in requested:
            entry = resolve_entry(token)
            if entry is None:
                raise typer.BadParameter(
                    f"unknown chart {token!r}. Valid: "
                    + ", ".join(sorted({e.name for e in CHART_REGISTRY.values()}))
                )
            keys.append(entry.key)
    else:
        keys = [e.key for e in CHART_REGISTRY.values()]

    results: list[dict] = []
    with httpx.Client(headers={"Accept": "application/json"}) as client:
        for idx, key in enumerate(keys, 1):
            entry = CHART_REGISTRY[key]

            # In-repo chart: version lives in Chart.yaml, not common.sh, and is
            # not published anywhere to compare against. No AH call.
            if entry.local_path:
                chart_yaml = root / entry.local_path / "Chart.yaml"
                try:
                    local_ver = str(yaml.safe_load(chart_yaml.read_text())["version"])
                except (OSError, KeyError, TypeError, yaml.YAMLError) as e:
                    console.print(f"  [red]{key}: failed to read {chart_yaml}: {e}[/red]")
                    results.append({"key": key, "current_raw": "-", "latest": "-",
                                    "latest_compat": None, "is_constrained": False,
                                    "status": "error", "status_str": f"[red]✗ {e}[/red]",
                                    "slug": ""})
                    continue
                results.append({"key": key, "current_raw": local_ver, "latest": "-",
                                "latest_compat": None, "is_constrained": False,
                                "status": "local",
                                "status_str": "[cyan]⊙ local (Chart.yaml)[/cyan]",
                                "slug": ""})
                continue

            current_raw = versions.get(key)
            if current_raw is None:
                console.print(f"[yellow]Warning:[/yellow] {key} missing in common.sh — skipping")
                results.append({"key": key, "current_raw": "-", "latest": "-",
                                "latest_compat": None, "is_constrained": False,
                                "status": "error", "status_str": "[red]✗ missing in common.sh[/red]",
                                "slug": entry.ah_slug or ""})
                continue

            is_constrained = current_raw.startswith("~") or current_raw.startswith("^")
            if not constraints and is_constrained:
                continue
            if entry.ah_slug is None:
                console.print(f"[yellow]Warning:[/yellow] {key} has no ArtifactHub slug — skipped")
                results.append({"key": key, "current_raw": current_raw, "latest": "-",
                                "latest_compat": None, "is_constrained": is_constrained,
                                "status": "skip", "status_str": "[yellow]skipped (no AH slug)[/yellow]",
                                "slug": ""})
                continue

            console.print(f"[dim]({idx}/{len(keys)})[/dim] Checking [cyan]{key}[/cyan] "
                          f"({entry.ah_slug})…", end="\r")
            try:
                data = fetch_artifacthub(entry.ah_slug, client)
                if data is None:
                    console.print(" " * 80, end="\r")
                    console.print(f"[yellow]Warning:[/yellow] {entry.ah_slug} not found on "
                                  f"ArtifactHub — skipped")
                    results.append({"key": key, "current_raw": current_raw, "latest": "-",
                                    "latest_compat": None, "is_constrained": is_constrained,
                                    "status": "skip", "status_str": "[yellow]skipped (AH 404)[/yellow]",
                                    "slug": entry.ah_slug})
                    continue
                _, all_items = data
                latest_abs = find_latest(all_items, include_pre)
                latest_compat = (find_latest_compatible(current_raw, all_items, include_pre)
                                 if is_constrained else None)
                current_ver = parse_version(current_raw)
                latest_abs_ver = parse_version(latest_abs) if latest_abs else None
                latest_compat_ver = parse_version(latest_compat) if latest_compat else None

                if current_ver is None or latest_abs_ver is None:
                    status, status_str = "error", "[red]✗ parse error[/red]"
                elif is_constrained:
                    if latest_compat_ver and latest_compat_ver > current_ver:
                        status, status_str = "update", "[yellow]⬆ update[/yellow]"
                    elif latest_abs_ver > current_ver:
                        status, status_str = "constrained", "[blue]↑ newer (constrained)[/blue]"
                    else:
                        status, status_str = "ok", "[green]✓ ok[/green]"
                else:
                    status, status_str = ("update" if latest_abs_ver > current_ver
                                          else "ok"), ("[yellow]⬆ update[/yellow]"
                                                       if latest_abs_ver > current_ver
                                                       else "[green]✓ ok[/green]")
            except RuntimeError as e:
                console.print(" " * 80, end="\r")
                latest_abs = latest_compat = None
                status, status_str = "error", f"[red]✗ {e}[/red]"

            results.append({"key": key, "current_raw": current_raw, "latest": latest_abs or "?",
                            "latest_compat": latest_compat, "is_constrained": is_constrained,
                            "status": status, "status_str": status_str, "slug": entry.ah_slug})

    console.print(" " * 80, end="\r")

    table = Table(title="Helm Chart Version Status", show_header=True, header_style="bold magenta")
    for col, style in (("Key", "cyan"), ("Current", ""), ("Latest", ""),
                       ("Compatible", ""), ("Status", "")):
        table.add_column(col, style=style, no_wrap=True)
    for r in results:
        table.add_row(r["key"], r["current_raw"], r["latest"], r["latest_compat"] or "-", r["status_str"])
    console.print()
    console.print(table)

    n_ok = sum(1 for r in results if r["status"] == "ok")
    n_update = sum(1 for r in results if r["status"] == "update")
    n_constrained = sum(1 for r in results if r["status"] == "constrained")
    n_error = sum(1 for r in results if r["status"] == "error")
    n_skip = sum(1 for r in results if r["status"] == "skip")
    n_local = sum(1 for r in results if r["status"] == "local")
    console.print(f"\n[bold]Summary:[/bold] [green]{n_ok} up-to-date[/green]  "
                  f"[yellow]{n_update} update(s) available[/yellow]  "
                  f"[blue]{n_constrained} newer (out of constraint range)[/blue]  "
                  f"[red]{n_error} error(s)[/red]  [yellow]{n_skip} skipped[/yellow]  "
                  f"[cyan]{n_local} local (Chart.yaml)[/cyan]")

    # Values diff for updated charts (plan section 6 wiring).
    if diff_values:
        charts_to_diff = [r for r in results if r["status"] == "update"]
        if not charts_to_diff:
            console.print("\n[green]No updates available — nothing to diff.[/green]")
        else:
            console.print(f"\n[bold]Values diffs for {len(charts_to_diff)} chart(s):[/bold]")
            with httpx.Client(headers={"Accept": "application/json"}) as client:
                for r in charts_to_diff:
                    entry = CHART_REGISTRY[r["key"]]
                    target = to or (r["latest_compat"] if r["is_constrained"] and r["latest_compat"]
                                    else r["latest"])
                    try:
                        old_values = helm_show_values(entry, r["current_raw"])
                        new_values = helm_show_values(entry, target)
                    except RuntimeError as e:
                        console.print(f"  [red]helm show values failed for {r['key']}: {e}[/red]")
                        continue
                    console.print(f"\n[bold cyan]── {entry.name}: {clean_version(r['current_raw'])} → "
                                  f"{clean_version(target)} ──[/bold cyan]")
                    d = unified_diff(f"{entry.name} ({clean_version(r['current_raw'])})",
                                     f"{entry.name} ({clean_version(target)})",
                                     old_values, new_values)
                    console.print(Syntax(d, "diff", theme="monokai") if d
                                  else "  [green]No changes in default values[/green]")

    # Update common.sh (plan section 10).
    if update:
        updates: dict[str, tuple[str, str]] = {}
        for r in results:
            if r["status"] == "update":
                new_ver = to or (r["latest_compat"] if r["is_constrained"] and r["latest_compat"]
                                 else r["latest"])
                updates[r["key"]] = (r["current_raw"], new_ver)
        if not updates:
            console.print("\n[green]Nothing to update.[/green]")
        else:
            console.print(f"\n[bold]Updating {len(updates)} chart(s) in scripts/common.sh:[/bold]")
            try:
                update_common_sh(root, updates)
                console.print("[green]Done.[/green]")
            except subprocess.CalledProcessError as e:
                console.print(f"[red]bash -n failed after update — common.sh may be corrupt:[/red] {e}")
                raise typer.Exit(1)

    if n_error:
        raise typer.Exit(1)


if __name__ == "__main__":
    app()