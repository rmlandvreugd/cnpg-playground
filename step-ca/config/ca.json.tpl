{
  "root": "/home/step/certs/root_ca.crt",
  "federatedRoots": [],
  "crt": "/home/step/certs/intermediate_ca.crt",
  "key": "/home/step/secrets/intermediate_ca_key",
  "address": ":${STEP_CA_PORT}",
  "dnsNames": ["${STEP_CA_DNS_NAME}", "localhost", "step-ca"],
  "logger": {"format": "text"},
  "db": {
    "type": "badgerv2",
    "dataSource": "/home/step/db"
  },
  "authority": {
    "provisioners": []
  },
  "tls": {
    "cipherSuites": [
      "TLS_ECDHE_ECDSA_WITH_CHACHA20_POLY1305_SHA256",
      "TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256"
    ],
    "minVersion": 1.2,
    "maxVersion": 1.3
  },
  "crl": {
    "enabled": true,
    "generateOnRevoke": true,
    "cacheDuration": "24h",
    "renewPeriod": "16h"
  }
}
