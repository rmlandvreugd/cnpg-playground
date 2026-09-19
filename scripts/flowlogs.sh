#!/usr/bin/env bash
# Query Calico's flow-logs API (Goldmane, gRPC goldmane.Flows/List) for the local cluster.
# Goldmane is mTLS-only; this borrows the whisker-backend client cert that the operator
# issues, port-forwards calico-system/goldmane and calls it with grpcurl + the pinned proto.
#
#   scripts/flowlogs.sh denied  [--since SECS] [--ns NS] [--json]  # flows the dataplane denied
#   scripts/flowlogs.sh pending [--since SECS] [--ns NS] [--json]  # flows a STAGED policy would deny
#   scripts/flowlogs.sh all     [--since SECS] [--ns NS] [--json]
#
# --ns filters on the destination namespace. Output: one line per distinct flow key,
#   src_ns/src_name -> dst_ns/dst_name:port/proto  action [policy that decided]
# Use `pending` with the staged default-deny (k8s/calico/policies) to find missing allows
# before enforcing; use `denied` afterwards to confirm only unwanted flows are dropped.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export KUBECONFIG="${KUBECONFIG:-${REPO_ROOT}/k8s/kube-config.yaml}"
PROTO_DIR="${REPO_ROOT}/k8s/calico/goldmane"
LOCAL_PORT="${GOLDMANE_LOCAL_PORT:-17443}"

mode="${1:-}"
shift || true
since=900
ns=""
json=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        --since) since="$2"; shift 2 ;;
        --ns) ns="$2"; shift 2 ;;
        --json) json=true; shift ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done

case "${mode}" in
    denied) filter='"actions":["Deny"]' ;;
    pending) filter='"pending_actions":["Deny"]' ;;
    all) filter='' ;;
    *) sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac
if [[ -n "${ns}" ]]; then
    filter="${filter:+${filter},}\"dest_namespaces\":[{\"value\":\"${ns}\",\"type\":\"Exact\"}]"
fi

command -v grpcurl >/dev/null || { echo "grpcurl not found (mise install)" >&2; exit 1; }

tmp=$(mktemp -d)
pf_pid=""
cleanup() {
    [[ -n "${pf_pid}" ]] && kill "${pf_pid}" 2>/dev/null || true
    rm -rf "${tmp}"
}
trap cleanup EXIT

kubectl -n calico-system get secret whisker-backend-key-pair -o jsonpath='{.data.tls\.crt}' | base64 -d >"${tmp}/tls.crt"
kubectl -n calico-system get secret whisker-backend-key-pair -o jsonpath='{.data.tls\.key}' | base64 -d >"${tmp}/tls.key"
kubectl -n calico-system get configmap tigera-ca-bundle -o jsonpath='{.data.tigera-ca-bundle\.crt}' >"${tmp}/ca.crt"

kubectl -n calico-system port-forward svc/goldmane "${LOCAL_PORT}:7443" >"${tmp}/pf.log" 2>&1 &
pf_pid=$!
for _ in $(seq 1 50); do
    grep -q "Forwarding from" "${tmp}/pf.log" 2>/dev/null && break
    sleep 0.2
done

# Page through the result set (page_size is capped server-side).
filter_clause=""
[[ -n "${filter}" ]] && filter_clause=",\"filter\":{${filter}}"
page=0
: >"${tmp}/flows.json"
while :; do
    req="{\"start_time_gte\":-${since},\"page\":${page},\"page_size\":1000${filter_clause}}"
    grpcurl -import-path "${PROTO_DIR}" -proto api.proto \
        -cacert "${tmp}/ca.crt" -cert "${tmp}/tls.crt" -key "${tmp}/tls.key" \
        -authority goldmane.calico-system.svc -d "${req}" \
        "127.0.0.1:${LOCAL_PORT}" goldmane.Flows/List >"${tmp}/page.json"
    jq -c '.flows[]?' "${tmp}/page.json" >>"${tmp}/flows.json"
    total=$(jq -r '.meta.totalPages // 1' "${tmp}/page.json")
    page=$((page + 1))
    [[ "${page}" -ge "${total}" ]] && break
done

if ${json}; then
    jq -s '.' "${tmp}/flows.json"
    exit 0
fi

# One line per distinct key with the deciding hit of the relevant trace: the first Deny
# (an EndOfTier deny names the policy that selected the endpoint), else the last hit.
jq -rs --arg mode "${mode}" '
  map(.flow.Key) | unique_by([.sourceNamespace, .sourceName, .destNamespace, .destName, .destPort, .proto, .action, .reporter])
  | .[]
  | (if $mode == "pending" then (.policies.pendingPolicies // []) else (.policies.enforcedPolicies // []) end
     | (map(select(.action == "Deny")) | first) // last // {}) as $hit
  | (if $hit.kind == "EndOfTier" then "end-of-tier(\($hit.trigger.name // "?"))"
     else "\($hit.namespace // "")\(if $hit.namespace then "/" else "" end)\($hit.name // "")" end) as $by
  | "\(.sourceNamespace // "-")/\(.sourceName) -> \(.destNamespace // "-")/\(.destName):\(.destPort)/\(.proto)  \($hit.action // .action // "?") [\(.reporter // "?")] \($hit.tier // "")/\($by)"
' "${tmp}/flows.json" | sort -u
