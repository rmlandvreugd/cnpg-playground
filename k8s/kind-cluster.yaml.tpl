kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
name: cnpg
networking:
  disableDefaultCNI: true
  podSubnet: "10.244.0.0/16"
# Kubelets request serving certs from the cluster CA (with IP SANs) instead of
# self-signing, so metrics-server can verify kubelet TLS on :10250. The resulting
# kubernetes.io/kubelet-serving CSRs are auto-approved by kubelet-csr-approver
# (the in-tree approver deliberately never approves serving CSRs).
kubeadmConfigPatches:
  - |
    kind: KubeletConfiguration
    apiVersion: kubelet.config.k8s.io/v1beta1
    serverTLSBootstrap: true
nodes:

# Control Plane node
- role: control-plane
  extraMounts:
    - hostPath: ${GIT_REPO_ROOT}/k8s/encryption/secretbox.key
      containerPath: /etc/kubernetes/encryption/secretbox.key
      readOnly: true
    - hostPath: ${GIT_REPO_ROOT}/k8s/authn-config.yaml
      containerPath: /etc/kubernetes/authn-config.yaml
      readOnly: true
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
      apiServer:
        extraArgs:
          encryption-provider-config: /etc/kubernetes/encryption/secretbox.key
          feature-gates: "MutatingAdmissionPolicy=true"
          runtime-config: "admissionregistration.k8s.io/v1beta1=true"
          authentication-config: /etc/kubernetes/authn-config.yaml
        extraVolumes:
          - name: encryption-config
            hostPath: /etc/kubernetes/encryption/secretbox.key
            mountPath: /etc/kubernetes/encryption/secretbox.key
            readOnly: true
            pathType: File
          - name: authn-config
            hostPath: /etc/kubernetes/authn-config.yaml
            mountPath: /etc/kubernetes/authn-config.yaml
            readOnly: true
            pathType: File
    - |
      kind: KubeProxyConfiguration
      metricsBindAddress: 0.0.0.0

# Infrastructure (2) / Application (2) nodes
- role: worker
  labels:
    infra.node.kubernetes.io:
- role: worker
  labels:
    infra.node.kubernetes.io:
# App nodes stay untainted (nodeSelector-only pinning) so platform/monitoring
# overflow can still schedule here; demo-app + connection poolers select them.
- role: worker
  labels:
    app.node.kubernetes.io:
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
