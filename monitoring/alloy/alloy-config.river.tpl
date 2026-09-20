// Discover all CNPG pods across all namespaces
discovery.kubernetes "cnpg_pods" {
  role = "pod"
  attach_metadata {
    namespace = true
  }
  selectors {
    role  = "pod"
    label = "cnpg.io/cluster"
  }
}

// Relabel pod metadata into Loki stream labels
discovery.relabel "cnpg_pods" {
  targets = discovery.kubernetes.cnpg_pods.targets

  // Loki tenant (X-Scope-OrgID): the source namespace's Capsule tenant, else "platform".
  rule {
    target_label = "tenant"
    replacement  = "platform"
  }
  rule {
    source_labels = ["__meta_kubernetes_namespace_label_capsule_clastix_io_tenant"]
    regex         = "(.+)"
    target_label  = "tenant"
  }
  rule {
    source_labels = ["__meta_kubernetes_namespace"]
    target_label  = "namespace"
  }
  rule {
    source_labels = ["__meta_kubernetes_pod_name"]
    target_label  = "pod"
  }
  rule {
    source_labels = ["__meta_kubernetes_pod_label_cnpg_io_cluster"]
    target_label  = "cluster"
  }
  rule {
    source_labels = ["__meta_kubernetes_pod_label_role"]
    target_label  = "role"
  }
}

// Tail pod logs via Kubernetes API
loki.source.kubernetes "cnpg_logs" {
  targets    = discovery.relabel.cnpg_pods.output
  forward_to = [loki.process.pgaudit.receiver]
}

// Extract pgaudit fields from matching log lines; non-matching lines pass through unlabeled
loki.process "pgaudit" {
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

  forward_to = [loki.process.tenant.receiver]
}

// Every pipeline ends here: the "tenant" label becomes the X-Scope-OrgID.
loki.process "tenant" {
  stage.tenant {
    label = "tenant"
  }
  forward_to = [loki.write.grafana_loki.receiver]
}

// Push logs to in-cluster Loki
loki.write "grafana_loki" {
  endpoint {
    url = "http://loki.grafana.svc.cluster.local:3100/loki/api/v1/push"
  }
}

// === Cluster-wide pod logs (system + workload) ===
discovery.kubernetes "all_pods" {
  role = "pod"
  attach_metadata {
    namespace = true
  }
}

discovery.relabel "all_pods" {
  targets = discovery.kubernetes.all_pods.targets

  // Loki tenant (X-Scope-OrgID): the source namespace's Capsule tenant, else "platform".
  rule {
    target_label = "tenant"
    replacement  = "platform"
  }
  rule {
    source_labels = ["__meta_kubernetes_namespace_label_capsule_clastix_io_tenant"]
    regex         = "(.+)"
    target_label  = "tenant"
  }
  rule {
    source_labels = ["__meta_kubernetes_namespace"]
    target_label  = "namespace"
  }
  rule {
    source_labels = ["__meta_kubernetes_pod_name"]
    target_label  = "pod"
  }
  rule {
    source_labels = ["__meta_kubernetes_pod_container_name"]
    target_label  = "container"
  }
  rule {
    source_labels = ["__meta_kubernetes_pod_node_name"]
    target_label  = "node"
  }
  rule {
    source_labels = ["__meta_kubernetes_pod_label_app_kubernetes_io_name"]
    target_label  = "app"
  }
  // Drop CNPG pods here — they are already shipped via cnpg_logs → pgaudit pipeline
  rule {
    source_labels = ["__meta_kubernetes_pod_label_cnpg_io_cluster"]
    action        = "drop"
    regex         = ".+"
  }
  // Drop Traefik pods — shipped via traefik_access pipeline below
  rule {
    source_labels = ["__meta_kubernetes_pod_label_app_kubernetes_io_name"]
    action        = "drop"
    regex         = "traefik"
  }
}

loki.source.kubernetes "system_logs" {
  targets    = discovery.relabel.all_pods.output
  forward_to = [loki.process.tenant.receiver]
}

// === Traefik access-log branch ===
discovery.relabel "traefik_pods" {
  targets = discovery.kubernetes.all_pods.targets

  // Loki tenant (X-Scope-OrgID): the source namespace's Capsule tenant, else "platform".
  rule {
    target_label = "tenant"
    replacement  = "platform"
  }
  rule {
    source_labels = ["__meta_kubernetes_namespace_label_capsule_clastix_io_tenant"]
    regex         = "(.+)"
    target_label  = "tenant"
  }
  rule {
    source_labels = ["__meta_kubernetes_pod_label_app_kubernetes_io_name"]
    regex         = "traefik"
    action        = "keep"
  }
  rule {
    source_labels = ["__meta_kubernetes_namespace"]
    target_label  = "namespace"
  }
  rule {
    source_labels = ["__meta_kubernetes_pod_name"]
    target_label  = "pod"
  }
  rule {
    target_label = "app"
    replacement  = "traefik"
  }
}

loki.source.kubernetes "traefik_access" {
  targets    = discovery.relabel.traefik_pods.output
  forward_to = [loki.process.traefik_access.receiver]
}

loki.process "traefik_access" {
  // Non-JSON lines (Traefik runtime logs) pass through unmodified
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

  // Tenant attribution (bd3d.10). The Traefik pod lives in the platform namespace, so the
  // only per-request signal is the router/service name, which Traefik renders as
  // "<namespace>-<ingressroute>-<hash>@kubernetescrd". Capsule forces the tenant prefix on
  // its namespaces, so an ANCHORED match identifies the tenant. Anchoring matters: the
  // tenant's own Grafana is "grafana-grafana-rbr-ver-..." in the platform namespace and
  // must stay platform. Tenants are listed explicitly rather than captured with a generic
  // prefix, so a platform namespace can never mint a Loki tenant (bd3d.7 will generate
  // this list from the Capsule Tenants).
  // No match (platform routers, and Traefik's own runtime lines) extracts nothing, and
  // stage.labels only sets labels whose extracted key exists — so those keep the
  // tenant="platform" label that discovery.relabel already put on the Traefik pod.
  // >>> per-tenant: alloy-traefik-tenant (generated, see scripts/render-tenant-telemetry.py)
  // <<< per-tenant

  // Promote low-cardinality fields to Loki labels
  stage.labels {
    values = {
      method = "method",
      status = "status",
      route  = "route",
      tenant = "tenant_from_service",
    }
  }

  forward_to = [loki.process.tenant.receiver]
}

// === Kubernetes events ===
loki.source.kubernetes_events "k8s_events" {
  job_name   = "k8s-events"
  log_format = "logfmt"
  forward_to = [loki.process.events.receiver]
}

loki.process "events" {
  // loki.source.kubernetes_events already labels each entry with the involved object's
  // namespace, so the Capsule tenant comes from an anchored namespace match — the same rule
  // the pod-log and Traefik pipelines use (bd3d.5). Everything else stays platform, so
  // cluster-scoped and platform-namespace events never reach a tenant.
  stage.static_labels {
    values = { tenant = "platform" }
  }
  // >>> per-tenant: alloy-events-tenant (generated, see scripts/render-tenant-telemetry.py)
  // <<< per-tenant

  // The event body is logfmt; promote the low-cardinality fields to labels.
  stage.logfmt {
    mapping = {
      "reason" = "",
      "type"   = "",
      "kind"   = "",
    }
  }
  stage.labels {
    values = {
      "reason" = "reason",
      "type"   = "type",
      "kind"   = "kind",
    }
  }
  forward_to = [loki.process.tenant.receiver]
}
