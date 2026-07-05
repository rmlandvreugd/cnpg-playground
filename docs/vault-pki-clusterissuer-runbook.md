# Vault PKI ClusterIssuer Runbook

This runbook describes the flow used by `scripts/setup.sh local` and the related Vault PKI setup, generalized for another Kubernetes environment.

Goal: use Vault as an intermediate CA, expose it to Kubernetes through cert-manager, then request workload certificates with a `ClusterIssuer`.

## Inputs

Decide these values before starting:

| Name | Example | Purpose |
|------|---------|---------|
| `PARENT_CA_CERT` | `step-ca intermediate_ca.crt` | CA certificate that signs the Vault intermediate CA |
| `PARENT_CA_KEY` | `step-ca intermediate_ca_key` | Private key for the parent signing CA |
| `PARENT_CA_CHAIN` | root + parent intermediate | CA chain trusted by clients |
| `VAULT_ADDR` | `https://vault.example.com:8200` | Vault API address |
| `VAULT_K8S_ADDR` | `https://vault.172-18-0-250.sslip.io` | Vault address reachable by cert-manager (canonical edge-LB URL; no port) |
| `VAULT_TOKEN` | root/bootstrap token | Token used only for PKI/bootstrap work |
| `VAULT_PKI_MOUNT` | `pki_int` | Vault PKI mount used by cert-manager |
| `VAULT_ROLE` | `cluster-certs` | Vault PKI role used for normal server certs |
| `ISSUER_NAME` | `vault-pki` | cert-manager `ClusterIssuer` name |
| `ISSUER_NAMESPACE` | `cert-manager` | Namespace containing cert-manager and issuer auth secrets |

## 1. Prepare Vault TLS

Vault must serve HTTPS with a certificate that cert-manager can validate.

1. Issue a server TLS certificate for Vault from a CA trusted by the cluster.
2. Include every name cert-manager will use in the SANs. At minimum include the Kubernetes service DNS name, for example:

   ```text
   vault.vault.svc
   vault.vault.svc.cluster.local
   vault.example.com
   ```

3. Configure the Vault listener with the certificate and key.
4. Keep the CA bundle that validates Vault's listener certificate. This becomes `caBundle` in the `ClusterIssuer`.

In this repo, `scripts/vault-setup.sh` gets Vault's listener certificate from step-ca and writes the validation chain to `vault/certs/vault-ca.pem`.

## 2. Create the Vault Intermediate CA

Enable a Vault PKI mount and request an intermediate CA certificate signing request:

```bash
vault secrets enable -path="${VAULT_PKI_MOUNT}" pki
vault secrets tune -max-lease-ttl=43800h "${VAULT_PKI_MOUNT}"

vault write -field=csr "${VAULT_PKI_MOUNT}/intermediate/generate/internal" \
  common_name="Platform Vault Intermediate CA" \
  key_type=rsa \
  key_bits=2048 > vault-intermediate.csr
```

Sign the CSR with the parent CA. The result must be a CA certificate, not a leaf certificate:

```bash
cat > vault-intermediate.ext <<'EOF'
basicConstraints=critical,CA:TRUE,pathlen:0
keyUsage=critical,digitalSignature,keyCertSign,cRLSign
EOF

openssl x509 -req \
  -in vault-intermediate.csr \
  -CA "${PARENT_CA_CERT}" \
  -CAkey "${PARENT_CA_KEY}" \
  -CAcreateserial \
  -days 1825 \
  -extfile vault-intermediate.ext \
  -out vault-intermediate.crt
```

Import the signed intermediate into Vault. Include the parent/root chain after the Vault intermediate if your clients need Vault to serve the chain:

```bash
cat vault-intermediate.crt "${PARENT_CA_CHAIN}" > vault-intermediate-chain.crt

vault write "${VAULT_PKI_MOUNT}/intermediate/set-signed" \
  certificate=@vault-intermediate-chain.crt
```

Configure issuing certificate and revocation URLs:

```bash
vault write "${VAULT_PKI_MOUNT}/config/urls" \
  issuing_certificates="${VAULT_ADDR}/v1/${VAULT_PKI_MOUNT}/ca" \
  crl_distribution_points="${VAULT_ADDR}/v1/${VAULT_PKI_MOUNT}/crl" \
  ocsp_servers="${VAULT_ADDR}/v1/${VAULT_PKI_MOUNT}/ocsp"

vault write "${VAULT_PKI_MOUNT}/config/crl" \
  auto_rebuild=true \
  auto_rebuild_grace_period=12h \
  ocsp_disable=false
```

## 3. Create Vault PKI Roles

Create a role for normal in-cluster TLS certificates:

```bash
vault write "${VAULT_PKI_MOUNT}/roles/${VAULT_ROLE}" \
  allowed_domains="cluster.local,example.com" \
  allow_subdomains=true \
  allow_bare_domains=true \
  allow_any_name=false \
  allow_ip_sans=true \
  max_ttl=720h \
  not_before_duration=0s \
  require_cn=false \
  key_type=ec \
  key_bits=256 \
  enforce_hostnames=true
```

For this repo's sandbox, `cluster-certs` is deliberately more permissive (`allow_any_name=true`, `sslip.io`, `cluster.local`) because certificates cover Kind service DNS names and local external `sslip.io` names. For a shared environment, tighten `allowed_domains` and avoid `allow_any_name=true` unless there is a clear need.

Important: this repo's Vault role only accepts EC P-256 keys. Every cert-manager `Certificate` using this issuer must set:

```yaml
privateKey:
  algorithm: ECDSA
  size: 256
```

## 4. Create cert-manager Vault Auth

Create a Vault policy for cert-manager:

```hcl
path "pki_int/sign/cluster-certs"  { capabilities = ["create", "update"] }
path "pki_int/issue/cluster-certs" { capabilities = ["create", "update"] }
path "pki_int/cert/ca"             { capabilities = ["read"] }
path "pki_int/certs"               { capabilities = ["list"] }
```

If you use different mount or role names, replace `pki_int` and `cluster-certs` everywhere in the policy.

Write it and create an AppRole:

```bash
vault policy write cert-manager cert-manager-policy.hcl

vault auth enable approle
vault write auth/approle/role/cert-manager \
  token_policies=cert-manager \
  secret_id_ttl=0

vault read -field=role_id auth/approle/role/cert-manager/role-id > role_id
vault write -field=secret_id -f auth/approle/role/cert-manager/secret-id > secret_id
```

The `role_id` is referenced by the `ClusterIssuer`. The `secret_id` is stored as a Kubernetes Secret in the cert-manager namespace.

## 5. Install Kubernetes Components

Install cert-manager and wait for its webhook:

```bash
helm upgrade --install cert-manager oci://quay.io/jetstack/charts/cert-manager \
  --namespace cert-manager \
  --create-namespace \
  --set crds.enabled=true

kubectl -n cert-manager wait --for=condition=Available \
  deployment/cert-manager-webhook --timeout=120s
```

If workloads need the issuing CA bundle mounted as a ConfigMap/Secret, install trust-manager and create a bundle containing:

1. the parent root CA
2. the parent intermediate CA
3. the Vault intermediate CA

This repo stores that combined target as `vault-pki-bundle` in each namespace.

## 6. Make Vault Reachable From Kubernetes

cert-manager must reach `VAULT_K8S_ADDR`.

Vault (a host docker container) is fronted by **traefik-edge acting as its load
balancer** (HashiCorp Raft reference architecture). Every in-cluster consumer —
cert-manager's ClusterIssuer, ESO's ClusterSecretStores, the demo self-service
stores — dials the single canonical URL:

```
https://vault.172-18-0-250.sslip.io      # <edge-ip-dashed>.sslip.io, port 443, no :8200
```

The edge terminates TLS at `:443`, then does a **verified re-encrypt** to
`https://vault:8200` (`serverName: vault.172-18-0-250.sslip.io`, a SAN on Vault's
cert; `rootCAs`: the step-ca chain already mounted in the edge). An LB
**health check** on `/v1/sys/health?standbyok=true` (interval 10s) gates the
backend. See `traefik-edge/dynamic/vault.yaml`.

There is **no** in-cluster `Service`/`Endpoints` for Vault. The previous
hand-built `Service` + `Endpoints` pair hardcoded Vault's dynamic docker IP at
setup time and broke silently on `docker restart vault`; the edge LB removes that
staleness entirely (`docker restart vault` → the edge health check recovers
automatically once Vault is unsealed).

Verify from inside the cluster:

```bash
kubectl -n cert-manager run vault-probe --rm -it --restart=Never \
  --image=curlimages/curl -- \
  curl -sk "${VAULT_K8S_ADDR}/v1/sys/health"
```

This verifies network reachability. For a full TLS check, run a debug pod with the
step-ca CA bundle mounted and use `curl --cacert <mounted-ca-file>`; the edge
presents its own step-ca-issued cert for `vault.172-18-0-250.sslip.io`.

## 7. Create cert-manager Secrets

Create the AppRole SecretID secret:

```bash
kubectl -n "${ISSUER_NAMESPACE}" create secret generic vault-approle \
  --from-literal=secretId="$(cat secret_id)" \
  --dry-run=client -o yaml | kubectl apply -f -
```

Optionally store the Vault listener CA bundle for inspection and troubleshooting:

```bash
kubectl -n "${ISSUER_NAMESPACE}" create secret generic vault-tls-ca \
  --from-file=ca.crt=vault-ca.pem \
  --dry-run=client -o yaml | kubectl apply -f -
```

## 8. Create the ClusterIssuer

Base64-encode the CA bundle that validates Vault's HTTPS listener:

```bash
VAULT_CA_BUNDLE="$(base64 -w0 < vault-ca.pem)"
VAULT_ROLE_ID="$(cat role_id)"
```

Apply the issuer:

```bash
cat > clusterissuer-vault-pki.yaml <<EOF
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: ${ISSUER_NAME}
spec:
  vault:
    server: ${VAULT_K8S_ADDR}
    path: ${VAULT_PKI_MOUNT}/sign/${VAULT_ROLE}
    caBundle: ${VAULT_CA_BUNDLE}
    auth:
      appRole:
        path: approle
        roleId: ${VAULT_ROLE_ID}
        secretRef:
          name: vault-approle
          key: secretId
EOF

kubectl apply -f clusterissuer-vault-pki.yaml
```

Then check readiness:

```bash
kubectl get clusterissuer "${ISSUER_NAME}"
kubectl describe clusterissuer "${ISSUER_NAME}"
```

## 9. Request a Kubernetes Certificate

Create a cert-manager `Certificate` in the workload namespace. The example uses `vault-pki`; replace it with `ISSUER_NAME` if you chose a different issuer name.

```yaml
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: app-server-tls
  namespace: app
spec:
  secretName: app-server-tls
  issuerRef:
    name: vault-pki
    kind: ClusterIssuer
  commonName: app.app.svc.cluster.local
  dnsNames:
    - app
    - app.app
    - app.app.svc
    - app.app.svc.cluster.local
  duration: 720h
  renewBefore: 168h
  privateKey:
    algorithm: ECDSA
    size: 256
  usages:
    - server auth
```

Apply and wait:

```bash
kubectl apply -f app-server-certificate.yaml
kubectl -n app wait --for=condition=Ready certificate/app-server-tls --timeout=120s
kubectl -n app get secret app-server-tls
```

The resulting secret contains `tls.crt`, `tls.key`, and usually `ca.crt`.

## 10. Validate the Issued Certificate

Inspect the cert-manager resources:

```bash
kubectl -n app describe certificate app-server-tls
kubectl -n app get certificaterequest
kubectl -n app describe certificaterequest <request-name>
```

Inspect the certificate chain:

```bash
kubectl -n app get secret app-server-tls \
  -o jsonpath='{.data.tls\.crt}' | base64 -d > tls.crt

openssl x509 -in tls.crt -noout -subject -issuer -dates -text
```

Expected chain:

```text
leaf certificate
  issued by Vault intermediate CA
    issued by parent intermediate CA
      issued by parent/root CA
```

## Troubleshooting

| Symptom | Likely cause | Check |
|---------|--------------|-------|
| `ClusterIssuer` not ready | cert-manager cannot reach Vault or cannot validate Vault TLS | `kubectl describe clusterissuer "${ISSUER_NAME}"`; check `server` and `caBundle` |
| `permission denied` from Vault | AppRole policy does not include the issuer path | Vault audit logs; policy path must match `${VAULT_PKI_MOUNT}/sign/${VAULT_ROLE}` |
| `role requires keys of type ec` | Certificate requested RSA key but Vault role requires EC | Add `privateKey.algorithm: ECDSA` and `size: 256` |
| CertificateRequest denied by Vault | DNS/IP SAN not allowed by Vault role | Compare requested SANs with role `allowed_domains`, `allow_ip_sans`, and hostname settings |
| Secret never appears | CertificateRequest failed or cert-manager webhook is unhealthy | `kubectl describe certificate`, `kubectl get events`, cert-manager logs |
| `x509: certificate is valid for …, not vault.172-18-0-250.sslip.io` on the edge→Vault hop | The edge's verified re-encrypt `serverName` is not a SAN on Vault's cert | Confirm `vault.<edge-ip-dashed>.sslip.io` is in Vault's cert SANs (`scripts/vault-setup.sh`); check `traefik-edge/dynamic/vault.yaml` `serversTransports.vault-verified.serverName` and `rootCAs` |
| `503 Service Unavailable` from `https://vault.<edge-ip-dashed>.sslip.io` | Edge LB health check failing — Vault is **sealed** (returns 503 on `/v1/sys/health`) so the edge marks the only backend down | `docker exec vault vault status`; unseal via `docker exec` or the host-published `127.0.0.1:8200`; Traefik dashboard shows the `vault` service unhealthy |
