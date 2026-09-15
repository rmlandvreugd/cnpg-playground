# Plan: zot registry (pull-through proxy) + stacker builds for demo-app

Status: brainstorm / plan — nothing implemented yet. Tracked as a beads epic
("zot registry + stacker"), one child per spike below.

## Goals

1. Run **zot** as a separate host container ("node") on the `kind` docker
   network, fronted by **traefik-edge** (`zot.172-18-0-250.sslip.io`), same
   pattern as Vault.
2. Use zot as an **on-demand pull-through cache** for container images
   (docker.io, ghcr.io, quay.io, registry.k8s.io) used by the kind nodes.
3. Use zot as a pull-through cache for **OCI helm charts** used by the setup
   scripts.
4. Replace `docker build` + `kind load docker-image` for the demo-app
   (`demo/self-service-setup.sh`) with a **stacker** build published to zot.

## Research findings

Sources: deepwiki (project-zot/zot), context7 (`/project-zot/zot`,
`/websites/kind_sigs_k8s_io`), zotregistry.dev v2.1.21, stackerbuild.io v1.0.0,
GitHub releases. Stacker is not indexed on deepwiki.

| Topic | Finding |
|---|---|
| Pull-through images | `extensions.sync` registry entries with `onDemand: true` |
| OCI helm charts | Synced like any OCI artifact; `helm pull oci://zot/<prefix>/...` |
| Classic helm repos (`index.yaml`) | **Not supported** by zot sync |
| containerd `?ns=` param | Not used by zot for routing → one sync entry per upstream with a `destination` prefix, plus `override_path = true` in containerd `hosts.toml` |
| Docker Hub | On-demand only (rate limits, no catalog). Use a `credentialsFile` |
| Digest-pinned pulls | Need `http.compat: ["docker2s2"]` + `preserveDigest: true`, otherwise zot converts to OCI and digests change (CNPG image catalogs pin digests) |
| Versions | zot **v2.1.21** (2026-09-06). stacker v1.2.1 release has **no binary assets** → pin **v1.2.0** (`stacker-linux-amd64`) |
| stacker on this WSL2 host | `stacker check` passes (overlay + userns, kernel 6.18 WSL2). Unprivileged busybox smoke build succeeded. `couldn't find AppArmor profile lxc-container-default-cgns` warning is harmless (no AppArmor on WSL) |

### Helm chart sources today

Already OCI (proxyable): kube-prometheus-stack, mimir, tempo, loki,
opentelemetry-collector, traefik, grafana-operator, cert-manager, trust-manager,
capsule, capsule-proxy, kyverno, argo-cd.

Not OCI (`--repo-url`, **not** proxyable by zot sync): cloudnative-pg charts,
calico (tigera-operator + CRDs), kyverno-policies, policy-reporter, grafana
alloy.

## Design A — zot as edge-fronted host container

- Container `zot` on docker network `kind`, config + htpasswd + storage
  bind-mounted from `zot/` (storage dir gitignored).
- `traefik-edge/dynamic/zot.yaml`: router `Host(zot.172-18-0-250.sslip.io)` →
  `http://zot:5000`.
- `scripts/traefik-edge-setup.sh`: `_issue_cert "zot" "zot.${TRAEFIK_EDGE_IP_DASHED}.sslip.io" "zot" "localhost" "127.0.0.1"`.
- Traefik v3 `entryPoints.websecure.transport.respondingTimeouts.readTimeout`
  defaults to 60s → raise it (large blob pushes) or blobs uploads get cut.

### zot config sketch

```json
{
  "storage": { "rootDirectory": "/var/lib/registry" },
  "http": {
    "address": "0.0.0.0", "port": "5000",
    "externalUrl": "https://zot.172-18-0-250.sslip.io",
    "compat": ["docker2s2"],
    "auth": { "htpasswd": { "path": "/etc/zot/htpasswd" } },
    "accessControl": { "repositories": {
      "**":      { "anonymousPolicy": ["read"] },
      "apps/**": { "policies": [{ "users": ["ci"], "actions": ["read", "create", "update"] }] }
    } }
  },
  "extensions": { "sync": {
    "enable": true,
    "credentialsFile": "/etc/zot/sync-auth.json",
    "registries": [
      { "urls": ["https://registry-1.docker.io"], "onDemand": true, "preserveDigest": true,
        "content": [{ "prefix": "**", "destination": "/docker.io" }] },
      { "urls": ["https://ghcr.io"], "onDemand": true, "preserveDigest": true,
        "content": [{ "prefix": "**", "destination": "/ghcr.io" }] },
      { "urls": ["https://quay.io"], "onDemand": true, "preserveDigest": true,
        "content": [{ "prefix": "**", "destination": "/quay.io" }] },
      { "urls": ["https://registry.k8s.io"], "onDemand": true, "preserveDigest": true,
        "content": [{ "prefix": "**", "destination": "/registry.k8s.io" }] }
    ]
  } }
}
```

To verify in spike 1: `**` + `destination` + default `stripPrefix` yields
`/docker.io/library/postgres` (not a doubled path), and on-demand works for
helm chart tags.

### kind nodes → containerd mirrors

kind v0.27+ node images already use `config_path = "/etc/containerd/certs.d"`.
Mount a repo dir (e.g. `k8s/containerd-certs.d/`) into every node via
`extraMounts` in `k8s/kind-cluster.yaml.tpl`, one `hosts.toml` per upstream:

```toml
# k8s/containerd-certs.d/docker.io/hosts.toml
server = "https://registry-1.docker.io"

[host."https://zot.172-18-0-250.sslip.io/v2/docker.io"]
  capabilities = ["pull", "resolve"]
  override_path = true
  ca = "/etc/containerd/certs.d/step-ca-chain.pem"
```

Plus `k8s/containerd-certs.d/zot.172-18-0-250.sslip.io/hosts.toml` (just `ca`)
for images pulled directly from zot (demo-app).

If zot is down containerd falls back to `server`, so ordering is not fatal:
zot + edge currently start after `kind create cluster` (the `kind` network is
created by kind). Early bootstrap images then simply miss the cache. For full
caching, pre-create the `kind` network (matching subnet) and start zot + edge
before the cluster.

### Helm → OCI proxy

Helm has no mirror config; chart refs must be rewritten.

- `common.sh`: `OCI_PROXY="${OCI_PROXY:-zot.${TRAEFIK_EDGE_IP_DASHED}.sslip.io}"`.
- In `helm_upgrade_install`: rewrite `oci://<host>/<path>` →
  `oci://${OCI_PROXY}/<host>/<path>` when `OCI_PROXY` is set (empty = direct).
- CA trust: add step-ca root to the WSL host trust store, or pass `--ca-file`.
- ArgoCD: OCI helm repo credentials/`enableOCI` for zot if any Application
  sources charts from OCI (demo-app chart is git-sourced).
- Non-OCI charts, choose:
  1. leave direct (simplest), or
  2. seed script: `helm pull --repo <url> <chart> --version <v>` →
     `helm push <tgz> oci://${OCI_PROXY}/charts`, then install from zot.

## Design B — stacker replaces docker build + kind load

`app/stacker.yaml` (translation of `app/Dockerfile`):

```yaml
uv:
  from:
    type: docker
    url: "docker://zot.172-18-0-250.sslip.io/ghcr.io/astral-sh/uv:latest"
  build_only: true

builder:
  from:
    type: docker
    url: "docker://zot.172-18-0-250.sslip.io/docker.io/library/python:3.12-slim"
  build_only: true
  imports:
    - stacker://uv/uv
    - path: pyproject.toml
    - path: uv.lock
    - path: src
  binds:
    - ${{UV_CACHE}} -> /root/.cache/uv   # replaces RUN --mount=type=cache
  run: |
    cp /stacker/imports/uv /bin/uv
    mkdir -p /app && cp -r /stacker/imports/* /app/ && cd /app
    UV_COMPILE_BYTECODE=1 UV_LINK_MODE=copy UV_PYTHON_DOWNLOADS=0 uv sync --locked --no-dev

demo-app:
  from:
    type: docker
    url: "docker://zot.172-18-0-250.sslip.io/docker.io/library/python:3.12-slim"
  imports:
    - stacker://builder/app
  run: |
    groupadd --system --gid 1000 appuser
    useradd --system --gid 1000 --uid 1000 --create-home appuser
    cp -a /stacker/imports/app /app && chown -R 1000:1000 /app
  environment:
    PATH: "/app/.venv/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
    PYTHONUNBUFFERED: "1"
    OTEL_PYTHON_LOGGING_AUTO_INSTRUMENTATION_LEVEL: info
  working_dir: /app
  runtime_user: "1000"
  full_command: [litestar, run, --host, 0.0.0.0, --port, "8000"]
```

`demo/self-service-setup.sh` (replaces the docker build / kind load block):

```bash
stacker build -f "${GIT_REPO_ROOT}/app/stacker.yaml" --substitute UV_CACHE="${HOME}/.cache/uv"
stacker publish -f "${GIT_REPO_ROOT}/app/stacker.yaml" \
  --url "docker://${OCI_PROXY}/apps" --tag "${DEMO_APP_VERSION}" \
  --username ci --password "${ZOT_CI_PASSWORD}"
```

`app/helm/demo-app/values-rbr-ver.yaml`:
`image.repository: zot.172-18-0-250.sslip.io/apps/demo-app`,
`pullPolicy: IfNotPresent` (was `Never`). Anonymous read → no imagePullSecret.

Gotchas:

- No `.dockerignore` equivalent: import explicit paths so `.venv/`, `tests/`
  don't leak into the image.
- `stacker://` import paths/layout (`stacker://builder/app` as a directory)
  must be verified in the spike.
- Pin stacker in `mise.toml` to `1.2.0` (`github:project-stacker/stacker`).
- `stacker publish` TLS: trust step-ca root on the host (avoid `--skip-tls`).
- Keep Docker for the inner dev loop (`app/Tiltfile`, `app/compose.yaml`);
  only the setup-script path moves to stacker.

## Spikes (beads children)

| # | Spike | Done when | Estimate |
|---|---|---|---|
| 1 | zot container + edge route + cert | `curl https://zot…/v2/` 200; `helm pull oci://zot…/ghcr.io/traefik/helm/traefik` works; digest-pinned pull keeps digest | 1–2 h |
| 2 | containerd mirrors in kind | cluster recreated; `crictl pull` on a node shows hit in zot logs; fallback works with zot stopped | 2 h + rebuild |
| 3 | helm OCI ref rewrite | `helm_upgrade_install` prefixes `OCI_PROXY`; decision on non-OCI charts recorded | 1 h |
| 4 | stacker demo-app build | stacker build + publish to zot; ArgoCD demo-app runs image from zot; `kind load` removed | 2–3 h |
| 5 | docs | architecture-overview + self-service-demo updated; zot metrics ServiceMonitor optional | 30 min |

## Open decisions

- zot storage: local bind-mounted dir (recommended start) vs SeaweedFS S3.
- Push auth: htpasswd `ci` user (recommended) vs Authelia OIDC for zot UI.
  containerd can't do OIDC, so pulls stay anonymous either way.
- Non-OCI charts: leave direct vs rehost in zot.

## Later / optional

- zot `search` + `ui` extensions, trivy CVE scanning.
- zot metrics scraped like traefik-edge (`monitoring/platform/`).
