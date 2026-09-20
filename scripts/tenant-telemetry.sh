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
        "${GIT_REPO_ROOT}/monitoring/alloy/alloy-config.river.tpl" \
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

    # otel-collector + Alloy carry their tenant routing in helm values.
    helm_upgrade_install otel-collector \
        oci://ghcr.io/open-telemetry/opentelemetry-helm-charts/opentelemetry-collector \
        otel "${CONTEXT}" "${OTEL_COLLECTOR_CHART_VERSION}" \
        --values "${RENDER_DIR}/otel-collector-values.yaml" \
        --set "image.tag=${OTEL_COLLECTOR_IMAGE_TAG}"

    helm_upgrade_install alloy alloy \
        grafana "${CONTEXT}" "${ALLOY_CHART_VERSION}" \
        --repo-url https://grafana.github.io/helm-charts \
        --values "${GIT_REPO_ROOT}/monitoring/alloy/alloy-values.yaml" \
        --set-file "alloy.configMap.content=${RENDER_DIR}/alloy-config.river"

    echo "✅ Per-tenant telemetry routing applied."
}

case "${mode}" in
    render) render ;;
    apply) apply ;;
    *) sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac
