storage "file" {
  path = "/vault/data"
}

cluster_addr = "https://127.0.0.1:8201"

disable_mlock = true

log_level = "info"
log_file  = "/vault/logs/vault.log"

listener "tcp" {
  address     = "0.0.0.0:8202"
  tls_disable = 1
}
