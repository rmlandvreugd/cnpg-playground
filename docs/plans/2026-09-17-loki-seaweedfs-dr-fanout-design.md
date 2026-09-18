# Loki S3 Storage A/B/C: RustFS-direct vs in-cluster SeaweedFS (+ RustFS mirror) vs host SeaweedFS

**Date:** 2026-09-17 (rev 2: 2026-09-18 adversarial review; rev 3: 2026-09-18 live-cluster review)
**Status:** Design — decisions closed, ready to implement
**Owner:** monitoring stack
**Tracking:** epic `cnpg-playground-t9p7` → `.1` operator → `8ti` Seaweed CR + mirror → `dfe` Lokis → `.2` k8s-monitoring + OTel log fan-out → `.3` benchmark → `.4` architecture-overview (§8a); bug `eff0` (Reloader) blocks `dfe`
**Target environment:** a cluster built with `./scripts/setup.sh local` (single region `local` = hub, one RustFS `objectstore-local`, host SeaweedFS container) followed by `./monitoring/setup.sh`.

> Rev 1 of this doc proposed one in-cluster SeaweedFS fanning out to two DR sinks (external SeaweedFS + RustFS) via two `weed filer.remote.gateway` sidecars. That mechanism does not work (see §9). Rev 2 records the reworked design and the decisions from the 2026-09-18 review.

---

## 1. Goal

Measure how Loki performs against S3 storage **outside** the cluster versus **inside** the cluster, with the in-cluster store also mirroring to the outside store for DR.

- Node logs and pod logs are collected by Alloy (Grafana **k8s-monitoring** chart, features `nodeLogs` + `podLogsViaLoki`) and pushed to every Loki.
- Grafana queries each Loki through its own datasource.
- All Lokis run side-by-side under identical load.

Verdict metrics (user decision): **query latency over old time ranges**, **S3 operation latency p50/p99**, **resource cost**. A **restore drill** from the mirror is a pass/fail gate (not scored).

---

## 2. Current state (verified 2026-09-18 against the `vault` branch)

| Fact | Evidence |
|---|---|
| `setup.sh local` → `REGIONS=(local)`, hub = `local` | `scripts/funcs_regions.sh` `set_regions`, `scripts/setup.sh:94-95` |
| Monitoring (incl. Loki) is **not** installed by `setup.sh` unless `--with-tenant`; run `monitoring/setup.sh` | `scripts/setup.sh:1375-1390` |
| Host SeaweedFS container `seaweedfs` (hub only), S3 HTTPS `:8333`, static identities `admin`/`loki`/`barman`/`zot` | `scripts/setup.sh:183-520` |
| Host SeaweedFS is **shared**: Loki bucket `loki`, CNPG Barman backups, **zot blob storage** (the containerd pull-through mirror) | `scripts/setup.sh:462-484,513-519`, `scripts/zot-setup.sh` |
| RustFS `objectstore-local` is **HTTPS-only** (restarted with `RUSTFS_TLS_PATH`), cert SANs = short name `objectstore-local`, `*.cnpg-system/mimir/tempo.svc` FQDNs, kind IP | `scripts/setup.sh:330-392` |
| RustFS is reached through **per-namespace** headless bridges (`mimir`, `tempo` only today) | `monitoring/mimir/objectstore-bridge.yaml.tpl`, `monitoring/setup.sh:58-66,120-128` |
| Loki today: release `loki`, ns `grafana`, chart `grafana-community/loki` 13.5.0 (Loki **3.7.1**), SingleBinary on infra nodes, bucket `loki` on host SeaweedFS via bridge Service `seaweedfs` | `monitoring/setup.sh:244-294`, `monitoring/loki/loki-values.yaml` |
| Rendered chart uses the **legacy** S3 client (`use_thanos_objstore: false`) and **hedging** `at: 250ms, up_to: 3` | `helm template` of 13.5.0 with current values |
| `compactor.retention_enabled` unset → no retention deletes today | `monitoring/loki/loki-values.yaml` |
| Loki `monitoring.serviceMonitor.enabled: false` → Loki metrics are not scraped | `monitoring/loki/loki-values.yaml` |
| Alloy today: release `alloy` (grafana/alloy 1.8.0) with custom River: pgaudit, `traefik_access`, `k8s_events`, system logs → `loki.grafana.svc:3100` | `monitoring/alloy/alloy-config.river` |
| Datasource uid `loki` is referenced by the Tempo datasource and dashboards | `monitoring/grafana/grafana_datasource_tempo.yaml:19,37` |
| `step-ca-external-bundle` is synced by trust-manager to **all** namespaces; `vault-pki-bundle` exists for Vault-PKI-issued certs; ClusterIssuer `vault-pki` | `step-ca/trust-manager/bundle-external.yaml`, `vault/trust-manager/bundle.yaml.tpl`, `vault/cert-manager/clusterissuer.yaml.tpl` |
| **Stakater Reloader is not installed anywhere** (only annotations exist) | repo-wide `rg stakater`; bug `cnpg-playground-eff0` |
| kind node image has **no `/var/log/journal`**; journald `Storage=auto` → volatile `/run/log/journal` | inspected `kindest/node` image locally |
| Infra nodes: 2 tainted workers (`node-role.kubernetes.io/infra:NoSchedule`) | `k8s/kind-cluster.yaml.tpl` |

### 2.1 Live-cluster check (rev 3, `kind-k8s-local`, 2026-09-18)

Checked against a running `setup.sh local` + `monitoring/setup.sh` cluster (no tenant; `demo-local-db` present). All rows above hold. Additional facts found live:

| # | Live fact | Evidence | Consequence |
|---|---|---|---|
| L1 | **otel-collector writes logs into Loki-C**: pipeline `logs: otlp → otlphttp/logs → http://loki.grafana.svc.cluster.local:3100/otlp`. Producers: traefik-edge (OTLP gRPC mTLS via `otel/ext-svc-lb` 172.28.255.240:4317), in-cluster Traefik. | ConfigMap `otel/otel-collector-opentelemetry-collector`; Loki streams `service_name=traefik-edge`, `opentelemetry-collector` | Second writer only Loki-C sees → breaks identical input. Fixed by §4.7. |
| L2 | **`loki-canary` DaemonSet runs** (4 pods) and pushes into Loki-C (`service_name=unknown_service`, ≈9% of bytes over 30 min) | `kubectl -n grafana get ds`; `helm get values loki -a` → `lokiCanary: true` | Chart 13.x reads **top-level** `lokiCanary.enabled`; our `monitoring.lokiCanary.enabled: false` is dead config. Set `lokiCanary.enabled: false` in all three values files. |
| L3 | Current Alloy = **1-replica Deployment**, `loki.source.kubernetes` (tails through the kube API, no hostPath) | `deploy/alloy`, ConfigMap `alloy` | k8s-monitoring `alloy-logs` is a DaemonSet reading `/var/log/pods` + journal — a collection-mechanism change, not just a chart swap. |
| L4 | Real ingest ≈ 7 MB / 30 min (~4 KB/s); top: etcd, loki, grafana-operator, canary, calico-node | Loki `bytes_over_time` by `service_name` | Confirms `flog` load is required. |
| L5 | Journald only in `/run/log/journal` (8 MB); `/var/log/journal` absent on nodes | `docker exec k8s-local-worker ls` | Confirms `nodeLogs.journal.path` override. |
| L6 | S3 secret **plaintext in ConfigMap `loki`** (`secret_access_key: lokiS3secret`) from `--set` | `kubectl -n grafana get cm loki` | New Lokis must not copy this: Secret + `extraEnvFrom` + `-config.expand-env=true` + `${S3_SECRET_KEY}` in values. Apply to Loki-C too. |
| L7 | StorageClass `standard` = local-path, `allowVolumeExpansion: false` | `kubectl get sc` | Size Loki PVCs and the SeaweedFS volume PVC up front; no resize later. |
| L8 | `step-ca-external-bundle` + `vault-pki-bundle` present in `grafana`; ServiceMonitor CRD present; no Seaweed / Reloader CRDs | `kubectl get cm,crd` | Matches §4 assumptions. |
| L9 | Container / LB IPs unchanged: RustFS 172.28.0.11, SeaweedFS .12, traefik 172.28.255.200 | `docker network inspect kind`, LB Services | — |

---

## 3. Topology

```
     k8s-monitoring (alloy-logs DaemonSet)          otel-collector (otel ns, kept)
     nodeLogs + podLogsViaLoki, WAL per dest        OTLP logs from traefik-edge + Traefik
                       └──────────────┬─────────────┘  (3 otlphttp exporters, §4.7)
                 ┌───────────────────┼─────────────────────┐
                 ▼                   ▼                     ▼
        Loki-A  loki-rustfs   Loki-B  loki-seaweedfs   Loki-C  loki (existing)
                 │ https             │ https               │ https
                 │                   ▼                     │
                 │        seaweedfs-ab (Seaweed CR, grafana ns)
                 │        s3 gw ─► filer ─► volume          │
                 │                   │ filer.backup sidecar │
                 │                   │ (mirror, deletes on) │
  ───────────── cluster boundary ────┼──────────────────────┼─────────
                 ▼                   ▼                      ▼
        RustFS objectstore-local                   host SeaweedFS `seaweedfs`
        bucket loki-direct  bucket loki-mirror     bucket loki
```

| Arm | Release (ns `grafana`) | Store | Location | Datasource uid | Role |
|---|---|---|---|---|---|
| A | `loki-rustfs` (new) | RustFS `loki-direct` | outside | `loki-rustfs` | RustFS-direct |
| B | `loki-seaweedfs` (new) | in-cluster SeaweedFS `loki`, mirrored to RustFS `loki-mirror` | inside | `loki-seaweedfs` | candidate |
| C | `loki` (existing, unchanged name) | host SeaweedFS `loki` | outside | `loki` | **control**: same software as B, same location as A |

Reading the results: **B vs C** isolates *location* (same software). **A vs C** isolates *software* (same location). A vs B is the combined comparison as originally asked.

---

## 4. Components

### 4.1 Platform additions (`scripts/setup.sh`, hub only)

| Component | Version | Notes | Bead |
|---|---|---|---|
| seaweedfs-operator | chart **0.1.42** / app **1.0.39** (`https://seaweedfs.github.io/seaweedfs-operator/`) | CRD `seaweeds.seaweed.seaweedfs.com` is templated (chart ≥0.1.15, upgrades update it). Infra nodes. | `t9p7.1` |
| stakater Reloader | pin at implementation | Also repairs demo-app's Vault-rotation restarts. | `eff0` |

### 4.2 In-cluster SeaweedFS (`monitoring/setup.sh`) — bead `8ti`

Seaweed CR **`seaweedfs-ab`** in `grafana`. The name avoids confusion with the existing bridge Service `seaweedfs` and the host container's cert SAN `seaweedfs.grafana.svc.cluster.local`.

```yaml
apiVersion: seaweed.seaweedfs.com/v1
kind: Seaweed
metadata: { name: seaweedfs-ab, namespace: grafana }
spec:
  image: chrislusf/seaweedfs:4.47          # pin; sidecar uses the same tag
  master: { replicas: 1, nodeSelector: *infra, tolerations: *infra }
  volume: { replicas: 1, requests: { storage: 20Gi }, storageClassName: standard, nodeSelector: *infra, tolerations: *infra }
  filer:
    replicas: 1
    s3: { enabled: false }                  # use the standalone gateway below
    nodeSelector: *infra
    tolerations: *infra
    annotations: { reloader.stakater.com/auto: "true" }
    sidecars:
      - name: filer-backup-rustfs
        image: chrislusf/seaweedfs:4.47
        args: [filer.backup, -filer=localhost:8888, -filerPath=/buckets/loki,
               -doDeleteFiles=true, -initialSnapshot]
        env: [{ name: AWS_CA_BUNDLE, value: /etc/ssl/step-ca/ca-certificates.crt }]
        volumeMounts: [replication-toml → /etc/seaweedfs/replication.toml, step-ca-external-bundle → /etc/ssl/step-ca]
  s3:
    replicas: 1
    configSecret: { name: seaweedfs-ab-s3-identities, key: identities.json }
    extraArgs: [-port.https=8333, -cert.file=/etc/tls/tls.crt, -key.file=/etc/tls/tls.key]   # verify flag names + HTTP port relocation
    volumes/volumeMounts: Certificate secret from ClusterIssuer vault-pki (SANs: operator s3 Service name(s))
    nodeSelector: *infra
    tolerations: *infra
```

Schematic; field names verified against `api/v1/seaweed_types.go` (master, 2026-09-18): `ComponentSpec` has `sidecars`, `initContainers`, `extraArgs`, `env`, `volumes`, `volumeMounts`, `nodeSelector`, `tolerations`, `annotations`. `SeaweedSpec.s3` is the standalone gateway (preferred over deprecated `filer.s3`). `spec.tls` is **gRPC mTLS only**. Client-facing S3 HTTPS has no first-class field, hence `extraArgs` plus a mounted cert.

S3 identities (`seaweedfs-ab-s3-identities`): `loki` → `Read/Write/List/Tagging:loki`; `admin` → bootstrap only (bucket create Job), never handed to a workload. This mirrors the host container's least-privilege model.

**Mirror mechanism: `weed filer.backup` (not `filer.remote.gateway`).**

| Property | Value | Source |
|---|---|---|
| Sink config | `replication.toml` `[sink.s3]` from a Secret: `enabled=true`, `is_incremental=false`, `endpoint=https://objectstore-local:9000`, `bucket=loki-mirror`, `directory=/`, `s3_force_path_style=true`, keys of RustFS user `loki-mirror` | `weed/command/scaffold/replication.toml`, `weed/replication/sink/s3sink/s3_sink.go:64-110` |
| Key layout | identical to source (so Loki can read the mirror) only with `is_incremental=false`; `true` prefixes `YYYY-MM-DD/` | `weed/command/filer_sync.go:788-792` |
| Deletes | only with **`-doDeleteFiles=true`** (default **false**), and never when `is_incremental=true` | `weed/command/filer_backup.go:61`, `filer_sync.go:640-647` |
| Resume | checkpoint keyed by `endpoint\0bucket\0dir` | `s3_sink.go:57` |
| Seed | `-initialSnapshot` walks the tree once. Remove it after catch-up, or every restart re-walks the whole tree. | `filer_backup.go:67` |
| TLS to RustFS | no CA option in `replication.toml`. The sink uses aws-sdk-go v1 `session.NewSession`, which should honour `AWS_CA_BUNDLE`. **Verify first**; fallback is adding the step-ca root to the image trust store via an initContainer. | `s3_sink.go:115-131` |

Why not the gateway, even with one sink:
- remote config is imperative (`weed shell remote.configure`, stored in filer `/etc/remote`)
- `-createBucketWithRandomSuffix` defaults `true`
- only buckets created after the gateway starts are picked up automatically

`filer.backup` is declarative and restartable.

### 4.3 RustFS (outside) — bead `dfe`

- Bridge Service/Endpoints `objectstore-local` in `grafana` (copy of `monitoring/mimir/objectstore-bridge.yaml.tpl`). Clients use the **short name** `objectstore-local`, because the cert SANs do not cover `objectstore-local.grafana.svc.cluster.local`.
- Buckets: `loki-direct` (Loki-A), `loki-mirror` (Loki-B's mirror). Same RustFS container for both (user decision). Loki-A's numbers therefore include mirror contention; §5 records mirror throughput as a covariate.
- IAM users `loki-direct` and `loki-mirror`, each `Read/Write/List` on its own bucket only (`mc admin user add` + policy). No root `cnpg` creds in any Loki or SeaweedFS pod.

### 4.4 Lokis — bead `dfe`

Per-arm values files; `loki-values.yaml` stays Loki-C's file.

| Key | Loki-A `loki-values-rustfs.yaml` | Loki-B `loki-values-seaweedfs.yaml` | Loki-C `loki-values.yaml` |
|---|---|---|---|
| `storage.s3.endpoint` | `https://objectstore-local:9000` | `https://<seaweedfs-ab s3 Service>.grafana.svc.cluster.local:8333` | `https://seaweedfs.grafana.svc.cluster.local:8333` (unchanged) |
| bucket (chunks/ruler/admin) | `loki-direct` | `loki` | `loki` |
| `http_config.ca_file` volume | `step-ca-external-bundle` | `vault-pki-bundle` | `step-ca-external-bundle` |
| creds (`--set`) | RustFS `loki-direct` | in-cluster `loki` identity | `SEAWEEDFS_ACCESS_KEY/SECRET_KEY` |

Common deltas applied to **all three** so the arms differ only in storage:
- `compactor.retention_enabled: true`, `limits_config.retention_period: 24h` (minimum with 24h index period), `compactor.delete_request_store: s3`
- hedging disabled (the chart default hides tail latency and multiplies requests to the slower backend)
- `monitoring.serviceMonitor.enabled: true`
- `lokiCanary.enabled: false` (top-level key; see L2)
- S3 keys from a Secret via `singleBinary.extraEnvFrom` + `singleBinary.extraArgs: [-config.expand-env=true]`, values reference `${S3_ACCESS_KEY}`/`${S3_SECRET_KEY}` (see L6)
- `singleBinary.podAnnotations.reloader.stakater.com/auto: "true"` (cert and secret rotation; see §7)
- keep `use_thanos_objstore: false` on all three (the chart 13.5.0 render). Latency metric = `loki_s3_request_duration_seconds`; Loki `main` has flipped the default to Thanos, so re-check on chart upgrade.
- identical `limits_config`, ingester chunk settings, PVC size, infra placement

### 4.5 Alloy via k8s-monitoring — bead `t9p7.2`

Replace the `alloy` release with `grafana/k8s-monitoring` **4.5.2**. It pulls the `alloy-operator` 0.7.1 subchart (CRD + operator).

```yaml
cluster: { name: local }
destinations:
  loki:           { type: loki, url: http://loki.grafana.svc.cluster.local:3100/loki/api/v1/push }
  lokiRustfs:     { type: loki, url: http://loki-rustfs.grafana.svc.cluster.local:3100/loki/api/v1/push }
  lokiSeaweedfs:  { type: loki, url: http://loki-seaweedfs.grafana.svc.cluster.local:3100/loki/api/v1/push }
  # identical batchSize/batchWait on all three; writeAheadLog enabled on all three
nodeLogs:
  enabled: true
  collector: alloy-logs
  journal: { path: /run/log/journal, units: [kubelet.service, containerd.service] }
podLogsViaLoki:
  enabled: true
  collector: alloy-logs
  extraLogProcessingStages: |   # ported pgaudit + traefik_access stages, each under stage.match
clusterEvents: { enabled: true, collector: alloy-singleton }   # replaces loki.source.kubernetes_events
collectors:
  alloy-logs:      { presets: [filesystem-log-reader, daemonset] }   # + hostPath mount /run/log/journal
  alloy-singleton: { presets: [singleton] }
```

- Features send to **every** enabled destination of a matching type (`destinations.get` in `templates/destinations/_destination_helpers.tpl`), so the fan-out needs no per-feature wiring.
- Each destination renders its own `loki.write`. Upstream, `loki.Fanout.Send` hands each entry to each receiver in turn and blocks while a receiver is full. The chart exposes no `queue_config.block_on_overflow` for Loki destinations. The per-destination **WAL** is the intended decoupling; verify that a stopped Loki does not stall the other two.
- kind journald is volatile, hence `journal.path: /run/log/journal` plus a mount. The `filesystem-log-reader` preset is not assumed to mount `/run`.

### 4.6 Grafana — bead `t9p7.2`

`GrafanaDatasource` objects: keep uid `loki` (Loki-C: Tempo links and dashboards keep working), add `loki-rustfs` and `loki-seaweedfs`. Dashboards using a `${datasource}` variable work with all three.

### 4.7 OTel Collector — kept, logs fanned out — bead `t9p7.2`

Decision (rev 3): otel-collector **stays** the traces gateway (tail sampling → Tempo, mTLS OTLP intake from traefik-edge via `ext-svc-lb`). It is **not** superseded by Alloy in this epic. Only its logs pipeline changes, so all three Lokis receive the same OTLP logs:

```yaml
# monitoring/otel-collector/otel-collector-values.yaml (config.exporters / service.pipelines.logs)
exporters:
  otlphttp/logs:          { endpoint: http://loki.grafana.svc.cluster.local:3100/otlp,           tls: { insecure: true } }
  otlphttp/logs-rustfs:   { endpoint: http://loki-rustfs.grafana.svc.cluster.local:3100/otlp,    tls: { insecure: true } }
  otlphttp/logs-seaweedfs:{ endpoint: http://loki-seaweedfs.grafana.svc.cluster.local:3100/otlp, tls: { insecure: true } }
service:
  pipelines:
    logs: { receivers: [otlp], processors: [memory_limiter, batch], exporters: [otlphttp/logs, otlphttp/logs-rustfs, otlphttp/logs-seaweedfs] }
```

Each exporter has its own `sending_queue`, so a slow Loki does not block the others (unlike Alloy's `loki.Fanout`). Keeping Loki's native `/otlp` endpoint keeps `limits_config.otlp_config` index labels (`service.name`, `host.name`) identical to today.

**Why not replace it with Alloy now** (assessed; follow-up bead):

| Capability | otel-collector today | k8s-monitoring `applicationObservability` + `alloy-receiver` |
|---|---|---|
| OTLP gRPC/HTTP, jaeger, zipkin receivers | yes | yes |
| Tail sampling → Tempo | `tail_sampling` processor | per-destination `processors.tailSampling` on the `otlp` destination |
| OTLP logs → several Lokis | exporters per Loki (above) | automatic, every `loki` destination |
| **mTLS on the OTLP receiver** (client-CA, edge intake) | yes | **not in feature values** → raw Alloy `extraConfig` (`otelcol.receiver.otlp` `tls` block) |
| Loki `/otlp` label semantics | native | via `otelcol.exporter.loki` → `loki.write`: labels differ from `otlp_config` |
| Callers to repoint | — | `otel/ext-svc-lb` selector, Traefik `--tracing.otlp.grpc.endpoint`, demo-app `otlpEndpoint`, spoke `otel-push` IngressRoute, OTLP server cert SANs |

Replacing is feasible and yields one collector, but it touches the edge mTLS path and traces. That is out of scope for a storage benchmark. Tracked as a separate follow-up.

---

## 5. Benchmark method — bead `t9p7.3`

1. **Load:** `flog` Deployment(s) in a dedicated namespace on app nodes at a fixed lines/s, collected by `podLogsViaLoki` like any pod. Real node/pod logs alone (a few KB/s) would flush too little to measure.
2. **Duration:** ≥ 26h, so chunks flush (`chunk_idle_period` 30m, `max_chunk_age` 2h) and 24h retention + 2h `retention_delete_delay` have fired at least once.
3. **Writes:** Alloy push latency never touches S3 (ingester memory + WAL). Measure `loki_s3_request_duration_seconds{operation=~"S3.PutObject|..."}` and ingester flush metrics.
4. **Reads:** a fixed LogQL set run by script against each Loki's query API, over ranges older than `max_chunk_age` + `query_ingesters_within`, so data comes from S3 and not ingester memory. Hedging off, caches off (already), same query order per arm. The TSDB index is cached on each PVC, so report first-run and warm-run separately.
5. **Resource cost:** CPU/memory/disk of `loki-*` pods and **all** `seaweedfs-ab-*` pods including the `filer-backup-rustfs` sidecar. The RustFS and host SeaweedFS containers are outside Kubernetes: record `docker stats` for them.
6. **Covariate:** `filer.backup` upload rate/bytes during each window, because it shares `objectstore-local` with Loki-A.

**Restore drill (pass/fail gate):** after the run, deploy a throwaway Loki (same schema) pointed at RustFS `loki-mirror` with read-only creds. It must return the same line counts as `loki-seaweedfs` for the fixed query set, over ranges older than the mirror lag.

Caveat: every store shares one WSL2 VM and one disk (`/dev/sdd`). "Outside" means a Docker bridge hop + TLS, not a network. Results show relative overhead, not production latency, and say nothing about geo-redundancy.

---

## 6. Deployment order (on `./scripts/setup.sh local`)

1. `scripts/setup.sh`: + Reloader (`eff0`), + seaweedfs-operator (`t9p7.1`).
2. `monitoring/setup.sh` (hub only):
   1. RustFS bridge in `grafana`
   2. RustFS buckets + IAM users
   3. Seaweed CR + cert + identities + bucket Job + replication Secret (`8ti`)
   4. Loki-C with common deltas
   5. Loki-A and Loki-B (`dfe`)
   6. k8s-monitoring replacing `alloy`
   7. otel-collector logs exporters for A and B (§4.7). otel-collector installs **before** Loki today (`monitoring/setup.sh:154` vs `:289`), so either move the upgrade after step 5 or accept exporter retries until A/B exist.
   8. datasources (`t9p7.2`)
3. Benchmark + drill (`t9p7.3`).
4. `monitoring/teardown.sh` and `scripts/teardown.sh` get matching removals: Seaweed CR + PVCs, releases, RustFS users/buckets.
5. `docs/architecture-overview.md` update (`t9p7.4`, §8a).

---

## 7. Risks

1. **Mirror deletes are real deletes.** `-doDeleteFiles=true` makes `loki-mirror` a mirror, not a backup: an accidental delete in `/buckets/loki` propagates. Accepted for the PoC (YAGNI tombstone window, rev-1 decision stands).
2. **Cert rotation.** Loki builds its TLS root pool once at client construction. The rev-1 analysis traced the Thanos client (`pkg/storage/bucket/s3`), which this Loki does not use (`use_thanos_objstore: false`); re-verify for the legacy `aws` client. The mitigation is the same either way: Reloader restarts on CA ConfigMap change, and the `filer.backup` sidecar needs the same (filer pod annotation). Depends on `eff0`.
3. **Secret rotation** (RustFS `loki-mirror` keys, S3 identities) needs a filer or S3 pod restart; handled by Reloader annotations.
4. **`AWS_CA_BUNDLE` unverified** for the `filer.backup` S3 sink. If not honoured, the sidecar fails TLS to RustFS; fallback is the initContainer trust-store injection.
5. **Alloy coupling.** A stalled Loki could throttle the others if the WAL does not decouple as expected. Verify before benchmarking.
6. **Mirror backlog is unobserved.** `filer.backup` has no metrics. Watch sidecar logs and compare bucket object counts at the end of the run (part of the drill).
7. **Version drift.** Operator (1.0.x), `chrislusf/seaweedfs`, k8s-monitoring and the Loki chart are pinned. Re-check the `use_thanos_objstore` default and metric names on any Loki chart bump.
8. **Bootstrap dependency.** In-cluster SeaweedFS images come through zot, whose blobs live on the host SeaweedFS. The host container is **not** decommissionable: it also carries zot and Barman. Rev 1's "decommission after PoC" is withdrawn.
9. **Hidden writers.** Anything that pushes to Loki outside Alloy breaks input parity: otel-collector (fixed §4.7), `loki-canary` (disabled). Before the benchmark, compare `sum by (service_name) (bytes_over_time(...))` across all three Lokis; they must match within ±1%.
10. **Collection-mechanism change.** API-tailing Deployment → file-reading DaemonSet (L3) may change line counts, timestamps and labels (`service_name` derivation). Pgaudit/Traefik/events dashboards must be re-checked after `t9p7.2`, not only the new datasources.

---

## 8. Decision log

| # | Decision | Date |
|---|---|---|
| 1 | Single DR sink: RustFS. External SeaweedFS sink dropped. | 2026-09-18 |
| 2 | Three Lokis: A RustFS-direct, B in-cluster SeaweedFS + mirror, C existing host-SeaweedFS `loki` as control | 2026-09-18 |
| 3 | Mirror via `weed filer.backup` (`is_incremental=false`, `-doDeleteFiles=true`), not `filer.remote.gateway` | 2026-09-18 |
| 4 | Mirror bucket `loki-mirror` on the same RustFS as Loki-A (contention accepted, recorded as covariate) | 2026-09-18 |
| 5 | Replace custom Alloy with k8s-monitoring (`nodeLogs` + `podLogsViaLoki`); port pgaudit/traefik/events | 2026-09-18 |
| 6 | HTTPS on every Loki→S3 hop (in-cluster via `vault-pki` cert + `extraArgs`) | 2026-09-18 |
| 7 | Load: `flog` pods | 2026-09-18 |
| 8 | Keep release/uid `loki` as Loki-C; new `loki-rustfs`, `loki-seaweedfs` | 2026-09-18 |
| 9 | seaweedfs-operator in `scripts/setup.sh`; everything else in `monitoring/setup.sh` | 2026-09-18 |
| 10 | Install Reloader in `scripts/setup.sh` | 2026-09-18 |
| 11 | Retention on, 24h, all three Lokis | 2026-09-18 |
| 12 | Per-purpose RustFS IAM users (`loki-direct`, `loki-mirror`) | 2026-09-18 |
| 13 | Everything in namespace `grafana` | 2026-09-18 |
| 14 | Verdict = old-range query latency + S3 op latency p50/p99 + resource cost; restore drill = pass/fail gate | 2026-09-18 |
| 15 | Spoke regions out of scope (hub only) | 2026-09-17 (kept) |
| 16 | Tombstone window YAGNI | 2026-09-17 (kept) |
| 17 | otel-collector kept (traces + edge mTLS gateway); its logs pipeline fans out to all three Lokis. Alloy replacement = separate follow-up. | 2026-09-18 (rev 3) |
| 18 | `loki-canary` disabled on all three Lokis (top-level `lokiCanary.enabled: false`) | 2026-09-18 (rev 3) |
| 19 | S3 keys via Secret + `-config.expand-env`, not `--set` (all three Lokis) | 2026-09-18 (rev 3) |

---

## 8a. Plan: update `docs/architecture-overview.md` — bead `t9p7.4`

Update **after** `t9p7.2` lands (the doc describes live state). Section-by-section:

| § | Current text | Change |
|---|---|---|
| 2 diagram | `Alloy "Log Collector"`, one `Loki`, `Seaweed -->|S3 storage| Loki`, `OTel -->|traces| Tempo` only | Alloy → "Alloy (k8s-monitoring)"; three Loki nodes (`loki`, `loki-rustfs`, `loki-seaweedfs`); in-cluster `SeaweedFS (operator)` node in ObsLayer; edges: host SeaweedFS→`loki`, RustFS→`loki-rustfs`, in-cluster SW→`loki-seaweedfs`, in-cluster SW `-.filer.backup mirror.->` RustFS; add missing `OTel -->|logs| Loki` (already true today) |
| 2.1 wiring table | `mimir,tempo/objectstore-local` | add `grafana/objectstore-local` (RustFS bridge for Loki-A + mirror) |
| 3.1 flowchart + outcomes | no seaweedfs-operator / Reloader | add both under Phase 4 (hub-only platform) |
| 3.3 flowchart | `M3 Loki (single-binary) → SeaweedFS`, `M5 Alloy`, `M6 OTel` | three Loki boxes with their stores; `M5` = k8s-monitoring (`nodeLogs`, `podLogsViaLoki`, `clusterEvents`); OTel → 3 Lokis (logs) + Tempo (traces) |
| 3.3 outcomes | "All long-term storage backed by RustFS S3" (**already wrong**: Loki is on SeaweedFS); "5 datasources … 12 dashboards" | per-signal storage list; datasource list incl. `loki-rustfs`, `loki-seaweedfs` (live today: 9 GrafanaDatasource CRs incl. `*-rbr-ver`, 19 dashboards) |
| 5.3 observability flow | `AppL --> Alloy`, `Loki --> Seaweed` | node journal + pod logs → Alloy DaemonSet; OTel logs → Lokis; three Loki → store edges + mirror edge |
| 6 namespaces | `grafana` = "Grafana Operator, platform Grafana, tenant Grafana, Loki, Alloy" | add Loki-A/B, SeaweedFS CR pods, alloy-operator; new `seaweedfs-operator` namespace (name set in `t9p7.1`); `reloader` namespace if separate |
| 7 Helm releases | `alloy 1.8.0`, `loki` only, 26 releases | replace `alloy` with `k8s-monitoring 4.5.2` (+ `alloy-operator` subchart); add `loki-rustfs`, `loki-seaweedfs`, `seaweedfs-operator 0.1.42`, `reloader`; recount |
| 7 dashboards | 16 listed | 19 live (adds `*-rbr-ver` variants); add the storage A/B/C benchmark dashboard from `t9p7.3` |
| 7 containers | RustFS purpose "Mimir, Tempo" | "Mimir, Tempo, Loki-A (`loki-direct`), Loki-B mirror (`loki-mirror`)" |
| new note | — | link this design doc; state the benchmark caveat (single WSL disk) |

Tenant Grafana (`demo/yaml/self-service/grafana/`, datasource `loki-rbr-ver` → `http://loki.grafana.svc…`) keeps pointing at Loki-C; no tenant change.

---

## 9. Rev-1 claims withdrawn (errata)

| Rev-1 claim | Reality | Evidence |
|---|---|---|
| Two `filer.remote.gateway` sidecars fan one bucket out to two sinks | One bucket maps to **one** remote; both gateways share the filer-stored mapping and would upload to the same remote | `weed/command/filer_remote_gateway_buckets.go` (`mappings.Mappings[bucketPath]`, `findRemoteStorageClient`) |
| Remotes `cloud1`/`cloud2` and `[remote.mount]` live in `filer.configSecret` TOML | Configured via `weed shell remote.configure`, stored in filer `/etc/remote`; `filer.configSecret` is `filer.toml` | same file (`collectRemoteStorageConf`), operator `FilerSpec.ConfigSecret` |
| Pre-create `loki` on the sinks with `mc mb` | Gateway creates `<bucket>-<random>` by default (`-createBucketWithRandomSuffix=true`) | `weed/command/filer_remote_gateway.go:59` |
| "seaweedfs-operator 0.1.42, operator is 0.1.x" | 0.1.42 is the **chart**; operator app is **1.0.39** | GitHub releases 2026-09-14 |
| `spec.s3` S3 endpoint keeps the TLS hop with existing `ca_file` | S3 gateway has only an HTTP `port`; `spec.tls` = gRPC mTLS | `api/v1/seaweed_types.go` (`S3GatewaySpec`, `TLSSpec`) |
| Loki #2 at `http://objectstore-local:9000` | RustFS is HTTPS-only, and `objectstore-local` only resolves in `mimir`/`tempo` today | `scripts/setup.sh:381-392`, bridge templates |
| "Reloader already deployed" | Not installed anywhere | bug `eff0` |
| Cert-reload trace via `pkg/storage/bucket/s3` (Thanos) | Current config renders `use_thanos_objstore: false` (legacy client) | `helm template` chart 13.5.0 |
| Rename Loki to `loki-primary` | Would break Alloy URL, Tempo `datasourceUid: loki`, dashboards; orphan PVC | `alloy-config.river:58`, `grafana_datasource_tempo.yaml` |
| New Argo CD app `manifests/argocd/apps/seaweedfs.yaml` | Root app is only applied by `demo/self-service-setup.sh`; `rbr` AppProject whitelist lacks `Secret`, `Seaweed`, CRDs | `manifests/argocd/root-app.yaml` |
| Decommission host SeaweedFS after PoC | It also hosts zot blobs (containerd mirror) and Barman backups | `scripts/setup.sh:462-519` |
| Spoke Lokis cannot reach hub SeaweedFS | Host container is on the shared `kind` network, reachable from every cluster; true only for an in-cluster store | `scripts/setup.sh:320-324` |
| "Validate retention delete propagates" | Impossible with `retention_enabled` unset; now enabled (decision 11) | `loki-values.yaml` |

---

## 10. Sources

- SeaweedFS (master, 2026-09-18): `weed/command/filer_remote_gateway.go`, `filer_remote_gateway_buckets.go`, `filer_backup.go`, `filer_sync.go`, `weed/replication/sink/s3sink/s3_sink.go`, `weed/command/scaffold/replication.toml`; release 4.47 (2026-09-14)
- seaweedfs-operator (master): `api/v1/seaweed_types.go`, README; release 1.0.39 / chart 0.1.42 (2026-09-14)
- Grafana k8s-monitoring-helm 4.5.2: `charts/k8s-monitoring/templates/destinations/_destination_loki.tpl`, `_destination_helpers.tpl`, `charts/feature-node-logs/values.yaml`, `Chart.yaml` (alloy-operator 0.7.1); feature docs via Context7 `/grafana/k8s-monitoring-helm`
- Grafana Alloy: `internal/component/common/loki/fanout.go`, `docs/design/4940-reliable-loki-pipelines.md`, `loki.write` reference (Context7 `/grafana/alloy`)
- Grafana Loki: storage + Thanos migration docs, meta-monitoring metrics, ingester config (Context7 `/grafana/loki`); chart `grafana-community/loki` 13.5.0 (appVersion 3.7.1)
- Repo: `scripts/setup.sh`, `scripts/common.sh`, `scripts/funcs_regions.sh`, `monitoring/setup.sh`, `monitoring/loki/loki-values.yaml`, `monitoring/alloy/alloy-config.river`, `monitoring/mimir/objectstore-bridge.yaml.tpl`, `k8s/kind-cluster.yaml.tpl`, `manifests/argocd/root-app.yaml`, `step-ca/trust-manager/bundle-external.yaml`, `vault/trust-manager/bundle.yaml.tpl`
