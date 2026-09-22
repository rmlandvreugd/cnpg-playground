#!/usr/bin/env bash
#
# A/B/C Loki storage benchmark harness (bead cnpg-playground-t9p7.3).
#
#   scripts/loki-bench.sh query   [region] [hours-ago]  # fixed LogQL set vs each arm
#   scripts/loki-bench.sh ingest  [region]              # ingest parity across arms
#   scripts/loki-bench.sh restore [region]              # restore drill from the RustFS mirror
#   scripts/loki-bench.sh status  [region]              # soak progress at a glance
#   scripts/loki-bench.sh start   [region]              # start the soak and record t0
#   scripts/loki-bench.sh health  [region]              # is the soak still VALID?
#   scripts/loki-bench.sh elapsed [region]              # how far into the soak are we?
#
# The three arms:
#   A loki-rustfs     -> RustFS directly       (bucket loki-direct)
#   B loki-seaweedfs  -> in-cluster SeaweedFS  (bucket loki, mirrored to RustFS)
#   C loki            -> host SeaweedFS        (bucket loki, the control)
#
set -euo pipefail

source "$(git rev-parse --show-toplevel)/scripts/common.sh"

mode="${1:-status}"
region="${2:-local}"
CONTEXT="$(get_cluster_context "${region}")"
kc() { kubectl --context "${CONTEXT}" "$@"; }

ARMS="loki loki-rustfs loki-seaweedfs"
# Platform view: platform plus every tenant org, so all three arms are compared
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

# The nightly Barman backup of verstappen at 00:00 writes into the HOST SeaweedFS
# that backs arm C, so a window overlapping it would penalise C for unrelated IO.
warn_if_backup_window() {
    local h; h=$(date -u -d "${HOURS_AGO} hours ago" +%H 2>/dev/null || echo "")
    if [[ "${h}" == "00" ]]; then
        echo "  ⚠️  window overlaps the 00:00-00:30 Barman backup of verstappen, which" >&2
        echo "      writes to the host SeaweedFS behind arm C. Pick another -hours-ago." >&2
    fi
}

runner_pod() {  # <name> <script>
    kc -n grafana delete pod "$1" --ignore-not-found >/dev/null 2>&1
    kc -n grafana run "$1" --restart=Never --image=curlimages/curl:8.8.0 \
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
SETTLE="${LOKI_BENCH_SETTLE:-600}"     # seconds to skip at the live edge
WINDOW="${LOKI_BENCH_WINDOW:-30m}"     # range to aggregate over

cmd_ingest() {
    echo "Ingest parity over ${WINDOW} ending ${SETTLE}s ago, org=${ORG}"
    echo "NOTE: always use a settled window. At the live edge the arms differ purely"
    echo "      by chunk-flush timing, which is the thing being measured."
    echo
    runner_pod loki-bench-ingest "
        END=\$(( \$(date +%s) - ${SETTLE} ))
        for h in ${ARMS}; do
          b=\$(curl -sS --get \"http://\$h.grafana.svc.cluster.local:3100/loki/api/v1/query\" \
                -H 'X-Scope-OrgID: ${ORG}' \
                --data-urlencode 'query=sum(bytes_over_time({namespace=\"loki-bench\"}[${WINDOW}]))' \
                --data-urlencode \"time=\$END\" 2>/dev/null | tr ',' '\n' | grep -A1 '\"value\"' | tail -1 | tr -dc '0-9')
          l=\$(curl -sS --get \"http://\$h.grafana.svc.cluster.local:3100/loki/api/v1/query\" \
                -H 'X-Scope-OrgID: ${ORG}' \
                --data-urlencode 'query=sum(count_over_time({namespace=\"loki-bench\"}[${WINDOW}]))' \
                --data-urlencode \"time=\$END\" 2>/dev/null | tr ',' '\n' | grep -A1 '\"value\"' | tail -1 | tr -dc '0-9')
          printf '  %-18s bytes=%-12s lines=%s\n' \"\$h\" \"\${b:-0}\" \"\${l:-0}\"
        done
    "
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
    # drop common.sh's ERR trap for this path — otherwise it prints a misleading
    # "script failed" line on top of a perfectly good verdict.
    trap - ERR
    local bad=0
    echo "=== per-arm object-store errors (last 300 log lines) ==="
    for arm in loki loki-rustfs loki-seaweedfs; do
        local n
        n=$(kc -n grafana logs "${arm}-0" -c loki --tail=300 2>/dev/null \
             | grep -ciE 'InvalidAccessKeyId|AccessDenied|NoSuchBucket|failed to flush' || true)
        if [ "${n:-0}" -gt 0 ]; then
            printf '  ❌ %-16s %s store errors\n' "${arm}" "${n}"
            kc -n grafana logs "${arm}-0" -c loki --tail=300 2>/dev/null \
              | grep -iE 'InvalidAccessKeyId|AccessDenied|NoSuchBucket' | tail -1 | cut -c1-160 | sed 's/^/       /'
            bad=$((bad + 1))
        else
            printf '  ✅ %-16s clean\n' "${arm}"
        fi
    done

    echo
    echo "=== mirror sidecar ==="
    local m
    m=$(kc -n grafana logs seaweedfs-ab-filer-0 -c filer-backup-rustfs --tail=300 2>/dev/null \
         | grep -ciE 'InvalidAccessKeyId|AccessDenied|error' || true)
    if [ "${m:-0}" -gt 0 ]; then
        printf '  ❌ filer.backup    %s errors\n' "${m}"
        bad=$((bad + 1))
    else
        printf '  ✅ filer.backup    clean\n'
    fi

    echo
    echo "=== flog load still running? ==="
    kc -n loki-bench get deploy flog --no-headers 2>&1 | sed 's/^/  /'

    echo
    if [ "${bad}" -gt 0 ]; then
        echo "  VERDICT: soak is NOT clean — ${bad} component(s) erroring."
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
    for arm in loki loki-rustfs loki-seaweedfs; do
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
    echo "=== confirming all three arms are ingesting it ==="
    sleep 90
    LOKI_BENCH_SETTLE=60 LOKI_BENCH_WINDOW=1m cmd_ingest

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
    echo "=== bucket contents (object counts) ==="
    runner_pod loki-bench-status "
        echo '  (see scripts/loki-bench.sh restore for the mirror comparison)'
    " >/dev/null 2>&1 || true
    cmd_ingest
}

# Restore drill: does the RustFS mirror actually hold a usable copy of arm B?
# Compares the fixed query set against loki-seaweedfs (source) and a throwaway
# Loki reading the mirror bucket. PASS requires identical counts.
cmd_restore() {
    echo "Restore drill: RustFS loki-mirror vs loki-seaweedfs"
    echo
    echo "  NOTE: the filer.backup mirror follows LIVE filer events and does not"
    echo "  reconcile. If arm B's store was rebuilt while the sidecar was down, the"
    echo "  mirror can hold keys the source no longer has. Re-seed first with:"
    echo "    SEAWEEDFS_AB_INITIAL_SNAPSHOT=-initialSnapshot monitoring/setup.sh ${region}"
    echo
    echo "  Not yet implemented — see bead cnpg-playground-t9p7.3."
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
    *) sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac
