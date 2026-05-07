kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
name: cnpg
nodes:

# Control Plane node
- role: control-plane
  kubeadmConfigPatches:
    - |
      kind: ClusterConfiguration
      controllerManager:
        extraArgs:
          bind-address: 0.0.0.0
      scheduler:
        extraArgs:
          bind-address: 0.0.0.0
      etcd:
        local:
          extraArgs:
            listen-metrics-urls: http://0.0.0.0:2381
    - |
      kind: KubeProxyConfiguration
      metricsBindAddress: 0.0.0.0

# Infrastructure/Application nodes (3)
- role: worker
  labels:
    infra.node.kubernetes.io:
- role: worker
  labels:
    infra.node.kubernetes.io:
- role: worker
  labels:
    app.node.kubernetes.io:

# PostgreSQL nodes (3)
- role: worker
  labels:
    postgres.node.kubernetes.io:
  kubeadmConfigPatches:
  - |
    kind: JoinConfiguration
    nodeRegistration:
      taints:
      - key: node-role.kubernetes.io/postgres
        effect: NoSchedule
- role: worker
  labels:
    postgres.node.kubernetes.io:
  kubeadmConfigPatches:
  - |
    kind: JoinConfiguration
    nodeRegistration:
      taints:
      - key: node-role.kubernetes.io/postgres
        effect: NoSchedule
- role: worker
  labels:
    postgres.node.kubernetes.io:
  kubeadmConfigPatches:
  - |
    kind: JoinConfiguration
    nodeRegistration:
      taints:
      - key: node-role.kubernetes.io/postgres
        effect: NoSchedule
