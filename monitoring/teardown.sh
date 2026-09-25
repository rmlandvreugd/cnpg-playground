#!/usr/bin/env bash
##
## Copyright © contributors to CloudNativePG, established as
## CloudNativePG a Series of LF Projects, LLC.
##
## Licensed under the Apache License, Version 2.0 (the "License");
## you may not use this file except in compliance with the License.
## You may obtain a copy of the License at
##
##     http://www.apache.org/licenses/LICENSE-2.0
##
## Unless required by applicable law or agreed to in writing, software
## distributed under the License is distributed on an "AS IS" BASIS,
## WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
## See the License for the specific language governing permissions and
## limitations under the License.
##
## SPDX-License-Identifier: Apache-2.0
##

#
# Tear down the Prometheus/Grafana stack installed by monitoring/setup.sh
#
# Removes all Helm releases, Kubernetes resources, and namespaces created by
# setup.sh, leaving the Kind clusters themselves intact.
# When run without arguments, auto-detects all cnpg-playground Kind clusters.
# To target specific regions only, pass region names as arguments.
#

# Source the common setup script
source $(git rev-parse --show-toplevel)/scripts/common.sh

# --- Main Logic ---
detect_running_regions "$@"

HUB_REGION="${REGIONS[0]}"
HUB_CONTEXT="$(get_cluster_context "${HUB_REGION}")"

for region in "${REGIONS[@]}"; do
    echo "-------------------------------------------------------------"
    echo " 🗑️  Tearing down monitoring for region: ${region}"
    echo "-------------------------------------------------------------"

    K8S_CLUSTER_NAME=$(get_cluster_name "${region}")
    CONTEXT_NAME=$(get_cluster_context "${region}")

    # --- Grafana namespace: collectors, Loki, Grafana CRs, Grafana Operator ---
    # k8s-monitoring supersedes the hand-written 'alloy' release (bead t9p7.2);
    # both are removed so a teardown works whichever one the cluster has.
    echo "🗑️  Uninstalling k8s-monitoring in '${K8S_CLUSTER_NAME}'..."
    helm_uninstall_if_present k8s-monitoring grafana "${CONTEXT_NAME}"
    echo "🗑️  Uninstalling the superseded Alloy release in '${K8S_CLUSTER_NAME}'..."
    helm_uninstall_if_present alloy grafana "${CONTEXT_NAME}"

    echo "🗑️  Uninstalling Loki in '${K8S_CLUSTER_NAME}'..."
    helm_uninstall_if_present loki grafana "${CONTEXT_NAME}"
    # Storage-PoC arms (epic t9p7), decommissioned in bead j9wn. Kept so a
    # teardown also cleans a cluster that was set up before that change.
    helm_uninstall_if_present loki-rustfs grafana "${CONTEXT_NAME}"
    helm_uninstall_if_present loki-seaweedfs grafana "${CONTEXT_NAME}"
    # Only present if a `loki-bench.sh restore` was kept (LOKI_BENCH_RESTORE_KEEP=1) or interrupted.
    helm_uninstall_if_present loki-restore grafana "${CONTEXT_NAME}"
    kubectl --context "${CONTEXT_NAME}" -n grafana delete secret \
        loki-s3 loki-rustfs-s3 loki-seaweedfs-s3 loki-restore-s3 --ignore-not-found
    # Legacy bridge to the host SeaweedFS (Loki storage before bead j9wn).
    kubectl --context "${CONTEXT_NAME}" -n grafana delete service,endpoints seaweedfs --ignore-not-found

    # --- seaweedfs-ab (Loki's storage) ---
    # The Seaweed CR goes first: deleting it lets the operator tear its
    # StatefulSets down before the secrets and the bridge they depend on vanish.
    # The volume PVC is deliberately NOT deleted here, so Loki's history (and
    # the filer.backup mirror checkpoint) survive a monitoring teardown/setup
    # cycle. A full scripts/teardown.sh removes it with the cluster.
    echo "🗑️  Removing Seaweed CR seaweedfs-ab from grafana namespace..."
    if kubectl --context "${CONTEXT_NAME}" get crd seaweeds.seaweed.seaweedfs.com &>/dev/null; then
        kubectl --context "${CONTEXT_NAME}" -n grafana delete seaweed seaweedfs-ab \
            --ignore-not-found --timeout=180s
    fi
    kubectl --context "${CONTEXT_NAME}" -n grafana delete service seaweedfs-ab-s3-https --ignore-not-found
    kubectl --context "${CONTEXT_NAME}" -n grafana delete certificate seaweedfs-ab-s3-tls --ignore-not-found
    kubectl --context "${CONTEXT_NAME}" -n grafana delete secret seaweedfs-ab-s3-tls \
        seaweedfs-ab-s3-config seaweedfs-ab-replication --ignore-not-found

    echo "🗑️  Removing objectstore-local bridge from grafana namespace..."
    kubectl --context "${CONTEXT_NAME}" -n grafana delete service objectstore-local --ignore-not-found
    kubectl --context "${CONTEXT_NAME}" -n grafana delete endpoints objectstore-local --ignore-not-found

    echo "🗑️  Removing Grafana IngressRoute..."
    kubectl --context "${CONTEXT_NAME}" -n grafana delete ingressroute grafana --ignore-not-found

    echo "🗑️  Removing Grafana CRs, datasources, and dashboards..."
    if kubectl --context "${CONTEXT_NAME}" get crd grafanas.grafana.integreatly.org &>/dev/null; then
        # Delete Grafana instance CR (both namespaces — default was used before namespace was set in tpl)
        kubectl --context "${CONTEXT_NAME}" delete grafana grafana -n grafana --ignore-not-found
        kubectl --context "${CONTEXT_NAME}" delete grafana grafana -n default --ignore-not-found
        kubectl kustomize "${GIT_REPO_ROOT}/monitoring/grafana/" | \
            kubectl --context "${CONTEXT_NAME}" delete --ignore-not-found -f -

        # Delete BY KIND, not just what kustomize knows about. Tenant onboarding
        # creates its own Grafana CRs through ArgoCD (loki-rbr-ver,
        # traefik-traces-rbr-ver, ...) which the kustomize delete above never
        # touches, so on a --with-tenant cluster they survive to wedge the
        # namespace below.
        for _kind in grafanadashboards grafanadatasources grafanafolders grafanas; do
            kubectl --context "${CONTEXT_NAME}" -n grafana \
                delete "${_kind}.grafana.integreatly.org" --all --ignore-not-found --timeout=60s || true
        done

        # Every one of these carries operator.grafana.com/finalizer, which ONLY
        # the Grafana Operator clears. Uninstalling the operator while any
        # remain strands them, and `delete namespace grafana` then hangs in
        # Terminating forever. Clear anything still left before the operator
        # goes away.
        for _kind in grafanadashboards grafanadatasources grafanafolders grafanas; do
            for _obj in $(kubectl --context "${CONTEXT_NAME}" -n grafana \
                            get "${_kind}.grafana.integreatly.org" -o name 2>/dev/null); do
                echo "  ⚠️  ${_obj} survived delete — clearing its finalizer"
                kubectl --context "${CONTEXT_NAME}" -n grafana patch "${_obj}" \
                    --type=merge -p '{"metadata":{"finalizers":null}}' >/dev/null 2>&1 || true
            done
        done
    else
        echo "  ℹ️  Grafana CRDs absent — skipping CR delete (namespace deletion will clean up)"
    fi

    echo "🗑️  Uninstalling Grafana Operator in '${K8S_CLUSTER_NAME}'..."
    helm_uninstall_if_present grafana-operator grafana "${CONTEXT_NAME}"

    echo "🗑️  Deleting grafana namespace..."
    kubectl --context "${CONTEXT_NAME}" delete namespace grafana --ignore-not-found

    # --- prometheus-operator namespace: Prometheus CR, RBAC, kube-prometheus-stack ---
    echo "🗑️  Removing Prometheus CR..."
    if kubectl --context "${CONTEXT_NAME}" get crd prometheuses.monitoring.coreos.com &>/dev/null; then
        kubectl --context "${CONTEXT_NAME}" -n prometheus-operator \
            delete prometheus prometheus --ignore-not-found
    fi

    echo "🗑️  Removing Prometheus RBAC resources..."
    kubectl kustomize "${GIT_REPO_ROOT}/monitoring/prometheus-instance" | \
        kubectl --context "${CONTEXT_NAME}" delete --ignore-not-found -f -

    echo "🗑️  Uninstalling kube-prometheus-stack in '${K8S_CLUSTER_NAME}'..."
    helm_uninstall_if_present kube-prometheus-stack prometheus-operator "${CONTEXT_NAME}"

    echo "🗑️  Deleting prometheus-operator namespace..."
    kubectl --context "${CONTEXT_NAME}" delete namespace prometheus-operator --ignore-not-found
done

# --- Hub region only: Tempo and Mimir ---
echo "-------------------------------------------------------------"
echo " 🗑️  Tearing down hub-only components in region: ${HUB_REGION}"
echo "-------------------------------------------------------------"

echo "🗑️  Removing OTel Collector IngressRoute..."
kubectl --context "${HUB_CONTEXT}" -n otel delete ingressroute otel-push --ignore-not-found

echo "🗑️  Uninstalling OTel Collector in '$(get_cluster_name "${HUB_REGION}")'..."
helm_uninstall_if_present otel-collector otel "${HUB_CONTEXT}"

echo "🗑️  Deleting otel namespace..."
kubectl --context "${HUB_CONTEXT}" delete namespace otel --ignore-not-found

echo "🗑️  Uninstalling Tempo in '$(get_cluster_name "${HUB_REGION}")'..."
helm_uninstall_if_present tempo tempo "${HUB_CONTEXT}"

echo "🗑️  Removing objectstore-local bridge from tempo namespace..."
kubectl --context "${HUB_CONTEXT}" -n tempo delete service objectstore-local --ignore-not-found
kubectl --context "${HUB_CONTEXT}" -n tempo delete endpoints objectstore-local --ignore-not-found

echo "🗑️  Deleting tempo namespace..."
kubectl --context "${HUB_CONTEXT}" delete namespace tempo --ignore-not-found

echo "🗑️  Removing Mimir IngressRoute..."
kubectl --context "${HUB_CONTEXT}" -n mimir delete ingressroute mimir-push --ignore-not-found

echo "🗑️  Uninstalling Mimir in '$(get_cluster_name "${HUB_REGION}")'..."
helm_uninstall_if_present mimir mimir "${HUB_CONTEXT}"

echo "🗑️  Removing objectstore-local bridge from mimir namespace..."
kubectl --context "${HUB_CONTEXT}" -n mimir delete service objectstore-local --ignore-not-found
kubectl --context "${HUB_CONTEXT}" -n mimir delete endpoints objectstore-local --ignore-not-found

echo "🗑️  Deleting mimir namespace..."
kubectl --context "${HUB_CONTEXT}" delete namespace mimir --ignore-not-found

# --- Non-hub regions: revert Traefik OTLP tracing re-install ---
if [[ ${#REGIONS[@]} -gt 1 ]]; then
    echo "-------------------------------------------------------------"
    echo " 🔁 Reverting Traefik OTLP tracing on non-hub regions..."
    echo "-------------------------------------------------------------"
    for non_hub_region in "${REGIONS[@]}"; do
        if [[ "${non_hub_region}" != "${HUB_REGION}" ]]; then
            NON_HUB_CTX="$(get_cluster_context "${non_hub_region}")"
            echo "🔁 Restoring Traefik without OTLP tracing in region '${non_hub_region}'..."
            helm_upgrade_install traefik \
                oci://ghcr.io/traefik/helm/traefik \
                traefik "${NON_HUB_CTX}" "${TRAEFIK_CHART_VERSION}" \
                --values "${GIT_REPO_ROOT}/traefik/values.yaml" \
                --set "tracing.otlp.http.enabled=false"
        fi
    done
fi

echo "-------------------------------------------------------------"
echo " ✅ Monitoring teardown complete."
echo "-------------------------------------------------------------"
