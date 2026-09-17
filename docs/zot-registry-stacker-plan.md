# Plan: zot registry (pull-through proxy) + stacker builds for demo-app

Status: plan — nothing implemented yet. Tracked as beads epic
`cnpg-playground-2k1`, one child per spike (see [Spikes](#spikes-beads-children)).

## Goals

1. Run **zot** as a separate host container ("node") on the `kind` docker
   network, fronted by **traefik-edge** (`zot.172-28-0-250.sslip.io`), same
   pattern as Vault / SeaweedFS.
2. Use zot as an **on-demand pull-through cache** for container images
   (docker.io, ghcr.io, quay.io, registry.k8s.io) used by the kind nodes.
3. Use zot as a pull-through cache for **OCI helm charts** used by the setup
   scripts.
4. Replace `docker build` + `kind load docker-image` for the demo-app
   (`demo/self-service-setup.sh`) with a **stacker** build published to zot.
5. Store zot blobs in **SeaweedFS S3**.
6. **htpasswd** for pushes, **Authelia OIDC** for the zot UI, anonymous pulls.
7. zot **search + UI**, **CVE scanning**, and **Prometheus metrics**.

## Decisions

| Topic | Decision | Consequence |
|---|---|---|
| zot storage | **SeaweedFS S3** (bucket `zot`) | zot-native CVE scanning is impossible (see below); dedupe uses local boltdb |
| Push auth | **htpasswd** user `ci` | stacker/helm/skopeo push with basic auth |
| UI auth | **Authelia OIDC** (`oidc` provider) | new Authelia client `zot`, group `zot-admin` |
| Pull auth | anonymous read | containerd can't do OIDC; no imagePullSecrets |
| Non-OCI helm charts | **leave direct** | cloudnative-pg, calico, kyverno-policies, policy-reporter, alloy keep `--repo-url` |
| CVE scanning | **trivy CLI outside zot** | zot UI shows no CVE data; setup prints a trivy report |

## Research findings

Sources: deepwiki (project-zot/zot), context7 (`/project-zot/zot`,
`/websites/kind_sigs_k8s_io`, `/websites/authelia`, `/websites/trivy_dev`),
zotregistry.dev v2.1.21, stackerbuild.io v1.0.0, zot v2.1.21 source
(`pkg/cli/server/root.go`, `pkg/api/authz.go`, `pkg/api/config/config.go`),
GitHub releases. Stacker is not indexed on deepwiki.

### Registry / proxy

| Topic | Finding |
|---|---|
| Pull-through images | `extensions.sync` registry entries with `onDemand: true` |
| OCI helm charts | Synced like any OCI artifact; `helm pull oci://zot/<prefix>/...` |
| Classic helm repos (`index.yaml`) | **Not supported** by zot sync |
| containerd `?ns=` param | Not used by zot for routing → one sync entry per upstream with a `destination` prefix, plus `override_path = true` in containerd `hosts.toml` |
| Docker Hub | On-demand only (rate limits, no catalog). Use a `credentialsFile` |
| Digest-pinned pulls | Need `http.compat: ["docker2s2"]` + `preserveDigest: true`, otherwise zot converts to OCI and digests change (CNPG image catalogs pin digests) |
| Image | `ghcr.io/project-zot/zot-linux-amd64:v2.1.21` (full build, includes UI; `-minimal` does not). Cmd `serve /etc/zot/config.json`, runs as uid 0, honours `SSL_CERT_FILE` |

### Storage (SeaweedFS S3) — verified in source

| Topic | Finding |
|---|---|
| S3 driver | `storage.storageDriver` `{name: s3, rootdirectory, region, bucket, regionendpoint, forcepathstyle, secure, skipverify, accesskey, secretkey}` |
| Dedupe | `dedupe: true` + `remoteCache: true` with no `cacheDriver` → startup error (`root.go:438`). Remote cache must be redis/dynamodb. `dedupe: true` + `remoteCache: false` → **local boltdb** under `storage.rootDirectory` (valid) |
| CVE scanning | **Any S3 `storageDriver` + CVE enabled → startup error** "failed to enable cve scanning due to incompatibility with remote storage" (`root.go:681`, also for subPaths) |
| Endpoint TLS | No per-driver CA option; use SeaweedFS plain-HTTP S3 port `8334` on the internal `kind` network (`secure: false`) |
| Sync + remote storage | **S3 `storageDriver` + `extensions.sync` enabled requires `extensions.sync.downloadDir`** → startup error "using both sync and remote storage features needs config.Extensions.Sync.DownloadDir to be specified" otherwise (`root.go:729`). Not caught by source review — found running spike 1 live; fixed with `downloadDir: /tmp/zot-sync` |

### Auth — verified in source

| Topic | Finding |
|---|---|
| Multiple methods | htpasswd + openid can be enabled together; basic auth (htpasswd / API keys) is tried first, then session cookie, then anonymous |
| Generic OIDC | Provider key must be `oidc` (`openIDSupportedProviders = google, gitlab, oidc`); fields `name, issuer, clientid, clientsecret, scopes, claimMapping{username, groups}` |
| Callback | `https://<externalUrl>/zot/auth/callback/oidc` |
| Sessions | `sessionKeysFile` JSON `{"hashKey": "...", "encryptKey": "..."}` (else keys regenerate on restart). `secureSession: true` needed because TLS terminates at the edge, not in zot |
| Groups | `claimMapping.groups` → zot groups usable in `accessControl` policies / `adminPolicy` |
| API keys | `http.auth.apikey: true` lets UI users mint `zak_…` keys usable as basic-auth passwords (optional) |
| Authelia | `token_endpoint_auth_method` defaults to `client_secret_basic`; PKCE optional for confidential clients. Existing `default_policy` claims policy already puts `groups` + `preferred_username` in the ID token |

### Search / UI / metrics — verified in source

| Topic | Finding |
|---|---|
| UI | `extensions.ui.enable` requires `extensions.search.enable` (`root.go:671`) |
| Search on S3 | Works; only the `search.cve` part is rejected with S3 |
| Metrics | `extensions.metrics.enable`, `prometheus.path` (default `/metrics`), same port as the registry |
| Metrics auth | With accessControl present: anonymous allowed only if `accessControl.metrics.anonymousPolicy` contains `read`; authenticated users only if in `accessControl.metrics.users` (`authz.go:924-946`) |
| Metric names | `zot_http_requests_total`, `zot_http_repo_latency_seconds`, `zot_repo_storage_bytes`, `zot_repo_downloads_total`, `zot_repo_uploads_total`, `zot_storage_lock_latency_seconds`, `zot_scheduler_*` |
| Dashboards | No upstream Grafana dashboard or ServiceMonitor |

### Trivy

| Topic | Finding |
|---|---|
| DB mirror | `--db-repository` / `--java-db-repository` (defaults `ghcr.io/aquasecurity/trivy-db:2`, `ghcr.io/aquasecurity/trivy-java-db:1`) → can point at zot's ghcr.io mirror |
| Remote scan | `--image-src remote`; `--severity HIGH,CRITICAL --exit-code 1` for gating |

### Stacker

| Topic | Finding |
|---|---|
| Versions | stacker v1.2.1 release has **no binary assets** → pin **v1.2.0** (`stacker-linux-amd64`) |
| This WSL2 host | `stacker check` passes (overlay + userns, kernel 6.18 WSL2). Unprivileged busybox smoke build succeeded. `couldn't find AppArmor profile lxc-container-default-cgns` warning is harmless |

### Helm chart sources today

Already OCI (proxied via zot): kube-prometheus-stack, mimir, tempo, loki,
opentelemetry-collector, traefik, grafana-operator, cert-manager, trust-manager,
capsule, capsule-proxy, kyverno, argo-cd.

Not OCI (`--repo-url`, **stay direct** by decision): cloudnative-pg charts,
calico (tigera-operator + CRDs), kyverno-policies, policy-reporter, grafana
alloy.

## Design A — zot host container, SeaweedFS storage, edge route

### Topology

```
kind nodes (containerd hosts.toml) ──┐
helm / stacker / trivy (WSL host) ───┼─> traefik-edge 172.28.0.250 ──> zot 172.28.0.251:5000
browser (UI) ────────────────────────┘      zot.172-28-0-250.sslip.io     │  ├─ S3 ──> seaweedfs:8334 (bucket zot)
                                                                          │  ├─ OIDC ─> authelia.172-28-0-250.sslip.io (via edge)
Prometheus (otel ns) ── Endpoints 172.28.0.251:5000/metrics ──────────────┘  └─ sync ─> docker.io / ghcr.io / quay.io / registry.k8s.io
```

### Setup sequencing

zot depends on SeaweedFS (connected to `kind` after cluster create), Authelia
and traefik-edge, so it starts **after** the edge (`scripts/setup.sh` ≈ line
573). Early bootstrap images pulled by the nodes before zot exists fall back to
upstream through containerd's `server` entry — not fatal, just not cached.

### New variables (`scripts/common.sh`)

```bash
# zot registry (host container on kind network, fronted by traefik-edge)
ZOT_IMAGE="${ZOT_IMAGE:-ghcr.io/project-zot/zot-linux-amd64:v2.1.21}"
ZOT_CONTAINER_NAME="${ZOT_CONTAINER_NAME:-zot}"
ZOT_IP="${ZOT_IP:-172.28.0.251}"          # static: metrics Endpoints target
ZOT_PORT="${ZOT_PORT:-5000}"
ZOT_HOST="zot.${TRAEFIK_EDGE_IP_DASHED}.sslip.io"
OCI_PROXY="${OCI_PROXY:-${ZOT_HOST}}"     # empty = pull helm charts direct
ZOT_CI_USER="${ZOT_CI_USER:-ci}"
ZOT_CI_PASSWORD="${ZOT_CI_PASSWORD:-zotCIsecret}"
SEAWEEDFS_ZOT_BUCKET="${SEAWEEDFS_ZOT_BUCKET:-zot}"
SEAWEEDFS_ZOT_ACCESS_KEY="${SEAWEEDFS_ZOT_ACCESS_KEY:-zot}"
SEAWEEDFS_ZOT_SECRET_KEY="${SEAWEEDFS_ZOT_SECRET_KEY:-zotS3secret}"
```

### SeaweedFS changes (`scripts/setup.sh`)

- `identities.json`: new least-privilege identity (same shape as `loki`/`barman`):

  ```json
  {
    "name": "zot",
    "credentials": [{"accessKey": "${SEAWEEDFS_ZOT_ACCESS_KEY}", "secretKey": "${SEAWEEDFS_ZOT_SECRET_KEY}"}],
    "actions": ["Read:${SEAWEEDFS_ZOT_BUCKET}", "Write:${SEAWEEDFS_ZOT_BUCKET}", "List:${SEAWEEDFS_ZOT_BUCKET}", "Tagging:${SEAWEEDFS_ZOT_BUCKET}"]
  }
  ```

- Bucket bootstrap (`mc mb --ignore-existing`, admin identity): add
  `sw/${SEAWEEDFS_ZOT_BUCKET}`.

### zot files (`zot/`, rendered, secrets gitignored)

- `zot/config.json.tpl` → `envsubst` → `zot/config.json`
- `zot/htpasswd` — `htpasswd -Bbn "${ZOT_CI_USER}" "${ZOT_CI_PASSWORD}"`
  (bcrypt; via `docker run --rm httpd:2.4-alpine htpasswd …` if not installed)
- `zot/session-keys.json` — `{"hashKey": "<openssl rand -hex 32>", "encryptKey": "<openssl rand -hex 16>"}`
- `zot/ca-bundle.crt` — system CA bundle + `step-ca/pki/{intermediate,root}_ca.crt`
  (needed for Authelia issuer TLS; upstream registries use public CAs)

### zot config (`zot/config.json.tpl`)

```json
{
  "distSpecVersion": "1.1.1",
  "log": { "level": "info" },
  "storage": {
    "rootDirectory": "/var/lib/zot",
    "dedupe": true,
    "remoteCache": false,
    "gc": true,
    "storageDriver": {
      "name": "s3",
      "rootdirectory": "/zot",
      "region": "us-east-1",
      "bucket": "${SEAWEEDFS_ZOT_BUCKET}",
      "regionendpoint": "http://seaweedfs:8334",
      "forcepathstyle": true,
      "secure": false,
      "skipverify": false,
      "accesskey": "${SEAWEEDFS_ZOT_ACCESS_KEY}",
      "secretkey": "${SEAWEEDFS_ZOT_SECRET_KEY}"
    }
  },
  "http": {
    "address": "0.0.0.0",
    "port": "5000",
    "externalUrl": "https://${ZOT_HOST}",
    "compat": ["docker2s2"],
    "auth": {
      "htpasswd": { "path": "/etc/zot/htpasswd" },
      "openid": {
        "providers": {
          "oidc": {
            "name": "Authelia",
            "issuer": "https://authelia.${TRAEFIK_EDGE_IP_DASHED}.sslip.io",
            "clientid": "zot",
            "clientsecret": "${AUTHELIA_ZOT_CLIENT_SECRET}",
            "scopes": ["openid", "profile", "email", "groups"],
            "claimMapping": { "username": "preferred_username", "groups": "groups" }
          }
        }
      },
      "sessionKeysFile": "/etc/zot/session-keys.json",
      "secureSession": true,
      "apikey": true
    },
    "accessControl": {
      "repositories": {
        "**": {
          "anonymousPolicy": ["read"],
          "defaultPolicy": ["read"]
        },
        "apps/**": {
          "anonymousPolicy": ["read"],
          "policies": [
            { "users": ["${ZOT_CI_USER}"], "actions": ["read", "create", "update"] }
          ]
        }
      },
      "adminPolicy": {
        "groups": ["zot-admin"],
        "actions": ["read", "create", "update", "delete"]
      },
      "metrics": { "anonymousPolicy": ["read"] }
    }
  },
  "extensions": {
    "search": { "enable": true },
    "ui": { "enable": true },
    "metrics": { "enable": true, "prometheus": { "path": "/metrics" } },
    "sync": {
      "enable": true,
      "downloadDir": "/tmp/zot-sync",
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
    }
  }
}
```

No `search.cve` block: CVE must stay disabled with S3 storage.

To verify in spike 1/6:

- `**` + `destination` + default `stripPrefix` yields `/docker.io/library/postgres`
  (not a doubled path); on-demand works for helm chart tags.
- Glob precedence: `apps/**` policy applies to `apps/demo-app` in addition to
  the `**` anonymous read (zot matches the most specific pattern).
- Env var substitution: `$` in bcrypt/secret values is not mangled by `envsubst`
  (pass an explicit variable list, as `authelia-setup.sh` does).

### zot container (`scripts/zot-setup.sh`, called from `scripts/setup.sh` after the edge)

```bash
${CONTAINER_PROVIDER} volume create zot-meta > /dev/null
${CONTAINER_PROVIDER} run -d --name "${ZOT_CONTAINER_NAME}" \
  --network kind --ip "${ZOT_IP}" \
  -v "${ZOT_DIR}/config.json:/etc/zot/config.json:ro" \
  -v "${ZOT_DIR}/htpasswd:/etc/zot/htpasswd:ro" \
  -v "${ZOT_DIR}/session-keys.json:/etc/zot/session-keys.json:ro" \
  -v "${ZOT_DIR}/sync-auth.json:/etc/zot/sync-auth.json:ro" \
  -v "${ZOT_DIR}/ca-bundle.crt:/etc/zot/ca-bundle.crt:ro" \
  -e SSL_CERT_FILE=/etc/zot/ca-bundle.crt \
  -v zot-meta:/var/lib/zot \
  --restart unless-stopped \
  "${ZOT_IMAGE}"
```

`zot-meta` holds the boltdb dedupe cache + metadata DB; blobs live in SeaweedFS.
Teardown (`scripts/teardown.sh`) removes the container and volume.

### traefik-edge

- `scripts/traefik-edge-setup.sh`:
  `_issue_cert "zot" "zot.${TRAEFIK_EDGE_IP_DASHED}.sslip.io" "zot" "localhost" "127.0.0.1"`
- `traefik-edge/dynamic/zot.yaml`:

  ```yaml
  http:
    routers:
      zot:
        # /metrics is scraped in-network (172.28.0.251:5000), never via the edge.
        rule: "Host(`zot.172-28-0-250.sslip.io`) && !PathPrefix(`/metrics`)"
        entryPoints:
          - websecure
        service: zot
        tls: {}
    services:
      zot:
        loadBalancer:
          servers:
            - url: "http://zot:5000"
          healthCheck:
            path: /v2/
            interval: 10s
  ```

- `traefik-edge/traefik.yaml`: raise
  `entryPoints.websecure.transport.respondingTimeouts.readTimeout` (v3 default
  60s) so large blob pushes are not cut, e.g. `0s` or `30m`.
- No Authelia forward-auth middleware on this router: the registry API must stay
  anonymous/basic-auth; the UI does its own OIDC login.

### kind nodes → containerd mirrors

kind v0.27+ node images already use `config_path = "/etc/containerd/certs.d"`.
Mount a repo dir (e.g. `k8s/containerd-certs.d/`) into every node via
`extraMounts` in `k8s/kind-cluster.yaml.tpl`, one `hosts.toml` per upstream:

```toml
# k8s/containerd-certs.d/docker.io/hosts.toml
server = "https://registry-1.docker.io"

[host."https://zot.172-28-0-250.sslip.io/v2/docker.io"]
  capabilities = ["pull", "resolve"]
  override_path = true
  ca = "/etc/containerd/certs.d/step-ca-chain.pem"
```

Plus `k8s/containerd-certs.d/zot.172-28-0-250.sslip.io/hosts.toml` (just `ca`)
for images pulled directly from zot (demo-app). If zot is down containerd falls
back to `server`.

### Helm → OCI proxy

Helm has no mirror config; chart refs are rewritten.

- In `helm_upgrade_install` (`scripts/common.sh`): rewrite `oci://<host>/<path>`
  → `oci://${OCI_PROXY}/<host>/<path>` when `OCI_PROXY` is set (empty = direct).
- `--repo-url` charts are untouched (decision: leave direct).
- CA trust: step-ca root in the WSL host trust store, or `--ca-file`.
- ArgoCD: OCI helm repo credentials/`enableOCI` for zot only if an Application
  sources charts from OCI (demo-app chart is git-sourced today).

## Design B — stacker replaces docker build + kind load

`app/stacker.yaml` (translation of `app/Dockerfile`):

```yaml
uv:
  from:
    type: docker
    url: "docker://zot.172-28-0-250.sslip.io/ghcr.io/astral-sh/uv:latest"
  build_only: true

builder:
  from:
    type: docker
    url: "docker://zot.172-28-0-250.sslip.io/docker.io/library/python:3.12-slim"
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
    url: "docker://zot.172-28-0-250.sslip.io/docker.io/library/python:3.12-slim"
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
  --username "${ZOT_CI_USER}" --password "${ZOT_CI_PASSWORD}"
```

`app/helm/demo-app/values-rbr-ver.yaml`:
`image.repository: zot.172-28-0-250.sslip.io/apps/demo-app`,
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

## Design C — zot UI + search with Authelia OIDC

- zot: `extensions.search` + `extensions.ui` enabled, `openid.providers.oidc`,
  `sessionKeysFile`, `secureSession`, `adminPolicy.groups: [zot-admin]` (see
  config above). Browse `https://zot.172-28-0-250.sslip.io` → "Sign in with
  Authelia".
- Authelia client, added to **both** `authelia/config/configuration.yaml.tpl`
  and `authelia/config/configuration-two-domains.yaml.tpl`:

  ```yaml
      - client_id: zot
        client_name: zot
        client_secret: '${AUTHELIA_ZOT_CLIENT_SECRET_HASH}'
        authorization_policy: one_factor
        redirect_uris:
          - 'https://zot.${TRAEFIK_EDGE_IP_DASHED}.sslip.io/zot/auth/callback/oidc'
        scopes:
          - openid
          - email
          - profile
          - groups
        claims_policy: 'default_policy'
        userinfo_signed_response_alg: none
        token_endpoint_auth_method: client_secret_basic
  ```

- `scripts/authelia-setup.sh`: generate `AUTHELIA_ZOT_CLIENT_SECRET`, hash it
  (`_hash_secret`) into `AUTHELIA_ZOT_CLIENT_SECRET_HASH`, add both to the
  explicit `envsubst` variable list; export the plain secret for
  `zot/config.json.tpl` rendering.
- `authelia/config/users_database.yml.tpl`: add `zot-admin` to the `admin` user
  (other personas get anonymous read only via the UI session).
- Network path: zot resolves `authelia.172-28-0-250.sslip.io` → edge on the
  `kind` network; TLS verified via `SSL_CERT_FILE` bundle incl. step-ca chain.
- API keys (`apikey: true`): a signed-in `zot-admin` can mint a `zak_…` key and
  use it as a basic-auth password for pushes, as an alternative to the shared
  `ci` htpasswd user.

## Design D — CVE scanning with trivy (outside zot)

zot-native CVE scanning is **rejected by zot at startup when S3 storage is
configured**, so scanning moves to the trivy CLI.

- Add `trivy` to `mise.toml` (pinned).
- After `stacker publish` in `demo/self-service-setup.sh`:

  ```bash
  SSL_CERT_FILE="${GIT_REPO_ROOT}/zot/ca-bundle.crt" \
  trivy image --image-src remote \
    --db-repository "${OCI_PROXY}/ghcr.io/aquasecurity/trivy-db:2" \
    --java-db-repository "${OCI_PROXY}/ghcr.io/aquasecurity/trivy-java-db:1" \
    --severity HIGH,CRITICAL --exit-code 0 \
    "${OCI_PROXY}/apps/demo-app:${DEMO_APP_VERSION}"
  ```

  `--exit-code 0` = report only in the demo; flip to `1` to gate.
- The trivy DBs are pulled through zot's ghcr.io mirror, so repeated setups
  don't hit ghcr.io.
- Optional follow-up: Trivy Operator in-cluster for running workloads
  (VulnerabilityReports), feeding policy-reporter.
- Rejected alternative: a second zot with local storage just for CVE data —
  doubles config/ops for a demo.

## Design E — zot metrics in Prometheus

- zot: `extensions.metrics.enable`, `accessControl.metrics.anonymousPolicy: ["read"]`
  (config above). Endpoint `http://172.28.0.251:5000/metrics`; not exposed via
  the edge (`!PathPrefix(/metrics)` in the router rule).
- `monitoring/platform/zot-servicemonitor.yaml`, same pattern as
  `traefik-edge-servicemonitor.yaml`:

  ```yaml
  # Static Service + Endpoints for zot Prometheus metrics (host container).
  # zot exposes /metrics at 172.28.0.251:5000 (ZOT_IP:ZOT_PORT), anonymous read.
  apiVersion: v1
  kind: Service
  metadata:
    name: zot-metrics
    namespace: otel
    labels:
      app.kubernetes.io/name: zot-metrics
  spec:
    clusterIP: None
    ports:
      - name: metrics
        port: 5000
        targetPort: 5000
        protocol: TCP
  ---
  apiVersion: v1
  kind: Endpoints
  metadata:
    name: zot-metrics
    namespace: otel
  subsets:
    - addresses:
        - ip: 172.28.0.251
      ports:
        - name: metrics
          port: 5000
          protocol: TCP
  ---
  apiVersion: monitoring.coreos.com/v1
  kind: ServiceMonitor
  metadata:
    name: zot
    namespace: otel
  spec:
    selector:
      matchLabels:
        app.kubernetes.io/name: zot-metrics
    endpoints:
      - port: metrics
        path: /metrics
        scheme: http
  ```

- `monitoring/setup.sh`: apply it next to `traefik-edge-servicemonitor.yaml`
  (≈ line 358).
- Optional: a small GrafanaDashboard (grafana-operator) — no upstream dashboard
  exists. Panels: `rate(zot_http_requests_total[5m])` by code,
  `zot_repo_storage_bytes` by repo, `zot_repo_downloads_total` (cache hits per
  mirrored repo), `zot_http_repo_latency_seconds`.

## Spikes (beads children)

| Beads | Spike | Blocked by | Done when | Estimate |
|---|---|---|---|---|
| `2k1.1` | zot container (SeaweedFS S3, htpasswd push) + edge route + cert | — | `curl https://zot…/v2/` 200; blobs in SeaweedFS `zot` bucket; `helm pull oci://zot…/ghcr.io/traefik/helm/traefik` works; digest-pinned pull keeps digest; `ci` push ok, anonymous push 401 | 2–3 h |
| `2k1.2` | containerd mirrors in kind | 2k1.1 | cluster recreated; `crictl pull` on a node shows hit in zot logs; fallback works with zot stopped | 2 h + rebuild |
| `2k1.3` | helm OCI ref rewrite (`OCI_PROXY`) | 2k1.1 | `helm_upgrade_install` prefixes `OCI_PROXY`; `--repo-url` charts untouched | 1 h |
| `2k1.4` | stacker demo-app build + publish | 2k1.1, 2k1.2 | stacker build + publish to zot; ArgoCD demo-app runs image from zot; `kind load` removed | 2–3 h |
| `2k1.6` | zot UI + search with Authelia OIDC | 2k1.1 | UI login via Authelia; `zot-admin` can delete; anonymous pull + `ci` push still work | 1–2 h |
| `2k1.7` | CVE scanning with trivy CLI | 2k1.1, 2k1.4 | setup prints trivy HIGH/CRITICAL report for demo-app; trivy DB pulled via zot | 1 h |
| `2k1.8` | zot metrics ServiceMonitor | 2k1.1 | zot target UP; `zot_http_requests_total` queryable in Grafana | 1 h (+1 h dashboard) |
| `2k1.5` | docs | 2k1.2–2k1.4, 2k1.6–2k1.8 | architecture-overview + self-service-demo updated; this plan marked implemented | 45 min |

Suggested order: 1 → (2, 3, 6, 8 in any order) → 4 → 7 → 5.
