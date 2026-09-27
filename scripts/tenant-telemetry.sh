#!/usr/bin/env bash
# Render and apply the per-tenant telemetry routing for every Capsule Tenant (bead bd3d.7).
#
#   scripts/tenant-telemetry.sh apply  [region]   # render from the live Tenants and apply
#   scripts/tenant-telemetry.sh render [region]   # render only, print the output directory
#
# No platform file names a tenant: each template carries a ">>> per-tenant" marker that
# scripts/render-tenant-telemetry.py fills from the Capsule Tenant objects. Run this after
# onboarding or removing a tenant — monitoring/setup.sh and demo/self-service-setup.sh do.
#
# Covers: Prometheus remoteWrite (Mimir org per tenant), the platform Grafana datasource
# X-Scope-OrgID headers, the otel-collector trace routing, the Alloy log pipelines and the
# Traefik metrics ServiceMonitor.
set -euo pipefail

source "$(git rev-parse --show-toplevel)/scripts/common.sh"

mode="${1:-apply}"
region="${2:-local}"
CONTEXT="$(get_cluster_context "${region}")"
RENDER_DIR="${GIT_REPO_ROOT}/k8s/rendered/tenant-telemetry"
RENDER="${GIT_REPO_ROOT}/scripts/render-tenant-telemetry.py"
MIMIR_PUSH_URL="${MIMIR_PUSH_URL:-http://mimir-gateway.mimir.svc.cluster.local/api/v1/push}"
TEMPO_OTLP="${TEMPO_OTLP:-tempo-distributor.tempo.svc.cluster.local:4317}"
kc() { kubectl --context "${CONTEXT}" "$@"; }

render() {
    rm -rf "${RENDER_DIR}"
    # --arg carries the one value a block needs (push URL / OTLP endpoint).
    python3 "${RENDER}" --tenants-from-cluster --context "${CONTEXT}" \
        --out-dir "${RENDER_DIR}" --arg "${MIMIR_PUSH_URL}" \
        "${GIT_REPO_ROOT}/monitoring/prometheus-instance/prometheus-cr.yaml.tpl" >/dev/null
    python3 "${RENDER}" --tenants-from-cluster --context "${CONTEXT}" \
        --out-dir "${RENDER_DIR}" --arg "${TEMPO_OTLP}" \
        "${GIT_REPO_ROOT}/monitoring/otel-collector/otel-collector-values.yaml.tpl" >/dev/null
    python3 "${RENDER}" --tenants-from-cluster --context "${CONTEXT}" \
        --out-dir "${RENDER_DIR}" \
        "${GIT_REPO_ROOT}/monitoring/k8s-monitoring/k8s-monitoring-values.yaml.tpl" \
        "${GIT_REPO_ROOT}/monitoring/platform/traefik-servicemonitor.yaml.tpl" \
        "${GIT_REPO_ROOT}/monitoring/grafana/grafana_datasource_loki.yaml.tpl" \
        "${GIT_REPO_ROOT}/monitoring/grafana/grafana_datasource_tempo.yaml.tpl" \
        "${GIT_REPO_ROOT}/monitoring/grafana/grafana_datasource_mimir_tempo.yaml.tpl" >/dev/null
    echo "${RENDER_DIR}"
}

apply() {
    echo "🏷️  Rendering per-tenant telemetry routing from the Capsule Tenants..."
    render >/dev/null

    # Grafana datasources (platform view: platform + every tenant org).
    kc apply -f "${RENDER_DIR}/grafana_datasource_loki.yaml" \
             -f "${RENDER_DIR}/grafana_datasource_tempo.yaml" \
             -f "${RENDER_DIR}/grafana_datasource_mimir_tempo.yaml"

    # Traefik metrics ServiceMonitor (kept out of the chart, see traefik/values.yaml).
    if kc get ns traefik >/dev/null 2>&1; then
        kc apply -f "${RENDER_DIR}/traefik-servicemonitor.yaml"
        # Upgrade path: the chart used to render its own ServiceMonitor named "traefik".
        # A fresh install no longer does (serviceMonitor.enabled=false), but on an existing
        # cluster it lingers and Prometheus scrapes Traefik twice — same series under two
        # job labels, and the stale copy has no tenant relabelings.
        if kc get servicemonitor traefik -n traefik \
            -o jsonpath='{.metadata.annotations.meta\.helm\.sh/release-name}' 2>/dev/null \
            | grep -q '^traefik$'; then
            echo "🧹 Removing the chart-managed Traefik ServiceMonitor (superseded)..."
            kc delete servicemonitor traefik -n traefik --ignore-not-found
        fi
    fi

    # Prometheus CR: the tenant blocks are rendered, REGION/MIMIR_PUSH_URL still envsubst.
    REGION="${region}" MIMIR_PUSH_URL="${MIMIR_PUSH_URL}" \
        envsubst '${REGION} ${MIMIR_PUSH_URL}' < "${RENDER_DIR}/prometheus-cr.yaml" \
        | kc apply --force-conflicts --server-side -f -

    # otel-collector + k8s-monitoring carry their tenant routing in helm values.
    helm_upgrade_install otel-collector \
        oci://ghcr.io/open-telemetry/opentelemetry-helm-charts/opentelemetry-collector \
        otel "${CONTEXT}" "${OTEL_COLLECTOR_CHART_VERSION}" \
        --values "${RENDER_DIR}/otel-collector-values.yaml" \
        --set "image.tag=${OTEL_COLLECTOR_IMAGE_TAG}"

    # k8s-monitoring replaced the hand-written 'alloy' release (bead t9p7.2). Its
    # podLogsViaLoki/clusterEvents extraLogProcessingStages are where per-tenant
    # log routing lives now, so onboarding a tenant MUST re-render and upgrade
    # this release — otherwise the new tenant's lines keep going to 'platform'.
    K8S_CLUSTER_NAME="$(get_cluster_name "${region}")" envsubst '${K8S_CLUSTER_NAME}' \
        < "${RENDER_DIR}/k8s-monitoring-values.yaml" \
        > "${RENDER_DIR}/k8s-monitoring-values.rendered.yaml"
    helm_upgrade_install k8s-monitoring k8s-monitoring \
        grafana "${CONTEXT}" "${K8S_MONITORING_CHART_VERSION}" \
        --repo-url https://grafana.github.io/helm-charts \
        --values "${RENDER_DIR}/k8s-monitoring-values.rendered.yaml"

    wait_events_routing_live

    echo "✅ Per-tenant telemetry routing applied."
}

# Block until the Kubernetes-event collector has LOADED the per-tenant event routing, not
# merely been told about it (bead tvdd). `helm --wait` returns once the alloy-operator's
# Alloy resources are accepted; the operator then rewrites the ConfigMap, the kubelet
# refreshes the mounted file (up to ~1 min) and a config-reloader sidecar triggers the
# reload. Events emitted in that window - onboarding creates the CNPG cluster right then -
# were stored under tenant "platform". No pod restart: Alloy reports the SHA-256 of the
# config it actually loaded (alloy_config_hash), which equals the ConfigMap content's hash.
wait_events_routing_live() {
    local cm=k8s-monitoring-alloy-singleton
    local selector="app.kubernetes.io/instance=k8s-monitoring-alloy-singleton"
    local timeout="${EVENTS_ROUTING_TIMEOUT:-240}" deadline tenants t content hash pod pods pending metrics

    tenants=$(kc get tenants.capsule.clastix.io \
        -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null)
    [ -z "${tenants}" ] && return 0   # no tenant: everything is platform, nothing to wait for

    echo "⏳ Waiting for the event collector to load the per-tenant routing..."
    deadline=$(( $(date +%s) + timeout ))
    # Hash the ConfigMap's exact bytes: capturing it with $(...) would strip its trailing
    # newline, and the SHA-256 would never match the one Alloy computes from the file.
    content=$(mktemp)

    # 1. The operator has reconciled the new routing into the collector's ConfigMap.
    while :; do
        kc get configmap "${cm}" -n grafana -o jsonpath='{.data.config\.alloy}' \
            > "${content}" 2>/dev/null
        pending=""
        for t in ${tenants}; do
            grep -qF "namespace=~\"${t}-.+\"" "${content}" || pending="${pending} ${t}"
        done
        [ -z "${pending}" ] && break
        if [ "$(date +%s)" -ge "${deadline}" ]; then
            echo "❌ ConfigMap ${cm} has no event routing for:${pending} after ${timeout}s" >&2
            rm -f "${content}"
            return 1
        fi
        sleep 3
    done
    hash=$(sha256sum < "${content}" | cut -c1-64)
    rm -f "${content}"

    # 2. Every event-collector pod has loaded exactly that config, successfully.
    while :; do
        pending=""
        pods=$(kc get pods -n grafana -l "${selector}" \
            -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')
        for pod in ${pods}; do
            metrics=$(kc get --raw "/api/v1/namespaces/grafana/pods/${pod}:12345/proxy/metrics" 2>/dev/null)
            if ! grep -q "^alloy_config_hash{.*sha256=\"${hash}\".*} 1" <<<"${metrics}" \
                || ! grep -q '^alloy_config_last_load_successful 1' <<<"${metrics}"; then
                pending="${pending} ${pod}"
            fi
        done
        [ -n "${pods}" ] && [ -z "${pending}" ] && break
        if [ "$(date +%s)" -ge "${deadline}" ]; then
            echo "❌ Event collector did not load the per-tenant routing within ${timeout}s:${pending:- (no pods)}" >&2
            return 1
        fi
        sleep 3
    done
    echo "✅ Event collector is routing events for: $(tr '\n' ' ' <<<"${tenants}")"
}

case "${mode}" in
    render) render ;;
    apply) apply ;;
    *) sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac
