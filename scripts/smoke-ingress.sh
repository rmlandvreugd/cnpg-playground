#!/usr/bin/env bash
#
# Ingress smoke test: every HTTP entry point, tenant and platform.
#
#   scripts/smoke-ingress.sh [region]
#
# Routes are DISCOVERED from the cluster's Traefik IngressRoutes rather than
# hard-coded, so onboarding a tenant or adding a service is picked up without
# editing this script. Edge-only services (they live on the host behind the edge
# Traefik and have no in-cluster IngressRoute) are listed explicitly because
# there is nothing in the cluster to discover them from.
#
# A route is classed as TENANT when its namespace carries the Capsule tenant
# label, or when it is a per-tenant object living in a platform namespace (the
# tenant Grafana and pgAdmin are deployed there). Everything else is PLATFORM.
#
# PASS means Traefik routed the request to a backend that answered. A redirect
# to Authelia (302/303) is a PASS: the route works and the service is protected.
# 404 means Traefik has no such router — the usual symptom of a route that was
# torn down and never recreated. 502/503 means the route exists but the backend
# is down. 000 means the name did not resolve or the connection failed.
#
set -euo pipefail

source "$(git rev-parse --show-toplevel)/scripts/common.sh"

region="${1:-local}"
CONTEXT="$(get_cluster_context "${region}")"
kc() { kubectl --context "${CONTEXT}" "$@"; }

fail=0
pass=0

probe() {  # <class> <host> <path> <what>
    local class="$1" host="$2" path="$3" what="$4" code
    code=$(curl -sk -o /dev/null -w '%{http_code}' --max-time 15 "https://${host}${path}" 2>/dev/null || echo 000)
    # Some backends only serve a PathPrefix WITH a trailing slash and hard-404
    # without one — Traefik's own dashboard does exactly this (/dashboard is a
    # 404, /dashboard/ is a 200), so a bare-prefix probe would report a healthy
    # route as broken. Retry once before believing the 404.
    if [ "${code}" = "404" ] && [ -n "${path}" ] && [ "${path%/}" = "${path}" ]; then
        code=$(curl -sk -o /dev/null -w '%{http_code}' --max-time 15 "https://${host}${path}/" 2>/dev/null || echo 000)
        [ "${code}" != "404" ] && path="${path}/"
    fi
    case "${code}" in
        # 405 is a PASS: Traefik routed the request and the backend answered,
        # it just does not accept GET (radar's /mcp endpoint is POST-only).
        200|201|204|301|302|303|307|308|401|403|405)
            printf '  ✅ %-9s %-46s %s %s\n' "${class}" "${host}${path}" "${code}" "${what}"
            pass=$((pass + 1)) ;;
        *)
            printf '  ❌ %-9s %-46s %s %s\n' "${class}" "${host}${path}" "${code}" "${what}"
            fail=$((fail + 1)) ;;
    esac
}

echo "=== in-cluster IngressRoutes (discovered) ==="
# Capsule namespaces carry capsule.clastix.io/tenant; that is the authoritative
# signal. The tenant's own Grafana/pgAdmin run in PLATFORM namespaces, so fall
# back to a name match for those.
TENANT_NS=$(kc get ns -l capsule.clastix.io/tenant -o jsonpath='{range .items[*]}{.metadata.name}{" "}{end}' 2>/dev/null || true)

while IFS='|' read -r ns name match; do
    [ -z "${ns}" ] && continue
    host=$(printf '%s' "${match}" | sed -n 's/.*Host(`\([^`]*\)`).*/\1/p')
    [ -z "${host}" ] && continue
    # FIRST PathPrefix, if the router demands one (radar, traefik dashboard).
    # grep -o, not sed: a greedy sed grabs the LAST prefix from a router like
    # `PathPrefix(/dashboard) || PathPrefix(/api)`, and bare /api 404s while
    # /dashboard is the real entry point.
    # `|| true`: most routers have no PathPrefix at all, and grep exits 1 on no
    # match, which would abort the whole run under `set -e`.
    path=$(printf '%s' "${match}" | grep -o 'PathPrefix(`[^`]*`)' 2>/dev/null | head -1 \
             | sed 's/PathPrefix(`\(.*\)`)/\1/' || true)
    class=PLATFORM
    case " ${TENANT_NS} " in *" ${ns} "*) class=TENANT ;; esac
    case "${name}" in *-rbr-*|*-rbr) class=TENANT ;; esac
    probe "${class}" "${host}" "${path}" "${ns}/${name}"
done < <(kc get ingressroute -A \
          -o jsonpath='{range .items[*]}{.metadata.namespace}{"|"}{.metadata.name}{"|"}{.spec.routes[0].match}{"\n"}{end}' 2>/dev/null)

echo
echo "=== edge-only services (host containers behind traefik-edge) ==="
EDGE_IP_DASHED="${TRAEFIK_EDGE_IP_DASHED:-172-28-0-250}"
for svc in zot vault authelia; do
    probe EDGE "${svc}.${EDGE_IP_DASHED}.sslip.io" "" "host container"
done
# The edge Traefik serves its own dashboard (traefik-edge/dynamic/dashboard.yaml),
# separate from the in-cluster Traefik dashboard probed above. Same trailing-slash
# quirk applies, and the probe's retry handles it.
probe EDGE "traefik.${EDGE_IP_DASHED}.sslip.io" "/dashboard" "edge Traefik dashboard"

echo
echo "=== summary ==="
echo "  pass=${pass} fail=${fail}"
if [ "${fail}" -gt 0 ]; then
    echo
    echo "  A 404 usually means the IngressRoute is gone rather than broken. Tenant"
    echo "  routes in particular do NOT survive monitoring/teardown.sh, which deletes"
    echo "  the tenant Grafana CRs by kind; re-run demo/self-service-setup.sh."
    exit 1
fi
echo "  All ingresses reachable."
