// Discover all CNPG pods across all namespaces
discovery.kubernetes "cnpg_pods" {
  role = "pod"
  selectors {
    role  = "pod"
    label = "cnpg.io/cluster"
  }
}

// Relabel pod metadata into Loki stream labels
discovery.relabel "cnpg_pods" {
  targets = discovery.kubernetes.cnpg_pods.targets

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
}

discovery.relabel "all_pods" {
  targets = discovery.kubernetes.all_pods.targets

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
  forward_to = [loki.write.grafana_loki.receiver]
}

// === Traefik access-log branch ===
discovery.relabel "traefik_pods" {
  targets = discovery.kubernetes.all_pods.targets

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

  // Promote low-cardinality fields to Loki labels
  stage.labels {
    values = {
      method = "method",
      status = "status",
      route  = "route",
    }
  }

  forward_to = [loki.write.grafana_loki.receiver]
}

// === Kubernetes events ===
loki.source.kubernetes_events "k8s_events" {
  job_name   = "k8s-events"
  log_format = "logfmt"
  forward_to = [loki.process.events.receiver]
}

loki.process "events" {
  stage.labels {
    values = {
      "namespace" = "namespace",
      "reason"    = "reason",
      "type"      = "type",
      "kind"      = "kind",
    }
  }
  forward_to = [loki.write.grafana_loki.receiver]
}

// === Metrics: ServiceMonitor + PodMonitor scrape → Mimir remote_write ===
// MIMIR_PUSH_URL and REGION substituted at install time by monitoring/setup.sh envsubst.
prometheus.remote_write "mimir" {
  endpoint {
    url = "${MIMIR_PUSH_URL}"
    headers = {
      "X-Scope-OrgID" = "${REGION}",
    }
    write_relabel_config {
      source_labels = ["__name__"]
      regex         = "(up|scrape_.*|kube_.*|node_.*|kubelet_.*|apiserver_.*|cnpg_.*|pg_.*|traces_.*|process_.*|go_.*)"
      action        = "keep"
    }
    queue_config {
      capacity             = 10000
      max_shards           = 10
      max_samples_per_send = 2000
    }
  }
  external_labels = {
    cluster = "${REGION}",
  }
}

prometheus.operator.servicemonitors "scrape" {
  forward_to = [prometheus.remote_write.mimir.receiver]
}

prometheus.operator.podmonitors "scrape" {
  forward_to = [prometheus.remote_write.mimir.receiver]
}

prometheus.operator.probes "scrape" {
  forward_to = [prometheus.remote_write.mimir.receiver]
}

// === PrometheusRule → Mimir Ruler ===
// MIMIR_RULER_URL substituted at install time by monitoring/setup.sh envsubst.
mimir.rules.kubernetes "rules" {
  address   = "${MIMIR_RULER_URL}"
  tenant_id = "${REGION}"

  rule_selector           = {}
  rule_namespace_selector = {}
}
