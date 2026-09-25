#!/usr/bin/env bash
#
# Loki storage harness: health, DR restore drill, and the load/query tools of
# the storage PoC (epic t9p7).
#
#   scripts/loki-bench.sh health  [region]              # is Loki's storage (and the DR mirror) healthy?
#   scripts/loki-bench.sh restore [region]              # restore drill from the RustFS mirror
#   scripts/loki-bench.sh query   [region] [hours-ago]  # fixed LogQL set vs each Loki in LOKI_BENCH_ARMS
#   scripts/loki-bench.sh ingest  [region]              # ingest parity across LOKI_BENCH_ARMS
#   scripts/loki-bench.sh status  [region]              # soak progress at a glance
#   scripts/loki-bench.sh start   [region]              # start a soak (flog load) and record t0
#   scripts/loki-bench.sh elapsed [region]              # how far into the soak are we?
#
# Loki ("loki"): storage in the in-cluster SeaweedFS seaweedfs-ab (bucket loki),
# mirrored by filer.backup into the RustFS bucket loki-mirror for DR. The PoC's
# other two arms (loki-rustfs, and the old loki on the host SeaweedFS) were
# decommissioned in bead j9wn; compare against extra releases again with e.g.
#   LOKI_BENCH_ARMS="loki loki-candidate" scripts/loki-bench.sh query
#
set -euo pipefail

source "$(git rev-parse --show-toplevel)/scripts/common.sh"

mode="${1:-status}"
region="${2:-local}"
CONTEXT="$(get_cluster_context "${region}")"
kc() { kubectl --context "${CONTEXT}" "$@"; }

ARMS="${LOKI_BENCH_ARMS:-loki}"
# Platform view: platform plus every tenant org, so all arms are compared
# over the SAME data. A single-org read would compare different line sets.
ORG="${LOKI_BENCH_ORG:-platform}"

# Queries must land on ranges the ingesters no longer serve, or the result is a
# memory benchmark rather than an object-store one. Loki serves the recent
# window from ingesters (query_ingesters_within, default 3h) and holds open
# chunks up to max_chunk_age (default 2h), so anything older than ~4h is safely
# store-only.
HOURS_AGO="${3:-5}"

# Fixed query set. Deliberately spans a cheap label lookup, a filtered scan and
# two aggregations, because object-store latency shows up differently in each:
# the scan pulls many chunks, the aggregations pull many and then compute.
QUERIES='
label_only|{namespace="loki-bench"}
filter_404|{namespace="loki-bench"} |= " 404 "
count_5m|sum(count_over_time({namespace="loki-bench"}[5m]))
bytes_by_pod|sum by (pod) (bytes_over_time({namespace="loki-bench"}[5m]))
'

# The nightly Barman backup of verstappen at 00:00 writes heavily to the host
# SeaweedFS on the same VM disk, so a window overlapping it measures that IO too.
warn_if_backup_window() {
    local h; h=$(date -u -d "${HOURS_AGO} hours ago" +%H 2>/dev/null || echo "")
    if [[ "${h}" == "00" ]]; then
        echo "  ⚠️  window overlaps the 00:00-00:30 Barman backup of verstappen, which" >&2
        echo "      writes to the host SeaweedFS on the same disk. Pick another -hours-ago." >&2
    fi
}

runner_pod() {  # <name> <script> [image]
    kc -n grafana delete pod "$1" --ignore-not-found >/dev/null 2>&1
    kc -n grafana run "$1" --restart=Never --image="${3:-curlimages/curl:8.8.0}" \
        --pod-running-timeout=300s --command -- sh -ec "$2" >/dev/null 2>&1
    kc -n grafana wait "pod/$1" --for=jsonpath='{.status.phase}'=Succeeded --timeout=600s >/dev/null 2>&1 || true
    kc -n grafana logs "$1" 2>&1
    kc -n grafana delete pod "$1" --ignore-not-found >/dev/null 2>&1
}

cmd_query() {
    warn_if_backup_window
    local end start
    end=$(date -d "${HOURS_AGO} hours ago" +%s)
    start=$(( end - 3600 ))
    echo "Query set over ${start} .. ${end} (1h window ending ${HOURS_AGO}h ago), org=${ORG}"
    echo
    runner_pod loki-bench-query "
        printf '%-14s %-16s %10s %10s %10s\n' QUERY ARM 'ms(1)' 'ms(2)' 'ms(3)'
        echo '$QUERIES' | while IFS='|' read -r name q; do
          [ -z \"\$name\" ] && continue
          for h in ${ARMS}; do
            t1=\$(curl -sS -o /dev/null -w '%{time_total}' --get \
                  \"http://\$h.grafana.svc.cluster.local:3100/loki/api/v1/query_range\" \
                  -H 'X-Scope-OrgID: ${ORG}' --data-urlencode \"query=\$q\" \
                  --data-urlencode 'start=${start}' --data-urlencode 'end=${end}' \
                  --data-urlencode 'step=60' --data-urlencode 'limit=1000' 2>/dev/null)
            t2=\$(curl -sS -o /dev/null -w '%{time_total}' --get \
                  \"http://\$h.grafana.svc.cluster.local:3100/loki/api/v1/query_range\" \
                  -H 'X-Scope-OrgID: ${ORG}' --data-urlencode \"query=\$q\" \
                  --data-urlencode 'start=${start}' --data-urlencode 'end=${end}' \
                  --data-urlencode 'step=60' --data-urlencode 'limit=1000' 2>/dev/null)
            t3=\$(curl -sS -o /dev/null -w '%{time_total}' --get \
                  \"http://\$h.grafana.svc.cluster.local:3100/loki/api/v1/query_range\" \
                  -H 'X-Scope-OrgID: ${ORG}' --data-urlencode \"query=\$q\" \
                  --data-urlencode 'start=${start}' --data-urlencode 'end=${end}' \
                  --data-urlencode 'step=60' --data-urlencode 'limit=1000' 2>/dev/null)
            printf '%-14s %-16s %10.0f %10.0f %10.0f\n' \"\$name\" \"\$h\" \
              \$(echo \"\$t1*1000\" | awk '{print \$1*1000}') \
              \$(echo \"\$t2\" | awk '{print \$1*1000}') \
              \$(echo \"\$t3\" | awk '{print \$1*1000}')
          done
        done
    "
}

# LOKI_BENCH_SETTLE / LOKI_BENCH_WINDOW let the same check run early in a soak
# (when nothing is old enough to be settled yet) and on settled data later.
# Read at CALL time: resolving them once at script load meant a per-call
# override (`LOKI_BENCH_SETTLE=60 cmd_ingest`) was silently ignored — `start`
# then "confirmed" ingestion against a window older than the load itself, saw
# zeros on every arm, and started the clock anyway.
#
# Returns non-zero if any arm reports zero lines, so callers can refuse to
# proceed rather than print zeros and carry on.
cmd_ingest() {
    local settle="${LOKI_BENCH_SETTLE:-600}" window="${LOKI_BENCH_WINDOW:-30m}" out
    echo "Ingest parity over ${window} ending ${settle}s ago, org=${ORG}"
    echo "NOTE: always use a settled window. At the live edge the arms differ purely"
    echo "      by chunk-flush timing, which is the thing being measured."
    echo
    out=$(runner_pod loki-bench-ingest "
        END=\$(( \$(date +%s) - ${settle} ))
        for h in ${ARMS}; do
          b=\$(curl -sS --get \"http://\$h.grafana.svc.cluster.local:3100/loki/api/v1/query\" \
                -H 'X-Scope-OrgID: ${ORG}' \
                --data-urlencode 'query=sum(bytes_over_time({namespace=\"loki-bench\"}[${window}]))' \
                --data-urlencode \"time=\$END\" 2>/dev/null | tr ',' '\n' | grep -A1 '\"value\"' | tail -1 | tr -dc '0-9')
          l=\$(curl -sS --get \"http://\$h.grafana.svc.cluster.local:3100/loki/api/v1/query\" \
                -H 'X-Scope-OrgID: ${ORG}' \
                --data-urlencode 'query=sum(count_over_time({namespace=\"loki-bench\"}[${window}]))' \
                --data-urlencode \"time=\$END\" 2>/dev/null | tr ',' '\n' | grep -A1 '\"value\"' | tail -1 | tr -dc '0-9')
          printf '  %-18s bytes=%-12s lines=%s\n' \"\$h\" \"\${b:-0}\" \"\${l:-0}\"
        done
    ")
    echo "${out}"
    ! printf '%s\n' "${out}" | grep -q 'lines=0$'
}


# Is the soak still producing trustworthy data? A soak can keep running while an
# object store has stopped accepting writes, and the verdict would then be taken
# over a window where one arm was silently broken. Run this periodically during
# the soak, not just at the end.
#
# Motivated by a real failure: RustFS (pre-1.0) degraded ~21h into a 26h run and
# began rejecting even its own configured root key with InvalidAccessKeyId, while
# its on-disk data stayed intact. Arm A and the mirror stopped ingesting; the
# other two arms carried on, so nothing looked wrong from the outside.
cmd_health() {
    # A non-zero exit here is a RESULT (soak dirty), not a script failure, so
    # drop common.sh's ERR trap for this path.
    trap - ERR
    # Time-bounded, not "last N lines": a line-count window cannot tell an error
    # from an hour ago from one happening now, so a recovered component kept
    # failing the check and a quiet failing one could pass it.
    local since="${LOKI_BENCH_HEALTH_SINCE:-30m}" bad=0 n
    local pat='InvalidAccessKeyId|AccessDenied|NoSuchBucket|bucket does not exist|failed to flush|500 Internal Server Error'

    echo "=== Loki arms: object-store errors in the last ${since} ==="
    for arm in ${ARMS}; do
        n=$(kc -n grafana logs "${arm}-0" -c loki --since="${since}" 2>/dev/null | grep -ciE "${pat}" || true)
        if [ "${n:-0}" -gt 0 ]; then
            printf '  ❌ %-16s %s store errors\n' "${arm}" "${n}"; bad=$((bad + 1))
        else
            printf '  ✅ %-16s clean\n' "${arm}"
        fi
    done

    echo
    echo "=== mirror sidecar (last ${since}) ==="
    n=$(kc -n grafana logs seaweedfs-ab-filer-0 -c filer-backup-rustfs --since="${since}" 2>/dev/null \
         | grep -ciE 'InvalidAccessKeyId|AccessDenied|error' || true)
    if [ "${n:-0}" -gt 0 ]; then printf '  ❌ filer.backup    %s errors\n' "${n}"; bad=$((bad + 1))
    else printf '  ✅ filer.backup    clean\n'; fi

    # Mimir and Tempo store on RustFS, which also holds the DR mirror. In soak 2 they reported
    # the RustFS failure ("bucket does not exist") while this check only looked
    # at Loki, so the failure went unnoticed until verdict time.
    echo
    echo "=== Mimir / Tempo long-term store (last ${since}) ==="
    local ns
    for ns in mimir tempo; do
        n=$(kc -n "${ns}" logs -l 'app.kubernetes.io/component in (ingester,compactor,store-gateway)' \
              --since="${since}" --prefix 2>/dev/null | grep -ciE "${pat}" || true)
        if [ "${n:-0}" -gt 0 ]; then printf '  ❌ %-16s %s store errors\n' "${ns}" "${n}"; bad=$((bad + 1))
        else printf '  ✅ %-16s clean\n' "${ns}"; fi
    done

    # Log-silence is not correctness: a store can accept requests and return
    # nothing. After RustFS failed, arm A answered every stored window with an
    # EMPTY result and no error. So ask each arm the same question about data
    # old enough to be store-served, and require the same answer.
    echo
    echo "=== store-served answers (1h window ending 5h ago, all namespaces) ==="
    local ans
    ans=$(runner_pod loki-bench-health "
        T=\$(( \$(date +%s) - 5*3600 ))
        for h in ${ARMS}; do
          v=\$(curl -sS --get \"http://\$h.grafana.svc.cluster.local:3100/loki/api/v1/query\" \
                -H 'X-Scope-OrgID: ${ORG}' \
                --data-urlencode 'query=sum(count_over_time({namespace=~\".+\"}[1h]))' \
                --data-urlencode \"time=\$T\" 2>/dev/null | tr ',' '\n' | grep -A1 '\"value\"' | tail -1 | tr -dc '0-9')
          echo \"\$h \${v:-0}\"
        done
    ")
    printf '%s\n' "${ans}" | sed 's/^/  /'
    if [ "$(wc -w <<<"${ARMS}")" -lt 2 ]; then
        # One Loki: nothing to compare against. An empty stored window is only
        # expected on a cluster younger than ~6h, so warn rather than fail.
        if printf '%s\n' "${ans}" | awk 'NF==2 && $2==0 {z=1} END {exit !z}'; then
            echo "  ⚠️  stored window is EMPTY (expected only on a cluster younger than ~6h)"
        else
            echo "  ✅ stored window served"
        fi
    elif [ "$(printf '%s\n' "${ans}" | awk 'NF==2 {print $2}' | sort -u | wc -l)" -gt 1 ]; then
        echo "  ❌ arms DISAGREE on the same stored window"; bad=$((bad + 1))
    else
        echo "  ✅ arms agree"
    fi

    echo
    echo "=== flog load still running? ==="
    kc -n loki-bench get deploy flog --no-headers 2>&1 | sed 's/^/  /' || true

    echo
    if [ "${bad}" -gt 0 ]; then
        echo "  VERDICT: soak is NOT clean — ${bad} check(s) failing."
        echo "  Results taken across this window are not trustworthy. Fix, then restart the clock."
        return 1
    fi
    echo "  VERDICT: soak is clean."
}


# Where t0 is recorded. Kept in the repo rather than /tmp so it survives a reboot
# and a different shell — the verdict window depends on it.
SOAK_STATE="${GIT_REPO_ROOT}/k8s/rendered/loki-bench-soak-start"

# Start the soak. Deliberately NOT part of monitoring/setup.sh: this generates
# continuous synthetic load, so it must be an explicit act rather than a side
# effect of rebuilding the cluster.
cmd_start() {
    trap - ERR
    echo "=== preconditions ==="
    local bad=0 notrunning r
    notrunning=$(kc get pods -A --no-headers 2>/dev/null | grep -vcE 'Running|Completed' || true)
    echo "  pods not Running/Completed : ${notrunning}"
    [ "${notrunning:-0}" -gt 0 ] && bad=1
    for arm in ${ARMS}; do
        r=$(kc -n grafana get sts "${arm}" -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
        printf '  %-16s ready=%s\n' "${arm}" "${r:-0}"
        [ "${r:-0}" = "1" ] || bad=1
    done
    if [ "${bad}" -ne 0 ]; then
        echo
        echo "  cluster is not clean — fix before starting a 26h clock."
        return 1
    fi

    echo
    echo "=== applying flog load ==="
    kc apply -f "${GIT_REPO_ROOT}/monitoring/loki-bench/flog.yaml"
    kc -n loki-bench rollout status deploy/flog --timeout=300s

    echo
    echo "=== confirming every arm is ingesting it ==="
    sleep 90
    if ! LOKI_BENCH_SETTLE=30 LOKI_BENCH_WINDOW=1m cmd_ingest; then
        echo
        echo "  At least one arm shows NO ingested load. Not starting the clock."
        return 1
    fi

    echo
    mkdir -p "$(dirname "${SOAK_STATE}")"
    date -Is > "${SOAK_STATE}"
    echo "=== SOAK STARTED: $(cat "${SOAK_STATE}") ==="
    echo "    >=26h elapses: $(date -Is -d "$(cat "${SOAK_STATE}") + 26 hours")"
    echo
    echo "  Check it is still VALID periodically, not just at the end:"
    echo "    scripts/loki-bench.sh health ${region}"
    echo "  A store can stop accepting writes mid-soak while everything still looks up."
}

cmd_elapsed() {
    trap - ERR
    if [ ! -f "${SOAK_STATE}" ]; then
        echo "  no soak recorded — run: scripts/loki-bench.sh start ${region}"
        return 1
    fi
    local t0 s n e
    t0=$(cat "${SOAK_STATE}")
    s=$(date -d "${t0}" +%s); n=$(date +%s); e=$(( (n - s) / 60 ))
    echo "  started : ${t0}"
    echo "  elapsed : ${e} min ($(( e / 60 ))h $(( e % 60 ))m) of >=1560 min (26h)"
    echo "  ends    : $(date -Is -d "${t0} + 26 hours")"
    if [ "${e}" -ge 1560 ]; then
        echo "  soak window COMPLETE"
    else
        echo "  remaining: $(( (1560 - e) / 60 ))h $(( (1560 - e) % 60 ))m"
    fi
}

cmd_status() {
    echo "=== flog load ==="
    kc -n loki-bench get deploy,pods 2>&1 | sed 's/^/  /' || echo "  (loki-bench absent — soak not started)"
    echo
    echo "=== arm StatefulSets ==="
    kc -n grafana get sts 2>&1 | grep -E 'NAME|loki' | sed 's/^/  /'
    echo
    echo "=== ingest parity ==="
    cmd_ingest || true
}

# Restore drill (design doc §5, pass/fail gate): does the RustFS loki-mirror
# bucket actually hold a USABLE copy of Loki's store (seaweedfs-ab)?
#
# Stands up a throwaway Loki ("loki-restore", the platform Loki's exact schema)
# that reads loki-mirror through a Get/List-only RustFS user, asks it and "loki"
# the same count questions over store-served windows, then removes everything
# it created. PASS = every window answers identically, with data in it.
#
# Safe to run DURING a soak: the drill never writes to the mirror (read-only
# user, verified before Loki starts; retention off; no writer points at it) and
# does not touch the platform Loki.
#
#   LOKI_BENCH_RESTORE_AGES="5 10 15 20"  window END ages in hours (1h windows)
#   LOKI_BENCH_RESTORE_KEEP=1            leave loki-restore running afterwards
cmd_restore() {
    # A non-zero exit here is a RESULT (drill FAIL), not a script failure. Drop
    # errexit as well as common.sh's ERR trap: under `set -eo pipefail` any
    # failing pipeline (e.g. `kc logs` of a pod that never started) would end
    # the script before restore_cleanup, stranding loki-restore and its user.
    trap - ERR
    set +e
    local ages="${LOKI_BENCH_RESTORE_AGES:-5 10 15 20}" keep="${LOKI_BENCH_RESTORE_KEEP:-0}"
    local mirror="${RUSTFS_LOKI_MIRROR_BUCKET}" ro_key="${RUSTFS_LOKI_RESTORE_ACCESS_KEY}"
    local ro_secret="${RUSTFS_LOKI_RESTORE_SECRET_KEY}" out

    echo "Restore drill: RustFS ${mirror} (via loki-restore) vs loki, org=${ORG}"
    echo "  1h windows ending ${ages// /h, }h ago"
    # The source answers from ingester memory + store; the restore sees only
    # what has been flushed AND whose TSDB index has been shipped (chunks flush
    # at max_chunk_age 2h). Younger windows DIFF by design, not by mirror loss:
    # a 2h-old window measured 22100 (source) vs 15145 (copy) on 2026-09-24.
    local a
    for a in ${ages}; do
        if (( a < 4 )); then
            echo "  ⚠️  ${a}h is younger than ~4h: the source still serves part of that window"
            echo "      from ingester memory, so a DIFF there says nothing about the mirror."
            break
        fi
    done
    echo

    restore_cleanup() {
        [[ "${keep}" == "1" ]] && { echo "  (LOKI_BENCH_RESTORE_KEEP=1: leaving loki-restore + ${ro_key} in place)"; return; }
        echo "=== cleanup ==="
        helm uninstall loki-restore -n grafana --kube-context "${CONTEXT}" --wait >/dev/null 2>&1 \
            && echo "  helm release loki-restore removed" || echo "  (no loki-restore release)"
        kc -n grafana delete secret loki-restore-s3 --ignore-not-found >/dev/null
        runner_pod loki-restore-iam-rm "
            rc alias set store https://objectstore-local:9000 '${RUSTFS_ROOT_USER}' '${RUSTFS_ROOT_PASSWORD}' --insecure >/dev/null
            rc admin policy detach store ${mirror}-ro --user '${ro_key}' >/dev/null 2>&1 || true
            rc admin user rm store '${ro_key}' >/dev/null 2>&1 && echo '  RustFS user ${ro_key} removed' || echo '  (RustFS user ${ro_key} not removed)'
            rc admin policy rm store ${mirror}-ro >/dev/null 2>&1 && echo '  RustFS policy ${mirror}-ro removed' || echo '  (RustFS policy ${mirror}-ro not removed)'" "${RC_IMAGE}"
    }

    # 1. Read-only RustFS user. The mirror's own user is read-write (filer.backup
    #    writes and deletes through it), so it must not be what the restore uses.
    echo "=== 1. read-only RustFS user ${ro_key} ==="
    out=$(runner_pod loki-restore-iam "
        rc alias set store https://objectstore-local:9000 '${RUSTFS_ROOT_USER}' '${RUSTFS_ROOT_PASSWORD}' --insecure >/dev/null
        printf '%s' '{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Action\":[\"s3:GetObject\",\"s3:ListBucket\",\"s3:GetBucketLocation\"],\"Resource\":[\"arn:aws:s3:::${mirror}\",\"arn:aws:s3:::${mirror}/*\"]}]}' > /tmp/ro.json
        rc admin policy create store ${mirror}-ro /tmp/ro.json >/dev/null
        rc admin user add store '${ro_key}' '${ro_secret}' >/dev/null
        rc admin policy attach store ${mirror}-ro --user '${ro_key}' >/dev/null
        rc alias set ro https://objectstore-local:9000 '${ro_key}' '${ro_secret}' --insecure >/dev/null
        echo READ_OK objects=\$(rc --json object list -r ro/${mirror}/ | grep -c '\"key\"')
        if echo x | rc pipe ro/${mirror}/zz-restore-ro-probe >/dev/null 2>&1; then
            rc object remove store/${mirror}/zz-restore-ro-probe >/dev/null 2>&1
            echo WRITE_ALLOWED
        else
            echo WRITE_DENIED
        fi" "${RC_IMAGE}")
    echo "${out}" | sed 's/^/  /'
    if ! grep -q '^READ_OK' <<<"${out}" || ! grep -q '^WRITE_DENIED' <<<"${out}"; then
        echo "  ❌ ${ro_key} cannot read ${mirror}, or CAN write to it. Not starting a Loki on it."
        restore_cleanup
        return 1
    fi

    # 2. The restore Loki.
    echo
    echo "=== 2. loki-restore (the platform Loki's schema, reading ${mirror}) ==="
    kc -n grafana create secret generic loki-restore-s3 \
        --from-literal=S3_ACCESS_KEY_ID="${ro_key}" \
        --from-literal=S3_SECRET_ACCESS_KEY="${ro_secret}" \
        --dry-run=client -o yaml | kc apply -f - >/dev/null
    if ! helm_upgrade_install loki-restore oci://ghcr.io/grafana-community/helm-charts/loki \
            grafana "${CONTEXT}" "${LOKI_CHART_VERSION}" \
            --values "${GIT_REPO_ROOT}/monitoring/loki/loki-values-common.yaml" \
            --values "${GIT_REPO_ROOT}/monitoring/loki/loki-values-restore.yaml" >/dev/null; then
        echo "  ❌ loki-restore did not become ready"
        kc -n grafana logs loki-restore-0 -c loki --tail=20 2>&1 | sed 's/^/    /'
        restore_cleanup
        return 1
    fi
    echo "  loki-restore ready"

    # 3. Same questions to source and copy. Counts, not log lines: a log query
    #    returns at most `limit` lines, so equal line lists would prove little.
    echo
    echo "=== 3. source vs restored copy ==="
    out=$(runner_pod loki-restore-compare "
        q() {  # <host> <logql> <time>
          curl -sS --get \"http://\$1.grafana.svc.cluster.local:3100/loki/api/v1/query\" \
            -H 'X-Scope-OrgID: ${ORG}' --data-urlencode \"query=\$2\" --data-urlencode \"time=\$3\" 2>/dev/null \
            | tr ',' '\n' | grep -A1 '\"value\"' | tail -1 | tr -dc '0-9'
        }
        NOW=\$(date +%s)
        printf '  %-6s %-12s %14s %14s\n' AGE QUERY loki loki-restore
        for h in ${ages}; do
          T=\$(( NOW - h*3600 ))
          for spec in \
            'all_lines|sum(count_over_time({namespace=~\".+\"}[1h]))' \
            'bench_lines|sum(count_over_time({namespace=\"loki-bench\"}[1h]))' \
            'bench_404|sum(count_over_time({namespace=\"loki-bench\"} |= \" 404 \" [1h]))' \
            'bench_bytes|sum(bytes_over_time({namespace=\"loki-bench\"}[1h]))'; do
            name=\${spec%%|*}; logql=\${spec#*|}
            src=\$(q loki \"\$logql\" \$T); dst=\$(q loki-restore \"\$logql\" \$T)
            src=\${src:-0}; dst=\${dst:-0}
            if [ \"\$src\" = \"\$dst\" ]; then
              if [ \"\$src\" = 0 ]; then v=EMPTY; else v=MATCH; fi
            else v=DIFF; fi
            printf '  %-6s %-12s %14s %14s  %s\n' \"\${h}h\" \"\$name\" \"\$src\" \"\$dst\" \"\$v\"
          done
        done")
    echo "${out}"

    restore_cleanup

    echo
    local diff match
    diff=$(grep -c ' DIFF$' <<<"${out}" || true)
    match=$(grep -c ' MATCH$' <<<"${out}" || true)
    if [[ "${diff}" -eq 0 && "${match}" -gt 0 ]]; then
        echo "  ✅ RESTORE DRILL: PASS — ${match} non-empty comparisons, all identical."
        return 0
    elif [[ "${diff}" -eq 0 ]]; then
        echo "  ⚠️  RESTORE DRILL: INCONCLUSIVE — every window is empty in the source."
        echo "      Pick older windows (LOKI_BENCH_RESTORE_AGES) once the soak has data there."
        return 1
    fi
    echo "  ❌ RESTORE DRILL: FAIL — ${diff} comparison(s) differ between source and copy."
    return 1
}

case "${mode}" in
    start)   cmd_start ;;
    elapsed) cmd_elapsed ;;
    query)   cmd_query ;;
    health)  cmd_health ;;
    ingest)  cmd_ingest ;;
    restore) cmd_restore ;;
    status)  cmd_status ;;
    *) sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac
