storage "file" {
  path = "/vault/data"
}

# Primary TLS listener — cert issued by step-ca
listener "tcp" {
  address       = "0.0.0.0:8200"
  tls_cert_file = "/vault/certs/vault-cert.pem"
  tls_key_file  = "/vault/certs/vault-key.pem"
}

# Plain HTTP listener — bootstrap fallback only
listener "tcp" {
  address     = "0.0.0.0:8202"
  tls_disable = 1
}

api_addr     = "https://0.0.0.0:8200"
cluster_addr = "https://0.0.0.0:8201"

disable_mlock = true

log_level = "debug"
log_file  = "/vault/logs/vault.log"

ui = true
