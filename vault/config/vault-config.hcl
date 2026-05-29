storage "file" {
  path = "/vault/data"
}

cluster_addr = "https://127.0.0.1:8201"

disable_mlock = true

log_level = "info"
log_file  = "/vault/logs/vault.log"

# TLS listener — cert issued by step-ca
listener "tcp" {
  address       = "0.0.0.0:8200"
  tls_cert_file = "/vault/certs/vault.crt"
  tls_key_file  = "/vault/certs/vault.key"
  tls_client_ca_file = "/vault/certs/vault-ca.pem"
}

# Plain HTTP listener — bootstrap fallback only
listener "tcp" {
  address     = "0.0.0.0:8202"
  tls_disable = 1
}
