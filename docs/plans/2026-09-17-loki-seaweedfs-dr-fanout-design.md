# Loki S3 Storage via in-cluster SeaweedFS with DR Fan-out to External SeaweedFS + RustFS

**Date:** 2026-09-17
**Status:** Design — pending decision on operator deployment + topology contradiction flagged below
**Owner:** monitoring stack
**Scope:** `monitoring/` (Loki + SeaweedFS fan-out). Mimir/Tempo untouched.

---

## 1. Goal

Replace the current Loki → SeaweedFS direct dependency with an architecture where:

- An **in-cluster SeaweedFS cluster** is the source of truth for Loki chunks/rules/admin.
- A **one-way fan-out** mirrors the bucket set to two DR sinks:
  - An **external SeaweedFS cluster** (off-cluster, geo-redundant copy).
  - The existing **RustFS cluster** (off-cluster, separate S3-compatible storage).
- Loki remains the only reader of these buckets.
- Driver is **disaster recovery**, not multi-region read locality or cost tiering.

---

## 2. Context (verified by recon, 2026-09-17)

### 2.1 Current state (as committed)

- Loki: SingleBinary, schema v13, store `tsdb` + `object_store: s3`, retention `3d` via `limits_config`. Buckets `loki/chunks`, `loki/ruler`, `loki/admin` (all named `loki`).
- File: `monitoring/loki/loki-values.yaml` lines 8–20:
  ```yaml
  storage:
    type: s3
    bucketNames: { chunks: loki, ruler: loki, admin: loki }
    s3:
      endpoint: https://seaweedfs.grafana.svc.cluster.local:8333
      region: us-east-1
      s3ForcePathStyle: true
      insecure: false
      http_config: { ca_file: /etc/ssl/step-ca/ca-certificates.crt }
  ```
- S3 creds: static `--set` from `SEAWEEDFS_ACCESS_KEY=loki` and `SEAWEEDFS_SECRET_KEY` (env, in `monitoring/setup.sh` and `common.sh:96–97`). No ESO/IRSA wired for Loki today.
- **SeaweedFS is currently a host Docker container** (`seaweedfs`, `weed server -dir=/data -filer -s3`, ports 8333/8334/8889/9333/9340) bridged into the cluster via `kind network connect` + headless `Service`+`Endpoints` created imperatively in `monitoring/setup.sh:248–271`.
- **RustFS is currently a host Docker container** (`objectstore-<region>` on port 9001), bridged into the cluster at `objectstore-<region>:9000` for Mimir/Tempo. Loki does **not** touch RustFS today.
- `minio.enabled: false` in the Loki chart. `mc` is used only as a throwaway client for bucket creation.

### 2.2 Topology decision (resolved 2026-09-17)

The user described the system as "in-cluster seaweedfs (managed by seaweedfs-operator) + external seaweedfs + external rustfs". **Recon showed that as a future-state target, not current reality.** SeaweedFS is currently a host Docker container; no `Seaweed` CR, no operator deployment. Same for RustFS.

**Decision (recorded 2026-09-17):** The operator-managed in-cluster SeaweedFS **coexists** with the host Docker SeaweedFS container for the duration of the PoC. The host container remains the rollback target if the operator path misbehaves. After the PoC validates, the host container can be decommissioned in a separate change.

**Second Loki:** User confirmed a second Loki (Loki #2) writing directly to RustFS is **planned, not yet committed**. It is part of the PoC scope (deployed side-by-side with Loki #1) so the two paths can be compared under identical load.

### 2.3 Doc drift to fix in the same change set

- `monitoring/codemap.md:4,8,9,14,23` and root `codemap.md:174,251` claim Loki → RustFS `objectstore-local:9000`. **Stale.** Reality is SeaweedFS `:8333` TLS.
- Root `codemap.md` external-services table omits SeaweedFS entirely.
- Graphify community labels reflect the stale Loki→RustFS association; graph was rebuilt 2026-09-17 but labels are pending LLM re-label.

---

## 3. Decision

### 3.1 Sync mechanism: **Gateway-to-Remote** (`weed filer.remote.gateway`)

| | Gateway-to-Remote | Filer Active-Active (`filer.sync`) |
|---|---|---|
| Can reach RustFS | ✅ yes | ❌ SeaweedFS-only |
| One-way fan-out | ✅ native | ⚠️ needs `-isActivePassive` |
| Bidirectional active-active | ❌ no | ✅ yes (signature dedup) |
| Deletion propagation | ✅ yes (DR = mirror, not backup) | ✅ yes |
| Sink type | any S3-compatible | SeaweedFS-native only |
| Loop / split-brain risk | none (one-way) | real; renames break in loops |
| Operational complexity | low: 1 daemon/sink, pause-resume safe | medium: per-direction sync, dual channels (gRPC 18888 + HTTP 8888), per-side TLS |
| Observability | logs only | `-a.debug`/`-b.debug` logs only |

Gateway wins because the sink is **plain S3** — one in-cluster SeaweedFS fans out to both DR sinks (external SeaweedFS + RustFS) with identical mechanics. `filer.sync` cannot target RustFS at all.

Sources:
- https://github.com/seaweedfs/seaweedfs/wiki/Gateway-to-Remote-Object-Storage (revised 2024–2026)
- https://github.com/seaweedfs/seaweedfs/wiki/Filer-Active-Active-cross-cluster-continuous-synchronization (revised 2026-09-02)

### 3.2 Deployment: operator-managed in-cluster SeaweedFS

`seaweedfs-operator 0.1.42` (latest, 2026-09-14). CRDs `seaweeds.seaweed.seaweedfs.com/v1` kind `Seaweed`. Neither sync mechanism has a first-class CRD field — both go through `spec.filer.sidecars` (arbitrary `v1.Container`) + `spec.filer.configSecret` for filer TOML.

Sample CR skeleton (subject to operator API validation):
```yaml
apiVersion: seaweed.seaweedfs.com/v1
kind: Seaweed
metadata: { name: seaweedfs, namespace: grafana }
spec:
  image: chrislusf/seaweedfs:latest   # required for filer.remote.gateway / filer.sync
  master: { replicas: 1 }              # bump to 3 once quorum is desired
  volume: { replicas: 1, requests: { storage: 100Gi } }   # bump per data growth
  filer:
    replicas: 1
    configSecret: seaweedfs-filer-config     # contains [s3] remotes cloud1/cloud2 + [remote.mount] entries
    sidecars:
      - name: filer-remote-gateway-cloud1
        image: chrislusf/seaweedfs:latest
        command: [weed, filer.remote.gateway, -createBucketAt=cloud1]
      - name: filer-remote-gateway-cloud2
        image: chrislusf/seaweedfs:latest
        command: [weed, filer.remote.gateway, -createBucketAt=cloud2]
  s3:
    replicas: 1   # Loki S3 endpoint target
```

### 3.3 Maturity call

- Gateway-to-Remote: documented, actively-maintained production feature.
- Operator path: **not GA-first-class.** Works via generic `sidecars` + `configSecret`. Operator itself is 0.1.x and actively developed — no version guarantee for the CRD surface.

---

## 4. Data flow

### 4.1 Write path (Loki → SeaweedFS)
```
loki (SingleBinary) ── S3 ──► seaweedfs-s3 (in-cluster, port 8333)
                                  │
                                  ▼
                            filer (in-cluster)
                                  │
              ┌───────────────────┴───────────────────┐
              ▼                                       ▼
   local volume servers (in-cluster)         filer.remote.gateway sidecar(s)
              │                                       │
              ▼                                       ▼
        chunks/rules/admin                  cloud1 → external SeaweedFS S3
        (canonical SOT)                     cloud2 → RustFS S3
```

Loki writes go to in-cluster SeaweedFS only; the gateway sidecars handle fan-out asynchronously. Loki's `insecure: false` + `ca_file` stays for the in-cluster TLS hop.

### 4.2 Read path
Loki compactor + queriers read their own chunks from in-cluster SeaweedFS. **No DR sink is read from Loki's perspective.** This simplifies the design: no read-coherence requirement between replicas; eventual mirror lag is invisible to queries.

### 4.3 Deletion flow
Local retention-driven deletes (Loki `limits_config.retention_period: 3d` → compactor → S3 `DELETE`) propagate to both DR sinks via the gateway. **There is no tombstone/recovery window** — local deletion is mirrored deletion. DR = mirror, not backup. See §7 risk 1.

---

## 5. Loki reconfiguration

The "direct to SeaweedFS" case is current reality. The "direct to RustFS" alternative is shown for comparison and for PoC A/B testing.

### 5.1 Delta table (hard-coupled to `monitoring/loki/loki-values.yaml`)

| YAML key | Current (SeaweedFS) | Direct-RustFS | Change? |
|---|---|---|---|
| `s3.endpoint` | `https://seaweedfs.grafana.svc.cluster.local:8333` | `http://objectstore-local:9000` | **CHANGE** |
| `s3.insecure` | `false` | `true` (or `http_config.insecure_skip_verify: true` if RustFS bridge serves self-signed TLS) | **CHANGE** |
| `s3.http_config.ca_file` | `/etc/ssl/step-ca/ca-certificates.crt` | remove (or keep with `insecure_skip_verify`) | **CHANGE** |
| `s3.accessKeyId` source | `SEAWEEDFS_ACCESS_KEY` (env, `common.sh`) | `RUSTFS_ROOT_USER` (env) | **CHANGE** |
| `s3.secretAccessKey` source | `SEAWEEDFS_SECRET_KEY` | `RUSTFS_ROOT_PASSWORD` | **CHANGE** |
| `s3.region` | `us-east-1` | `us-east-1` | stays |
| `s3.s3ForcePathStyle` | `true` | `true` | stays |
| `bucketNames.chunks/ruler/admin` | `loki`/`loki`/`loki` | `loki`/`loki`/`loki` (create bucket in RustFS first) | stays |
| `schemaConfig` (tsdb, v13, `loki_index_`, 24h) | — | — | stays |
| `limits_config.retention_period` | `3d` | `3d` | stays |
| `singleBinary.extraVolumes/extraVolumeMounts` (step-ca) | mounted | removable if bridge is plain HTTP | **CHANGE** |

**Caveat — RustFS bridge TLS:** `monitoring/setup.sh` aliases RustFS via `mc --insecure alias set store https://objectstore-local:9000` — the bridge is exercised over **HTTPS with TLS-skip-verify**. The `insecure: true`/plain-HTTP form in the table applies only if the bridge is in fact plain HTTP. If the bridge serves self-signed TLS, keep a CA path or add `http_config.insecure_skip_verify: true`.

### 5.2 S3 backend parity (RustFS)

Confirmed MinIO-grade for Loki operations (Context7 `/rustfs/rustfs`, `docs/architecture/s3-compatibility-matrix.md`, main branch):
- Bucket create/delete/list/head ✅
- Object PUT/GET/DELETE/COPY/HEAD ✅
- ListObjects / ListObjectsV2 ✅
- Multipart create/upload/complete/abort ✅
- Range and conditional reads ✅
- SSE-C / SSE-KMS for own objects ✅; **MinIO/SeaweedFS-encrypted objects not readable** by default
- Conditional writes: "Selected… conditional write behavior" — partial, not relied on by Loki

Real-world wiring evidence:
- `agalue/LGTM-PoC` `values-loki.yaml`: `endpoint: rustfs-svc.storage.svc:9000`, `s3ForcePathStyle: true`, `insecure: true`.
- `rustfs/rustfs` ships `.docker/observability/loki.yaml` itself.
- `safebucket/safebucket` `deployments/local/full/config/loki.yaml`: `endpoint: bucket:9000`, `bucketnames: loki-data`, `access_key_id: rustfsadmin`.

### 5.3 Compactor / S3 gotchas (apply to both backends, no config delta)

- Compactor is colocated (SingleBinary); `working_directory` lives on the existing 20Gi PVC — unchanged.
- Multipart: AWS SDK v2 transparently switches above threshold; both SeaweedFS S3 and RustFS support multipart. No change.
- SSE-KMS: keep unset. Enabling SSE-KMS on either store breaks DR object parity — `filer.sync` would copy ciphertext as-is, RustFS cannot decrypt MinIO/SeaweedFS-encrypted objects in default builds.
- Atomic rename: Loki never renames keys. Compactor PUTs new index/chunk keys, then DELETEs superseded ones. Gotcha is list-consistency, not rename.

### 5.4 What's NOT changing
- Schema, retention, replication factor, auth mode.
- Bucket names (`loki` for chunks/ruler/admin).
- Loki→external-SeaweedFS hop (zero change required at Loki level if we keep the bridge model).

---

## 6. Component inventory (PoC: two Lokis side-by-side)

### 6.1 DR path: Loki #1 → in-cluster SeaweedFS + fan-out

| Component | Where | Purpose |
|---|---|---|
| `Seaweed` CR (`grafana` ns) | `manifests/argocd/apps/seaweedfs.yaml` (new) | Operator-managed in-cluster SeaweedFS |
| `Secret seaweedfs-filer-config` (`grafana` ns) | same | filer TOML with `[s3] cloud1` + `cloud2` + `[remote.mount]` |
| `Secret seaweedfs-filer-credentials` (`grafana` ns) | same | external-SeaweedFS + RustFS access keys |
| `filer.sidecars[]` × 2 | inside the CR | one `weed filer.remote.gateway` per sink |
| `Service seaweedfs-s3` (`grafana` ns) | same | stable in-cluster endpoint for Loki #1 |
| ExternalSeaweedFS bucket `loki` | external cluster | DR mirror (created lazily by gateway) |
| RustFS bucket `loki` (mirror target) | external cluster | DR mirror; create pre-PoC via `mc mb` |
| Loki #1 Helm release (`loki-primary`, `grafana` ns) | `monitoring/setup.sh` | writes to in-cluster SeaweedFS at `https://seaweedfs-s3.grafana.svc.cluster.local:8333` |
| Host Docker SeaweedFS | `scripts/setup.sh` | **coexists** during PoC; rollback target |

### 6.2 Direct path: Loki #2 → RustFS

| Component | Where | Purpose |
|---|---|---|
| Loki #2 Helm release (`loki-rustfs`, `monitoring-l2` ns) | `monitoring/setup.sh` new step | writes to RustFS at `http://objectstore-local:9000` |
| `loki-values-rustfs.yaml` | `monitoring/loki/` | Loki #2-only values file (separate from `loki-values.yaml`) |
| RustFS bucket `loki` (primary) | external cluster | Loki #2's primary store; pre-PoC via `mc mb` |

### 6.3 Load generator

| Component | Where | Purpose |
|---|---|---|
| Alloy config (`monitoring/alloy/alloy-config.river`) | modified | parallel `loki.write` blocks: one to `loki-primary` `:3100`, one to `loki-rustfs` `:3100` |
| Synthetic log source | new | produces identical log lines to both Lokis so the A/B comparison is fair |

---

## 7. Open risks

> **Status legend** — D = decided, R = research pending, X = deferred, A = accepted (no action needed).

1. **D · Deletion cascades to both DR sinks.** Local retention deletes and accidental local deletes mirror to both sinks — DR is a mirror, not a backup.
   - **Decision (2026-09-17): YAGNI for now.**
   - **Recorded suggestion (not for implementation this PoC):** introduce a tombstone window by routing gateway deletes through a delayed-delete queue (e.g., a small `weed filer.remote.gateway` mirror flag or a sidecar that holds DELETEs for N hours before forwarding to DR sinks). Net effect: a N-hour recovery window for accidental deletes, at the cost of doubled delete-state and a soft-consistency window. Acceptable RPO/RTO cost: bounded by N. Implement only if a real deletion incident motivates it.
2. **D · Cert rotation.** step-ca bundle rotate → Loki reads `ca_file` at client init; failure mode is mid-chain `x509 unknown CA`.
   - **Finding (lib-3, 2026-09-17): Loki's S3 client reads `ca_file` exactly once at bucket-client construction.** Code path: Loki `pkg/storage/bucket/s3/bucket_client.go:72` → `thanos-io/objstore` `exthttp.TLSConfig` → `readCAFile` = `os.ReadFile`, then `tls.Config.RootCAs` is built once and frozen for the process lifetime. minio-go wraps the injected transport; no per-request re-read. The ConfigMap volume *does* get rewritten in place by kubelet (~1 min sync), but the running process ignores the new bytes.
   - **Helm side:** the chart's `checksum/config` annotation only hashes the Loki config ConfigMap, not `step-ca-external-bundle` — so a CA rotation alone does not trigger a chart-driven restart. Verified against `production/helm/loki/templates/single-binary/statefulset.yaml`.
   - **Option matrix (pros / cons):**
     | Option | Mechanism | Restart? | Repo fit | Cost | Verdict |
     |---|---|---|---|---|---|
     | A | Stakater Reloader watches `step-ca-external-bundle`, rollout-restarts Loki + gateway sidecars + RustFS bridge on change | Yes | Reloader already deployed (demo-app pattern, `cnpg-playground-1g3`) | ~2 annotation lines | ✅ **Recommended** |
     | B | ESO ClusterSecretStore → ExternalSecret writes Secret → Reloader restarts (ESO alone cannot reload Loki's pool — no inotify consumer) | Yes | High coupling to Vault | Medium | ❌ Adds a hop with no restart savings; reduces to B+A |
     | C | Fork Loki + SeaweedFS gateway: fsnotify-watch CA file, rebuild TLS pool in place | No | Upstream divergence | High | ❌ Fork of two Go projects for one cluster |
   - **Decision (2026-09-17): Option A.** Annotate the Loki StatefulSet (`loki.podAnnotations` in `loki-values.yaml`), future gateway sidecars, and RustFS bridge with `reloader.stakater.com/auto: "true"`. Keep `step-ca-external-bundle` ConfigMap as the bundle source-of-truth. Do not move the bundle through Vault/ESO — it adds a `refreshInterval` delay with no restart savings (verified by `lib-3`).
   - **AWS SDK Go v2 note:** not used by Loki today (`minio-go + thanos exthttp`). If `aws_sdk_auth` is ever enabled, `AWS_CA_BUNDLE` is read once at `LoadDefaultConfig` — no hot reload, **not documented in current AWS SDK Go v2; verify before relying.**
   - **Open questions (from `lib-3` §4):** step-ca rotation cadence (intermediate vs root); whether SeaweedFS S3 / RustFS bridge serves the full chain at handshake; whether the operator-managed gateway sidecars have a reload story for their own CA bundle; Reloader annotation coverage on the Loki StatefulSet volume references.
3. **R · Retention drift.** Loki retention materialises via compactor runs. Replica deletion lags by up to one compaction interval → DR object counts/bytes drift. Reconcile via bucket listing cron, not by trusting parity.
   - **Decision (2026-09-17): research and show pros/cons.** See `lib-4` research output (pending).
4. **X · Observability gap.** Neither `weed filer.remote.gateway` nor `filer.sync` exposes metrics or drift detection. `-a.debug`/`-b.debug` logs and (operator backup path only) `status.backupMirrors` are all that exist. Drift detection has to be out-of-band (e.g., a Grafana panel comparing `s3_objects_total` across buckets).
   - **Decision (2026-09-17): deferred.**
5. **D · Secret rotation requires filer restart.** SeaweedFS reads TOML at startup. Rotation of external-SeaweedFS or RustFS access keys requires a filer pod restart (operator README explicitly warns).
   - **Decision (2026-09-17): use recommended.** Add `cluster-autoscaler.kubernetes.io/safe-to-evict: "true"` (or operator equivalent) to the filer pod template; document the restart requirement in the operator's `Secret` rotation runbook; one replica restart at a time during rotation.
6. **X · Network-blip behaviour.** Pause/resume is safe per wiki, but long partitions produce unbounded fan-out backlog with no built-in alerting. On high change rates `filer.sync` can fail to catch up — does not apply here (we picked Gateway-to-Remote) but worth documenting if `filer.sync` is later added for a third SeaweedFS sink.
   - **Decision (2026-09-17): deferred.** Not applicable to Gateway-to-Remote; document only if `filer.sync` is ever added.
7. **D · Spoke-region Loki cannot reach hub-only SeaweedFS.** Today: hub SeaweedFS is the only instance; `monitoring/setup.sh:39` deploys Loki per region. Once SeaweedFS moves in-cluster, decide whether each region gets its own in-cluster SeaweedFS or shares via cross-region networking.
   - **Decision (2026-09-17): hub-only for now.** Out of scope for this PoC. Reopen when/if spoke regions need their own storage.
8. **A · Operator version risk.** `seaweedfs-operator` is 0.1.x. The `sidecars` + `configSecret` approach is the only path today. If the operator ships first-class remote-gateway fields in a future release, this design becomes shorter.
   - **Decision (2026-09-17): accepted.** No action; revisit at next operator release.

---

## 8. Decisions log (recorded 2026-09-17) and next steps

### 8.1 Resolved items

| # | Item | Decision | Notes |
|---|---|---|---|
| 1 | Topology (§2.2) | **Coexist** in-cluster SeaweedFS with host Docker container during PoC | Host container = rollback target; decommission in a separate change after PoC |
| 2 | Spoke-region (risk 7) | **Hub-only** for now | Out of scope; reopen if spoke regions need storage |
| 3 | Tombstone window (risk 1) | **YAGNI for now** | Suggestion recorded in §7.1; implement only if a real deletion incident motivates it |
| 4 | Codemap + graphify cleanup | **Defer** | Tracked as `cnpg-playground-ozm`; user notes more work in flight |
| 5 | Operator PoC | **Two Lokis side-by-side** | See §8.2 |
| 6 | Cert rotation (risk 2) | **Research pros/cons** | Tracked as `lib-3` research; output feeds §7.2 |
| 7 | Retention drift (risk 3) | **Research pros/cons** | Tracked as `lib-4` research; output feeds §7.3 |
| 8 | Observability (risk 4) | **Deferred** | — |
| 9 | Secret rotation (risk 5) | **Use recommended** | See §7.5 |
| 10 | Network-blip (risk 6) | **Deferred** | — |
| 11 | Operator version (risk 8) | **Accepted** | Revisit at next operator release |

### 8.2 PoC scope: two Lokis side-by-side

The PoC deploys **two** Loki Helm releases against **two** independent object-store paths under the same cluster and same synthetic load, so the design is validated under identical conditions.

| Component | Backend | Purpose |
|---|---|---|
| **Loki #1** (`loki-primary`) | in-cluster SeaweedFS (operator-managed) → fan-out via `weed filer.remote.gateway` to external SeaweedFS + RustFS | DR path; canonical chunk store; deletion propagates to both DR sinks |
| **Loki #2** (`loki-rustfs`) | RustFS directly (existing `objectstore-local:9000` bridge) | Direct-write path; baseline for comparison |
| Synthetic log load | same Alloy → both Lokis via parallel `loki.write` blocks | Identical inputs for A/B |

#### Per-component PoC checklist

**Loki #1 (`loki-primary`) → in-cluster SeaweedFS + DR fan-out:**
1. Install `seaweedfs-operator` (`monitoring/setup.sh` new step).
2. Apply `Seaweed` CR in `grafana` ns with `filer.configSecret` referencing two `[s3]` remotes (`cloud1`=external SeaweedFS, `cloud2`=RustFS) and `filer.sidecars[]` with two `weed filer.remote.gateway` daemons.
3. Repoint Loki #1 `s3.endpoint` to `http://seaweedfs-s3.grafana.svc.cluster.local:8333` (or operator-TLS variant). Keep `s3ForcePathStyle: true` and existing `ca_file` for the in-cluster TLS hop.
4. Create buckets `loki` on both DR sinks pre-flight (`mc mb`).
5. Validate: synthetic load → objects appear in in-cluster SeaweedFS → both DR sinks within observable lag; retention delete propagates; compactor runs cleanly.

**Loki #2 (`loki-rustfs`) → RustFS directly:**
1. Second Helm release in a separate namespace (e.g. `monitoring-l2` or `grafana-l2`) with its own `loki-values-rustfs.yaml`.
2. `s3.endpoint: http://objectstore-local:9000`, `s3.insecure: true` (or `http_config.insecure_skip_verify: true` if RustFS bridge serves self-signed TLS — see §5.1 caveat), creds from `RUSTFS_ROOT_USER`/`RUSTFS_ROOT_PASSWORD`.
3. Same retention, schema, and bucket naming (`loki`/`loki`/`loki`). Bucket must be `mc mb`'d in RustFS first.
4. Validate: same synthetic load path; verify write/read/compactor behaviour on RustFS.

**A/B comparison deliverable:**
- Object counts, multipart behaviour, compactor latency, deletion propagation latency under identical load.
- Functional delta expected: zero (Loki → SeaweedFS S3 ≈ Loki → RustFS S3, MinIO-grade parity).
- Operational delta expected: RustFS lacks SeaweedFS bucket-policy/IAM model; Loki does not exercise it today, so this should be invisible in Loki-specific tests but worth noting.

### 8.3 Remaining non-PoC tasks

- **Cert rotation** (§7.2): research pending, fold into §7.2 when `lib-3` returns.
- **Retention drift** (§7.3): research pending, fold into §7.3 when `lib-4` returns.
- **Codemap + graphify** (`cnpg-playground-ozm`): deferred.
- **Decommission host Docker SeaweedFS**: after PoC validates, separate change.
- **Multi-region expansion**: not in scope.

---

## 9. Sources

- https://github.com/seaweedfs/seaweedfs/wiki/Gateway-to-Remote-Object-Storage
- https://github.com/seaweedfs/seaweedfs/wiki/Filer-Active-Active-cross-cluster-continuous-synchronization
- https://github.com/seaweedfs/seaweedfs-operator (CRD at master; release `seaweedfs-operator-0.1.42`, 2026-09-14)
- https://github.com/rustfs/rustfs (`docs/architecture/s3-compatibility-matrix.md`, `README.md`, `ARCHITECTURE.md`, main branch)
- https://grafana.com/docs/loki/latest/configuration/#common-storage (via Context7 `/grafana/loki`)
- Real-world wiring: `agalue/LGTM-PoC/values-loki.yaml`, `safebucket/safebucket/deployments/local/full/config/loki.yaml`, `rustfs/rustfs/.docker/observability/loki.yaml`, `SpecterOps/Nemesis/infra/loki/local-config.yaml`
- Repo recon: `monitoring/loki/loki-values.yaml`, `monitoring/setup.sh`, `common.sh:88–97`, `seaweedfs/config/identities.json`
