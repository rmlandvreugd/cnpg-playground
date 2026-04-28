storage "file" {
  path = "/vault/data"
}

disable_mlock = true

log_level = "info"
log_file  = "/vault/logs/vault.log"

listener "tcp" {
  address     = "0.0.0.0:8201"
  tls_disable = 1
}
