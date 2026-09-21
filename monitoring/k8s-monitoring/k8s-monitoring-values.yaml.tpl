# grafana/k8s-monitoring 4.5.2 — replaces the hand-written Alloy release
# (monitoring/alloy/alloy-config.river.tpl) and fans every log line out to all
# three Loki storage arms of the A/B/C PoC.
#
# TENANT ISOLATION IS LOAD-BEARING HERE. The release this replaces carried all
# per-tenant log routing from beads bd3d.1/.5/.10. Two rules keep it working:
#
#   1. NO `tenantId` on any destination. Setting it renders a STATIC
#      `tenant_id` into loki.write, which would slam every line — platform and
#      tenant alike — into one Loki org. Per-line routing comes from
#      `stage.tenant`, which sets __tenant_id__ per entry and overrides the
#      endpoint default.
#   2. `attachNamespaceMetadata: true` below. Without it the Capsule namespace
#      label is not exposed to discovery, every line silently falls back to
#      tenant="platform", and isolation regresses with NO error anywhere.
#
# Rendered by scripts/render-tenant-telemetry.py, which fills the
# `>>> per-tenant` regions from the live Capsule Tenant objects.
---
cluster:
  name: ${K8S_CLUSTER_NAME}

# All three arms receive identical copies. The PoC compares object stores, so
# the write path must be byte-for-byte the same into each.
destinations:
  loki:
    type: loki
    url: http://loki.grafana.svc.cluster.local:3100/loki/api/v1/push
    # tenantId deliberately unset — see header.
    # Default clusterLabels is [cluster, k8s.cluster.name]; `cluster` would
    # collide with the CNPG cluster label that the pgaudit dashboards filter on.
    clusterLabels: [k8s.cluster.name]
    batchSize: 1MiB
    batchWait: 2s
    writeAheadLog:
      enabled: true
  lokiRustfs:
    type: loki
    url: http://loki-rustfs.grafana.svc.cluster.local:3100/loki/api/v1/push
    clusterLabels: [k8s.cluster.name]
    batchSize: 1MiB
    batchWait: 2s
    writeAheadLog:
      enabled: true
  lokiSeaweedfs:
    type: loki
    url: http://loki-seaweedfs.grafana.svc.cluster.local:3100/loki/api/v1/push
    clusterLabels: [k8s.cluster.name]
    batchSize: 1MiB
    batchWait: 2s
    writeAheadLog:
      enabled: true

podLogsViaLoki:
  enabled: true
  # Features must name their collector explicitly in 4.x.
  collector: alloy-logs
  # REQUIRED for tenant isolation — exposes
  # __meta_kubernetes_namespace_label_capsule_clastix_io_tenant to discovery.
  attachNamespaceMetadata: true

  # Label shape must match what the existing dashboards query.
  # `app` drives the Traefik stage.match selector below; `cluster` comes from
  # cnpg.io/cluster and is what the pgaudit dashboards filter on (and is also
  # how the pgaudit stages are scoped to CNPG pods only).
  labels:
    app: app.kubernetes.io/name
    cluster: cnpg.io/cluster

  # `pod` moves OUT of structured metadata and stays a real label, because the
  # k8s-pod-logs dashboard (platform) and the ArgoCD-managed tenant pgaudit
  # dashboard both select on pod as a label.
  structuredMetadata:
    k8s.pod.name: k8s.pod.name
    service.instance.id: service.instance.id

  # Sets the tenant label every line is routed by. Mirrors the relabel rules the
  # old alloy config applied in three separate discovery.relabel blocks:
  # default platform, overridden by the source namespace's Capsule tenant.
  extraDiscoveryRules: |-
    rule {
      target_label = "tenant"
      replacement  = "platform"
    }
    rule {
      source_labels = ["__meta_kubernetes_namespace_label_capsule_clastix_io_tenant"]
      regex         = "(.+)"
      target_label  = "tenant"
    }

  # Injected inside loki.process "pod_logs", immediately before the fan-out to
  # all three destinations.
  #
  # EVERY ported stage is wrapped in its own stage.match. The old config had
  # three independent pipelines (cnpg / all_pods / traefik); k8s-monitoring
  # funnels ALL pod logs through this single process block, so without a
  # selector the pgaudit regex would run against Traefik lines and vice versa.
  extraLogProcessingStages: |-
    // --- pgaudit (CNPG pods only; `cluster` is set from cnpg.io/cluster) ---
    stage.match {
      selector = `{cluster=~".+"}`
      stage.regex {
        expression = `AUDIT: (?P<audit_type>[^,]+),(?P<statement_id>[^,]+),(?P<substatement_id>[^,]+),(?P<class>[^,]+),(?P<command>[^,]+),(?P<object_type>[^,]*),(?P<object_name>[^,]*),(?P<statement>.*)`
      }
      stage.labels {
        values = {
          "audit_type" = "audit_type",
          "class"      = "class",
          "command"    = "command",
        }
      }
    }

    // --- Traefik access logs (Traefik pods only) ---
    stage.match {
      selector = `{app="traefik"}`
      // Non-JSON lines (Traefik runtime logs) pass through unmodified.
      stage.json {
        expressions = {
          method   = "RequestMethod",
          status   = "DownstreamStatus",
          host     = "RequestHost",
          route    = "RouterName",
          service  = "ServiceName",
          duration = "Duration",
          trace_id = "traceID",
        }
      }

      // Tenant attribution (bd3d.10). Traefik runs in a platform namespace, so
      // the only per-request signal is the router/service name, which Traefik
      // renders as "<namespace>-<ingressroute>-<hash>@kubernetescrd". Capsule
      // forces the tenant prefix on its namespaces, so an ANCHORED match
      // identifies the tenant. Anchoring matters: the tenant's own Grafana is
      // "grafana-grafana-rbr-ver-..." in a platform namespace and must stay
      // platform. Tenants are listed explicitly rather than captured with a
      // generic prefix, so a platform namespace can never mint a Loki tenant.
      // No match extracts nothing, and stage.labels only sets labels whose
      // extracted key exists — so those keep tenant="platform" from discovery.
      // >>> per-tenant: alloy-traefik-tenant
      // <<< per-tenant

      stage.labels {
        values = {
          method = "method",
          status = "status",
          route  = "route",
          tenant = "tenant_from_service",
        }
      }
    }

    // --- MUST BE LAST: turn the tenant label into Loki's X-Scope-OrgID ---
    // This is the single point that enforces per-tenant isolation for pod logs.
    stage.tenant {
      label = "tenant"
    }

clusterEvents:
  enabled: true
  # Gathered once per cluster, so it rides the singleton, not the DaemonSet.
  collector: alloy-singleton
  # Keep the existing job label so the k8s-events dashboard keeps rendering.
  jobLabel: k8s-events
  logFormat: logfmt
  extraLogProcessingStages: |-
    // loki.source.kubernetes_events labels each entry with the involved
    // object's namespace, so the Capsule tenant comes from an anchored
    // namespace match (bd3d.5). Everything else stays platform, so
    // cluster-scoped and platform-namespace events never reach a tenant.
    stage.static_labels {
      values = { tenant = "platform" }
    }
    // >>> per-tenant: alloy-events-tenant
    // <<< per-tenant

    // MUST BE LAST — same reason as the pod-logs block.
    stage.tenant {
      label = "tenant"
    }

nodeLogs:
  enabled: true
  collector: alloy-logs
  # REQUIRED. Loki runs with auth_enabled, so every write needs an X-Scope-OrgID.
  # Pod logs and cluster events get theirs from their own tenant stages; without
  # the same here the journal pipeline sends tenant="" and Loki rejects EVERY
  # batch with:
  #   status=401 ... error="server returned HTTP status 401 Unauthorized: no org id"
  # The collection side works fine, so this fails as silent data loss: journal
  # logs simply never appear, with the only evidence in the collector's own log.
  #
  # Node/journal logs are node-scoped, never tenant-scoped, so they are always
  # platform.
  extraLogProcessingStages: |-
    stage.static_labels {
      values = { tenant = "platform" }
    }
    stage.tenant {
      label = "tenant"
    }
  journal:
    # The kind node image has no /var/log/journal, so journald is volatile and
    # only /run/log/journal exists. Note this also SKIPS the chart's
    # varlog-mount validation (it only fires for a /var/log prefix), which is
    # why alloy-logs below mounts /run/log/journal explicitly.
    path: /run/log/journal

collectors:
  alloy-logs:
    enabled: true
    # daemonset: pod logs are read from each node's filesystem, not the API.
    # filesystem-log-reader: mounts /var/log for the container log files.
    presets: [filesystem-log-reader, daemonset]
    alloy:
      mounts:
        extra:
          - name: runlogjournal
            mountPath: /run/log/journal
            readOnly: true
    controller:
      # No nodeSelector/tolerations: this is a DaemonSet and must run on EVERY
      # node to collect that node's pod and journal logs — including the
      # tainted infra and postgres nodes. Pinning it to infra would silently
      # lose all logs from app and postgres nodes.
      tolerations:
        - operator: Exists
      # `volumes.extra`, NOT `extraVolumes`. The Alloy CRD accepts the wrong key
      # without complaint and the embedded alloy chart then ignores it, so the
      # volumeMount above is rendered while its volume is not, and the operator
      # fails the DaemonSet with:
      #   volumeMounts[3].name: Not found: "runlogjournal"
      volumes:
        extra:
          - name: runlogjournal
            hostPath:
              path: /run/log/journal

  alloy-singleton:
    enabled: true
    # Cluster events are gathered once per cluster, not per node. The collector
    # defaults to a DaemonSet, which with two infra nodes means TWO
    # loki.source.kubernetes_events readers and every event ingested twice —
    # so pin it to a single-replica Deployment explicitly. The `singleton`
    # preset does NOT do this; it only steers self-reporting.
    controller:
      type: deployment
      replicas: 1
      nodeSelector:
        node-role.kubernetes.io/infra: ""
      tolerations:
        - key: node-role.kubernetes.io/infra
          operator: Exists
          effect: NoSchedule

alloy-operator:
  enabled: true
