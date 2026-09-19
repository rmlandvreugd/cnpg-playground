#!/usr/bin/env bash
# Cluster-wide ingress allow-list + default-deny (k8s/calico/policies, bead i23).
#
#   scripts/netpol.sh stage   [region]  # apply as StagedGlobalNetworkPolicy: nothing is dropped,
#                                       # would-be denies show up in `scripts/flowlogs.sh pending`
#   scripts/netpol.sh enforce [region]  # apply as GlobalNetworkPolicy (default-deny is live)
#   scripts/netpol.sh off     [region]  # remove both (fully reversible)
#   scripts/netpol.sh status  [region]
#
# Both modes first render GlobalNetworkSet "cluster-nodes" from the node InternalIPs; the
# policies allow it so the apiserver reaches webhooks on other nodes.
set -euo pipefail

source "$(git rev-parse --show-toplevel)/scripts/common.sh"

mode="${1:-}"
region="${2:-local}"
CONTEXT="$(get_cluster_context "${region}")"
POLICY_DIR="${GIT_REPO_ROOT}/k8s/calico/policies"
LABEL="app.kubernetes.io/part-of=playground-netpol"
kc() { kubectl --context "${CONTEXT}" "$@"; }

render_node_set() {
    local ips
    ips=$(kc get nodes -o jsonpath='{range .items[*]}{.status.addresses[?(@.type=="InternalIP")].address}{"\n"}{end}')
    {
        cat <<EOF
apiVersion: projectcalico.org/v3
kind: GlobalNetworkSet
metadata:
  name: cluster-nodes
  labels:
    app.kubernetes.io/part-of: playground-netpol
    role: k8s-node
spec:
  nets:
EOF
        for ip in ${ips}; do echo "    - ${ip}/32"; done
    } | kc apply -f -
}

# The policy files are authored as GlobalNetworkPolicy; staging only swaps the kind.
render_policies() {
    local kind="$1"
    for f in "${POLICY_DIR}"/*.yaml; do
        sed "s/^kind: GlobalNetworkPolicy$/kind: ${kind}/" "${f}"
        echo "---"
    done
}

delete_kind() {
    kc delete "$1" -l "${LABEL}" --ignore-not-found
}

case "${mode}" in
    stage)
        render_node_set
        render_policies StagedGlobalNetworkPolicy | kc apply -f -
        delete_kind globalnetworkpolicies.projectcalico.org
        echo "✅ Allow-list + default-deny STAGED. Drive traffic, then: scripts/flowlogs.sh pending"
        ;;
    enforce)
        render_node_set
        render_policies GlobalNetworkPolicy | kc apply -f -
        delete_kind stagedglobalnetworkpolicies.projectcalico.org
        echo "✅ Allow-list + default-deny ENFORCED. Dropped flows: scripts/flowlogs.sh denied"
        ;;
    off)
        delete_kind globalnetworkpolicies.projectcalico.org
        delete_kind stagedglobalnetworkpolicies.projectcalico.org
        delete_kind globalnetworksets.projectcalico.org
        echo "✅ Allow-list + default-deny removed."
        ;;
    status)
        kc get globalnetworkpolicies.projectcalico.org,stagedglobalnetworkpolicies.projectcalico.org,globalnetworksets.projectcalico.org -l "${LABEL}"
        ;;
    *)
        sed -n '2,11p' "$0" | sed 's/^# \{0,1\}//'
        exit 2
        ;;
esac
