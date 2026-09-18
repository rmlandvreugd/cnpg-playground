{
  "distSpecVersion": "1.1.1",
  "log": { "level": "info" },
  "storage": {
    "rootDirectory": "/var/lib/zot",
    "dedupe": true,
    "remoteCache": false,
    "gc": true,
    "storageDriver": {
      "name": "s3",
      "rootdirectory": "/zot",
      "region": "us-east-1",
      "bucket": "${SEAWEEDFS_ZOT_BUCKET}",
      "regionendpoint": "http://seaweedfs:8334",
      "forcepathstyle": true,
      "secure": false,
      "skipverify": false,
      "accesskey": "${SEAWEEDFS_ZOT_ACCESS_KEY}",
      "secretkey": "${SEAWEEDFS_ZOT_SECRET_KEY}"
    }
  },
  "http": {
    "address": "0.0.0.0",
    "port": "${ZOT_PORT}",
    "externalUrl": "https://${ZOT_HOST}",
    "compat": ["docker2s2"],
    "auth": {
      "htpasswd": { "path": "/etc/zot/htpasswd" },
      "openid": {
        "providers": {
          "oidc": {
            "name": "Authelia",
            "issuer": "https://authelia.${TRAEFIK_EDGE_IP_DASHED}.sslip.io",
            "clientid": "zot",
            "clientsecret": "${AUTHELIA_ZOT_CLIENT_SECRET}",
            "scopes": ["openid", "profile", "email", "groups"],
            "claimMapping": { "username": "preferred_username", "groups": "groups" }
          }
        }
      },
      "sessionKeysFile": "/etc/zot/session-keys.json",
      "secureSession": true
    },
    "accessControl": {
      "repositories": {
        "**": {
          "anonymousPolicy": ["read"],
          "defaultPolicy": ["read"]
        },
        "apps/**": {
          "anonymousPolicy": ["read"],
          "policies": [
            { "users": ["${ZOT_CI_USER}"], "actions": ["read", "create", "update"] }
          ]
        }
      },
      "adminPolicy": {
        "groups": ["zot-admin"],
        "actions": ["read", "create", "update", "delete"]
      },
      "metrics": { "anonymousPolicy": ["read"] }
    }
  },
  "extensions": {
    "search": { "enable": true },
    "ui": { "enable": true },
    "metrics": { "enable": true, "prometheus": { "path": "/metrics" } },
    "sync": {
      "enable": true,
      "downloadDir": "/tmp/zot-sync",
      "registries": [
        { "urls": ["https://registry-1.docker.io"], "onDemand": true, "preserveDigest": true,
          "content": [{ "prefix": "**", "destination": "/docker.io" }] },
        { "urls": ["https://ghcr.io"], "onDemand": true, "preserveDigest": true,
          "content": [{ "prefix": "**", "destination": "/ghcr.io" }] },
        { "urls": ["https://quay.io"], "onDemand": true, "preserveDigest": true,
          "content": [{ "prefix": "**", "destination": "/quay.io" }] },
        { "urls": ["https://registry.k8s.io"], "onDemand": true, "preserveDigest": true,
          "content": [{ "prefix": "**", "destination": "/registry.k8s.io" }] }
      ]
    }
  }
}
