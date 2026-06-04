# Plan: Barman Cloud Plugin — cert-manager/trust-manager Certs Instead of Self-Signed

## Current State

The Barman Cloud Plugin helm chart (`plugin-barman-cloud`) creates three cert-manager resources by default:

1. **`selfsigned-issuer`** Issuer — a self-signed CA in `cnpg-system`
2. **`barman-cloud-server`** Certificate — server auth cert signed by the self-signed issuer
3. **`barman-cloud-client`** Certificate — client auth cert signed by the self-signed issuer

These are used for mTLS between the CNPG operator and the Barman Cloud Plugin sidecar. The Service annotations (`cnpg.io/pluginClientSecret`, `cnpg.io/pluginServerSecret`) tell the operator which secrets to use.

**Problem**: The self-signed issuer creates certs that aren't chained to the playground's step-ca → Vault PKI hierarchy. They can't be verified by any other workload in the cluster.

## Target State

Replace the self-signed certs with certs issued by the existing `vault-pki` ClusterIssuer, which chains through Vault's intermediate CA → step-ca's intermediate CA → step-ca's root CA. This gives the barman plugin certs the same trust chain as every other TLS cert in the playground (PostgreSQL, PgBouncer, Dex, Traefik, Grafana).

## Key Constraint

The helm chart **hardcodes** the issuer reference to `<fullname>-selfsigned-issuer` in both Certificate templates and **always creates** the self-signed Issuer (no flag to skip it). The `certificate.issuerName` value is effectively unused. This means we can't simply pass `--set certificate.issuerName=vault-pki`.

## Approach

1. **Disable the chart's Certificate creation** via `--set certificate.createClientCertificate=false --set certificate.createServerCertificate=false`
2. **Create our own Certificate CRs** that reference `vault-pki` ClusterIssuer
3. The self-signed Issuer still gets created but is harmless (unused)

## Changes

### 1. New: `demo/yaml/barman-cloud/certificate-server.yaml`

```yaml
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: barman-cloud-server
  namespace: cnpg-system
spec:
  commonName: barman-cloud
  dnsNames:
    - barman-cloud
    - barman-cloud.cnpg-system
    - barman-cloud.cnpg-system.svc
    - barman-cloud.cnpg-system.svc.cluster.local
  issuerRef:
    kind: ClusterIssuer
    name: vault-pki
  secretName: barman-cloud-server-tls
  duration: 720h
  renewBefore: 168h
  privateKey:
    algorithm: ECDSA
    size: 256
  usages:
    - server auth
```

- Uses `vault-pki` ClusterIssuer (chains to step-ca root)
- ECDSA P256 key — consistent with Vault PKI role and other playground certs
- 720h duration / 168h renewBefore — matches other playground server certs
- DNS names cover in-cluster service discovery

### 2. New: `demo/yaml/barman-cloud/certificate-client.yaml`

```yaml
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: barman-cloud-client
  namespace: cnpg-system
spec:
  commonName: barman-cloud-client
  issuerRef:
    kind: ClusterIssuer
    name: vault-pki
  secretName: barman-cloud-client-tls
  duration: 168h
  renewBefore: 24h
  privateKey:
    algorithm: ECDSA
    size: 256
  usages:
    - client auth
```

- Shorter duration (168h / 7 days) for client auth certs — matches Vault `mtls-client` role TTL
- No DNS names needed — client auth certs only need a CN

### 3. Modify: `demo/setup.sh`

Update the barman-cloud helm install to disable self-signed cert creation, then apply our Certificate CRs:

```bash
# Before (line ~102-106):
helm_upgrade_install barman-cloud plugin-barman-cloud cnpg-system "${CONTEXT_NAME}" \
    "${BARMAN_CLOUD_PLUGIN_CHART_VERSION}" \
    --repo-url https://cloudnative-pg.github.io/charts

# After:
helm_upgrade_install barman-cloud plugin-barman-cloud cnpg-system "${CONTEXT_NAME}" \
    "${BARMAN_CLOUD_PLUGIN_CHART_VERSION}" \
    --repo-url https://cloudnative-pg.github.io/charts \
    --set certificate.createClientCertificate=false \
    --set certificate.createServerCertificate=false

# Apply barman-cloud TLS certificates (vault-pki instead of self-signed)
echo "📜 Issuing barman-cloud TLS certificates via vault-pki..."
kubectl apply --context "${CONTEXT_NAME}" -f \
    ${demo_yaml_path}/barman-cloud/certificate-server.yaml
kubectl apply --context "${CONTEXT_NAME}" -f \
    ${demo_yaml_path}/barman-cloud/certificate-client.yaml
kubectl wait --context "${CONTEXT_NAME}" --timeout=60s \
    --for=condition=Ready certificate/barman-cloud-server -n cnpg-system
kubectl wait --context "${CONTEXT_NAME}" --timeout=60s \
    --for=condition=Ready certificate/barman-cloud-client -n cnpg-system
```

### 4. Modify: `demo/teardown.sh`

Add cleanup for the Certificate CRs before helm uninstall:

```bash
# Before helm uninstall, delete the vault-pki certificates
kubectl delete certificate barman-cloud-server barman-cloud-client \
    -n cnpg-system --context "${CONTEXT_NAME}" --ignore-not-found
```

### 5. New: `demo/yaml/barman-cloud/codemap.md`

Document the new directory.

## Why This Works

| Aspect | Detail |
|--------|--------|
| **Trust chain** | `vault-pki` ClusterIssuer → Vault `pki_int/sign/cluster-certs` → step-ca intermediate → step-ca root |
| **CA distribution** | trust-manager `vault-pki-bundle` already distributes full CA chain to all namespaces (including `cnpg-system`) |
| **Secret names** | `barman-cloud-server-tls` and `barman-cloud-client-tls` — match the Service annotations exactly |
| **Service annotations** | Unchanged — `cnpg.io/pluginClientSecret: barman-cloud-client-tls` and `cnpg.io/pluginServerSecret: barman-cloud-server-tls` |
| **Self-signed Issuer** | Still created by helm chart but unused — harmless |

## Future Enhancement: ObjectStore `endpointCA`

Currently all ObjectStore CRs use `http://` endpoints (no TLS). A follow-up could add:

1. TLS certificates for RustFS (via cert-manager + `vault-pki`)
2. `endpointCA` field in ObjectStore CRs pointing to the trust-manager CA bundle Secret
3. Change `endpointURL` from `http://` to `https://`

This would give end-to-end TLS for backup traffic, but is out of scope for this change.

## Files Summary

| Action | File |
|--------|------|
| **Create** | `demo/yaml/barman-cloud/certificate-server.yaml` |
| **Create** | `demo/yaml/barman-cloud/certificate-client.yaml` |
| **Create** | `demo/yaml/barman-cloud/codemap.md` |
| **Modify** | `demo/setup.sh` — helm flags + cert apply/wait |
| **Modify** | `demo/teardown.sh` — cert cleanup |