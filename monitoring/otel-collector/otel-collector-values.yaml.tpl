# OTel Collector contrib — tail-based sampling gateway for Tempo.
# Single replica: all spans for a trace must land on same instance.

mode: deployment
replicaCount: 1

image:
  repository: otel/opentelemetry-collector-contrib
  # tag pinned via OTEL_COLLECTOR_IMAGE_TAG in scripts/common.sh

# Chart >=0.110 requires explicit command name when image.repository diverges
# from the default. contrib binary is `otelcol-contrib`.
command:
  name: otelcol-contrib

config:
  receivers:
    otlp:
      protocols:
        grpc:
          endpoint: 0.0.0.0:4317
          tls:
            cert_file: /etc/otel/tls/tls.crt
            key_file: /etc/otel/tls/tls.key
            client_ca_file: /etc/otel/step-ca/ca-certificates.crt
        http:
          endpoint: 0.0.0.0:4318
    # In-cluster workloads (e.g. tenant demo-app): plaintext gRPC. :4317 stays mTLS for
    # traefik-edge and spokes, which in-cluster SDKs have no client certificate for.
    otlp/cluster:
      protocols:
        grpc:
          endpoint: 0.0.0.0:4319

  processors:
    # Tag spans with the source pod's namespace and its Capsule tenant (namespace label
    # capsule.clastix.io/tenant); the per-org trace filters below pick the Tempo org from it.
    k8s_attributes:
      extract:
        metadata:
          - k8s.namespace.name
          - k8s.pod.name
        labels:
          - tag_name: capsule.tenant
            key: capsule.clastix.io/tenant
            from: namespace
      pod_association:
        - sources:
            - from: connection

    memory_limiter:
      check_interval: 1s
      limit_percentage: 75
      spike_limit_percentage: 25

    # THE sampling decision - made once, for the whole trace, before the org split below.
    tail_sampling:
      decision_wait: 10s         # buffer window; tune up if Traefik spans arrive late
      num_traces: 1000           # circular buffer; sized as ~tps * decision_wait * 10x safety
      expected_new_traces_per_sec: 10
      policies:
        - name: errors-policy
          type: status_code
          status_code:
            status_codes: [ERROR]
        - name: slow-traces-policy
          type: latency
          latency:
            threshold_ms: 500
        - name: probabilistic-sample-policy
          type: probabilistic
          probabilistic:
            sampling_percentage: 10   # keep 10% of healthy fast traces

    batch:
      send_batch_size: 1000      # low-traffic playground; full batch unlikely
      timeout: 5s                # snappier flush for live dashboards

    # Tempo runs multi-tenant and tenancy belongs to the REQUEST, not the span: Traefik's
    # entrypoint, middleware and ReverseProxy spans carry no tenant attribute, yet sit
    # between the tenant's Router/Service spans and its app's spans (bead bd3d.9). So every
    # sampled trace is fanned out to one pipeline per org, and each org keeps or drops the
    # WHOLE trace with a second tail_sampling used as a pure 100% filter - never
    # probabilistic, or two samplers could disagree about the same trace:
    #   tail_sampling/<tenant>  keeps a trace if ANY span is the tenant's (source namespace
    #                           tenant, or a Traefik router/service anchored at "<tenant>-");
    #   tail_sampling/platform  keeps every trace that no tenant claims.
    # The upstream sampler releases a trace's spans together, so a short decision_wait is
    # enough; the decision cache sends late spans after the trace they belong to.
    # >>> per-tenant: otel-org-filters (generated, see scripts/render-tenant-telemetry.py)
    # <<< per-tenant

  connectors:
    # Fan-out: every pipeline that receives from forward/orgs gets a copy of every trace.
    forward/orgs: {}

  exporters:
    otlp/platform:
      endpoint: tempo-distributor.tempo.svc.cluster.local:4317
      headers:
        X-Scope-OrgID: platform
      tls:
        insecure: true
    # >>> per-tenant: otel-exporters (generated, see scripts/render-tenant-telemetry.py)
    # <<< per-tenant
    otlphttp/logs:
      endpoint: http://loki.grafana.svc.cluster.local:3100/otlp
      # Loki runs with auth_enabled; OTLP logs arrive from platform components.
      headers:
        X-Scope-OrgID: platform
      tls:
        insecure: true
    debug:
      verbosity: basic   # remove or set verbosity: detailed for trace debugging

  service:
    pipelines:
      traces:
        receivers: [otlp, otlp/cluster]
        processors: [memory_limiter, k8s_attributes, tail_sampling]
        exporters: [forward/orgs]
      traces/platform:
        receivers: [forward/orgs]
        processors: [tail_sampling/platform, batch]
        exporters: [otlp/platform]
      # >>> per-tenant: otel-pipelines (generated, see scripts/render-tenant-telemetry.py)
      # <<< per-tenant
      logs:
        receivers: [otlp]
        processors: [memory_limiter, batch]
        exporters: [otlphttp/logs]

ports:
  otlp:
    enabled: true
    containerPort: 4317
    servicePort: 4317
  otlp-http:
    enabled: true
    containerPort: 4318
    servicePort: 4318
  otlp-cluster:
    enabled: true
    containerPort: 4319
    servicePort: 4319
    protocol: TCP
    appProtocol: grpc

  # disable unused default ports to reduce surface area
  metrics:
    enabled: false
  jaeger-compact:
    enabled: false
  jaeger-thrift:
    enabled: false
  jaeger-grpc:
    enabled: false
  zipkin:
    enabled: false

# k8s_attributes needs to look up pods (by connection IP) and their namespaces' labels.
clusterRole:
  create: true
  rules:
    - apiGroups: [""]
      resources: [pods, namespaces]
      verbs: [get, list, watch]
    - apiGroups: [apps]
      resources: [replicasets]
      verbs: [get, list, watch]

resources:
  limits:
    memory: 512Mi
    cpu: 500m
  requests:
    memory: 256Mi
    cpu: 100m

nodeSelector:
  node-role.kubernetes.io/infra: ""
tolerations:
  - key: node-role.kubernetes.io/infra
    operator: Exists
    effect: NoSchedule

extraVolumes:
  - name: otlp-tls
    secret:
      secretName: otel-collector-otlp-tls
  - name: step-ca-bundle
    configMap:
      name: step-ca-external-bundle

extraVolumeMounts:
  - name: otlp-tls
    mountPath: /etc/otel/tls
    readOnly: true
  - name: step-ca-bundle
    mountPath: /etc/otel/step-ca
    readOnly: true
