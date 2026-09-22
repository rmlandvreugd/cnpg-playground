# Loki-B storage: in-cluster SeaweedFS, reconciled by the platform's
# seaweedfs-operator (installed in scripts/setup.sh, bead t9p7.1).
#
# Shape and flag behaviour below were established empirically against the live
# CRD — the operator marks several of these fields
# x-kubernetes-preserve-unknown-fields, so the API server does NOT validate them
# and a wrong shape is silently dropped rather than rejected.
apiVersion: seaweed.seaweedfs.com/v1
kind: Seaweed
metadata:
  name: seaweedfs-ab
  namespace: grafana
spec:
  image: ${SEAWEEDFS_AB_IMAGE}
  volumeServerDiskCount: 1

  # Applied to every component the operator renders (master/volume/filer/s3),
  # so the whole cluster lands on infra nodes alongside the rest of monitoring.
  nodeSelector:
    node-role.kubernetes.io/infra: ""
  tolerations:
    - key: node-role.kubernetes.io/infra
      operator: Exists
      effect: NoSchedule

  master:
    replicas: 1
    # Prometheus metrics. `weed` exposes /metrics only when a metricsPort is set,
    # so leaving these unset means the storage comparison has container CPU/mem
    # but nothing from the store itself.
    metricsPort: 9324
    # Without this the master's topology metadata is ephemeral and every restart
    # re-learns the cluster from scratch.
    persistence:
      enabled: true
      storageClassName: standard
      accessModes: [ReadWriteOnce]
      resources:
        requests:
          storage: 1Gi

  volume:
    replicas: 1
    metricsPort: 9325
    storageClassName: standard
    requests:
      storage: ${SEAWEEDFS_AB_VOLUME_SIZE}

  filer:
    replicas: 1
    metricsPort: 9326
    # REQUIRED for the mirror to be restart-safe, not just for file metadata.
    # filer.backup stores its replication checkpoint ON THE FILER (setOffset over
    # gRPC to the source filer). With an ephemeral filer store that offset dies
    # with the pod, and the sidecar comes back reporting
    #   starting from 1970-01-01 00:00:00 +0000 UTC (no prior checkpoint)
    # then replays the entire metadata log and re-copies everything — which the
    # "resumes from checkpoint without re-copying" requirement forbids.
    persistence:
      enabled: true
      storageClassName: standard
      accessModes: [ReadWriteOnce]
      resources:
        requests:
          storage: 5Gi
    annotations:
      # The mirror sidecar reads credentials and the CA bundle from a Secret and
      # a ConfigMap; without Reloader a rotation leaves it running on stale
      # material until something else restarts the pod.
      reloader.stakater.com/auto: "true"
    volumes:
      - name: replication-config
        secret:
          secretName: seaweedfs-ab-replication
      - name: step-ca-bundle
        configMap:
          name: step-ca-external-bundle
    # Verified against the live operator: this IS a list of corev1.Container and
    # the rendered filer pod comes up with two containers.
    sidecars:
      - name: filer-backup-rustfs
        image: ${SEAWEEDFS_AB_IMAGE}
        # -doDeleteFiles defaults to FALSE; without it the mirror never removes
        # keys, so a Loki compactor retention delete would silently diverge.
        #
        # -initialSnapshot is deliberately NOT here by default. It walks the
        # whole tree and OVERWRITES the saved checkpoint on every start while
        # -timeAgo is 0, so leaving it in would make each restart — including
        # every monitoring/setup.sh re-run — re-copy everything, and the
        # "resumes from checkpoint without re-copying" behaviour could never
        # hold. It is a no-op on a genuinely fresh install anyway, because the
        # source tree is empty at that point.
        #
        # Set SEAWEEDFS_AB_INITIAL_SNAPSHOT=-initialSnapshot for the one case
        # that needs it: re-seeding an emptied mirror from a source that already
        # holds data (the t9p7.3 restore drill). Its default is the explicit
        # no-op `-debug=false` (that IS the flag's default) rather than an empty
        # string, because envsubst would otherwise leave a null YAML list item
        # and hand weed an empty argument.
        #
        # The wait loop is load-bearing, not defensive padding. This container
        # starts at the same time as the filer container beside it, and
        # filer.backup reads its saved offset over gRPC (filer port + 10000)
        # exactly once at startup. If the filer is not listening yet that read
        # fails SOFTLY and the backup silently restarts from epoch:
        #   starting from 1970-01-01 ... (offset read failed: ... :18888:
        #   connect: connection refused)
        # which re-copies the whole tree on every restart.
        command:
          - /bin/sh
          - -ec
          - |
            until nc -z localhost 18888; do
              echo "waiting for filer gRPC on :18888 before reading backup offset"
              sleep 2
            done
            exec weed filer.backup \
              -filer=localhost:8888 \
              -filerPath=/buckets/loki \
              -doDeleteFiles=true \
              ${SEAWEEDFS_AB_INITIAL_SNAPSHOT}
        env:
          # weed's S3 sink builds its client with aws-sdk-go v1
          # session.NewSession() and passes no custom HTTPClient, so the SDK's
          # env-config path picks this up to trust the step-ca chain that signed
          # the RustFS endpoint.
          - name: AWS_CA_BUNDLE
            value: /etc/ssl/step-ca/ca-certificates.crt
        volumeMounts:
          # weed finds replication.toml by scanning /etc/seaweedfs; mounting the
          # whole directory is safe here because this is the sidecar, not the
          # filer container.
          - name: replication-config
            mountPath: /etc/seaweedfs
            readOnly: true
          - name: step-ca-bundle
            mountPath: /etc/ssl/step-ca
            readOnly: true

  s3:
    replicas: 1
    metricsPort: 9327
    # The operator renders `weed s3 -port=<this>`, so HTTP must move off 8333 to
    # leave it free for the TLS listener below.
    port: 8334
    configSecret:
      name: seaweedfs-ab-s3-config
      # `key` is mandatory (the operator's validating webhook rejects the CR
      # without it) AND it becomes the filename: the operator mounts the secret
      # at /etc/sw and appends -config=/etc/sw/<key>.
      key: seaweedfs_s3_config
    # NOT the s3.-prefixed spelling. Those exist only on `weed server`, where s3
    # is one sub-service among many; the operator runs the standalone `weed s3`
    # command, whose equivalents are unprefixed. Using -s3.port.https here makes
    # the gateway exit immediately with
    #   flag provided but not defined: -s3.port.https
    extraArgs:
      - -port.https=8333
      - -cert.file=/etc/seaweedfs/tls/tls.crt
      - -key.file=/etc/seaweedfs/tls/tls.key
    volumes:
      - name: s3-tls
        secret:
          secretName: seaweedfs-ab-s3-tls
    volumeMounts:
      - name: s3-tls
        mountPath: /etc/seaweedfs/tls
        readOnly: true
