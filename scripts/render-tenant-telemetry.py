#!/usr/bin/env python3
"""Render the per-tenant telemetry routing from the live Capsule Tenants (bead bd3d.7).

Every tenant-dependent block in the platform's observability config is generated here
instead of naming a tenant in git: Prometheus remoteWrite, the Grafana datasource
X-Scope-OrgID headers, the otel-collector trace routing, the Alloy log pipelines and the
Traefik metrics ServiceMonitor.

Each template carries a marked region:

    <comment> >>> per-tenant: <block-name> (generated, see scripts/render-tenant-telemetry.py)
    ...anything here is replaced...
    <comment> <<< per-tenant

Tenants are an explicit list, never a generic "^([a-z0-9]+)-" capture: Traefik router and
service names start with the *namespace*, so a generic capture would let a platform
namespace mint a Loki/Mimir tenant of its own name (bd3d.10).

Usage:
    render-tenant-telemetry.py --tenants rbr,foo --out-dir DIR FILE...
    render-tenant-telemetry.py --tenants-from-cluster --context kind-k8s-local ...

Each FILE is written to OUT_DIR under its original basename with any ".tpl" dropped.
"""
from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from pathlib import Path

BEGIN = re.compile(r"^(?P<indent>\s*)(?P<comment>#|//)\s*>>> per-tenant:\s*(?P<name>\S+)")
END = re.compile(r"^\s*(?:#|//)\s*<<< per-tenant")


def capsule_tenants(context: str | None) -> list[str]:
    """Tenant names from the Capsule Tenant objects, sorted for stable output."""
    cmd = ["kubectl", "get", "tenants.capsule.clastix.io", "-o", "json"]
    if context:
        cmd += ["--context", context]
    try:
        out = subprocess.run(cmd, capture_output=True, text=True, check=True).stdout
    except (subprocess.CalledProcessError, FileNotFoundError) as exc:
        print(f"warning: could not list Capsule Tenants ({exc}); rendering platform-only",
              file=sys.stderr)
        return []
    return sorted(item["metadata"]["name"] for item in json.loads(out).get("items", []))


# --- block renderers -------------------------------------------------------------------
# Each returns the lines for one marked region, already indented by the caller.

def prometheus_remote_write(tenants: list[str], push_url: str) -> list[str]:
    """One remoteWrite per tenant: its namespaces' series, plus anything a ServiceMonitor
    tagged tenant=<name> (Traefik series live in namespace "traefik", bd3d.10). A single
    keep with a combined regex — separate keeps would AND, not OR."""
    out: list[str] = []
    for t in tenants:
        out += [
            f"- url: {push_url}",
            "  headers:",
            f"    X-Scope-OrgID: {t}",
            "  writeRelabelConfigs:",
            "    - sourceLabels: [namespace, tenant]",
            "      separator: ';'",
            f"      regex: '({t}-.+;.*|.*;{t})'",
            "      action: keep",
        ]
    return out


def org_header(tenants: list[str], _: str) -> list[str]:
    """Platform datasources read the platform org plus every tenant org."""
    return [f"httpHeaderValue1: {'|'.join(['platform'] + tenants)}"]


def otel_routing_table(tenants: list[str], _: str) -> list[str]:
    """Route spans to a tenant's Tempo org either by the source pod's Capsule tenant
    (k8s_attributes) or, for Traefik, by the anchored router/service span attribute —
    every Traefik span carries the platform pod's resource."""
    out: list[str] = []
    for t in tenants:
        out += [
            f'- condition: resource.attributes["capsule.tenant"] == "{t}"',
            f"  pipelines: [traces/{t}]",
            "- context: span",
            f'  condition: IsMatch(attributes["traefik.router.name"], "^{t}-") or '
            f'IsMatch(attributes["traefik.service.name"], "^{t}-")',
            f"  pipelines: [traces/{t}]",
        ]
    return out


def otel_exporters(tenants: list[str], endpoint: str) -> list[str]:
    out: list[str] = []
    for t in tenants:
        out += [
            f"otlp/{t}:",
            f"  endpoint: {endpoint}",
            "  headers:",
            f"    X-Scope-OrgID: {t}",
            "  tls:",
            "    insecure: true",
        ]
    return out


def otel_pipelines(tenants: list[str], _: str) -> list[str]:
    out: list[str] = []
    for t in tenants:
        out += [
            f"traces/{t}:",
            "  receivers: [routing]",
            f"  exporters: [otlp/{t}]",
        ]
    return out


def alloy_traefik_tenant(tenants: list[str], _: str) -> list[str]:
    """Traefik access logs: the tenant comes from the anchored ServiceName prefix."""
    if not tenants:
        return []
    alt = "|".join(tenants)
    return [
        "stage.regex {",
        f'  expression = `"ServiceName":"(?P<tenant_from_service>{alt})-`',
        "}",
    ]


def alloy_events_tenant(tenants: list[str], _: str) -> list[str]:
    """Kubernetes events: the source labels each entry with the object's namespace."""
    out: list[str] = []
    for t in tenants:
        out += [
            "stage.match {",
            f'  selector = `{{namespace=~"{t}-.+"}}`',
            "  stage.static_labels {",
            f'    values = {{ tenant = "{t}" }}',
            "  }",
            "}",
        ]
    return out


def traefik_metric_relabelings(tenants: list[str], _: str) -> list[str]:
    """Traefik's own "service" label collides with the ServiceMonitor target label, so
    Prometheus renames it exported_service; router has no collision."""
    out: list[str] = []
    for t in tenants:
        out += [
            "- sourceLabels: [exported_service]",
            f"  regex: '{t}-.+'",
            "  targetLabel: tenant",
            f"  replacement: {t}",
            "- sourceLabels: [router]",
            f"  regex: '{t}-.+'",
            "  targetLabel: tenant",
            f"  replacement: {t}",
        ]
    return out


BLOCKS = {
    "prometheus-remote-write": prometheus_remote_write,
    "grafana-org-header": org_header,
    "otel-routing-table": otel_routing_table,
    "otel-exporters": otel_exporters,
    "otel-pipelines": otel_pipelines,
    "alloy-traefik-tenant": alloy_traefik_tenant,
    "alloy-events-tenant": alloy_events_tenant,
    "traefik-metric-relabelings": traefik_metric_relabelings,
}


def render(text: str, tenants: list[str], arg: str) -> str:
    out: list[str] = []
    skipping = False
    for line in text.splitlines():
        if skipping:
            if END.match(line):
                skipping = False
                out.append(line)
            continue
        out.append(line)
        m = BEGIN.match(line)
        if not m:
            continue
        name = m.group("name")
        if name not in BLOCKS:
            raise SystemExit(f"unknown per-tenant block: {name}")
        indent = m.group("indent")
        out += [f"{indent}{ln}" if ln else "" for ln in BLOCKS[name](tenants, arg)]
        skipping = True
    if skipping:
        raise SystemExit("unterminated per-tenant block (missing '<<< per-tenant')")
    return "\n".join(out) + "\n"


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("files", nargs="+", type=Path)
    ap.add_argument("--out-dir", required=True, type=Path)
    ap.add_argument("--tenants", default="", help="comma-separated; overrides discovery")
    ap.add_argument("--tenants-from-cluster", action="store_true")
    ap.add_argument("--context", default=None)
    ap.add_argument("--arg", default="", help="value the block renderer needs (URL/endpoint)")
    args = ap.parse_args()

    if args.tenants:
        tenants = [t for t in args.tenants.split(",") if t]
    elif args.tenants_from_cluster:
        tenants = capsule_tenants(args.context)
    else:
        tenants = []

    args.out_dir.mkdir(parents=True, exist_ok=True)
    for src in args.files:
        dst = args.out_dir / src.name.removesuffix(".tpl")
        dst.write_text(render(src.read_text(), tenants, args.arg))
        print(dst)
    print(f"tenants: {', '.join(tenants) or '(none)'}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
