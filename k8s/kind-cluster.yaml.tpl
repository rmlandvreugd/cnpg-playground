kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
name: cnpg
nodes:

# Control Plane node
- role: control-plane
  # Authelia CA mounted into control-plane so kube-apiserver can verify the OIDC issuer cert.
  # Path on host is rendered by setup.sh from $AUTHELIA_TLS_DIR (authelia/tls).
  extraMounts:
    - hostPath: ${AUTHELIA_TLS_DIR}/ca-chain.pem
      containerPath: /etc/kubernetes/oidc/oidc-ca.pem
      readOnly: true
  kubeadmConfigPatches:
    - |
      kind: ClusterConfiguration
      apiServer:
        extraArgs:
          # Authelia issuer URL — must be HTTPS and reachable from the control-plane container.
          # ${AUTHELIA_HOST} = authelia.<HOST_IP_DASHED>.sslip.io ; ${AUTHELIA_PORT} = 9091 (default).
          oidc-issuer-url: https://${AUTHELIA_HOST}:${AUTHELIA_PORT}
          oidc-ca-file: /etc/kubernetes/oidc/oidc-ca.pem
          oidc-client-id: kubernetes
          oidc-username-claim: email
          oidc-username-prefix: "oidc:"
          oidc-groups-claim: groups
          oidc-groups-prefix: "oidc:"
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
