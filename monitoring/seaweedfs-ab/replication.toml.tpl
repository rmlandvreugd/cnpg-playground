# Sink config for the seaweedfs-ab filer.backup mirror.
#
# weed loads this as replication.toml via util.LoadConfiguration("replication"),
# which scans /etc/seaweedfs — hence the sidecar mounts this Secret there.
# Key names are taken from S3Sink.Initialize() in
# weed/replication/sink/s3sink/s3_sink.go.
#
# is_incremental=false: the mirror tracks the source, so a delete on the source
# must delete here too (together with -doDeleteFiles=true on the sidecar).
# Setting it true would keep deleted keys forever and break the retention test.
[sink.s3]
enabled = true
aws_access_key_id = "${RUSTFS_LOKI_MIRROR_ACCESS_KEY}"
aws_secret_access_key = "${RUSTFS_LOKI_MIRROR_SECRET_KEY}"
region = "us-east-1"
bucket = "${RUSTFS_LOKI_MIRROR_BUCKET}"
directory = "/"
# Bare host on purpose: the RustFS server cert carries DNS:objectstore-local as
# a SAN, so the FQDN form would fail verification until the cert is reminted.
endpoint = "https://objectstore-local:9000"
s3_force_path_style = true
is_incremental = false
