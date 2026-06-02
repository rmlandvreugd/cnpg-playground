# Plan: Two IngressRouteTCP Routes with mTLS for pg-local

## Architecture Diagram

```
┌────────────────────────────────────────────────────────────────────────────────┐
│                              CLIENT (psql)                                     │
│                                                                                │
│  Route 1: psql "host=pg-local-demo-local-db-t.172-18-255-210.sslip.io"         │
│            sslmode=verify-ca sslrootcert=vault-pki-ca.crt                      │
│            sslcert=client.crt sslkey=client.key  ← mTLS via Vault PKI          │
│            → Traefik terminates TLS, forwards plaintext to pg-local-rw         │
│                                                                                │
│  Route 2: psql "host=pg-local-demo-local-db-p.172-18-255-210.sslip.io"         │
│            sslmode=verify-full sslrootcert=vault-pki-ca.crt                    │
│            sslcert=client.crt sslkey=client.key  ← mTLS via Vault PKI          │
│            → Traefik passes TLS through to PostgreSQL                          │
└──────────────────────────────┬─────────────────────────────────────────────────┘
                               │
                               │  172.18.255.210:5432
                               ▼
┌─────────────────────────────────────────────────────────────────────────────────┐
│  MetalLB LoadBalancer  172.18.255.210  (NEW Service: traefik-postgres)          │
│  Port 5432 → Traefik entrypoint "postgres"                                      │
└──────────────────────────────┬──────────────────────────────────────────────────┘
                               │
                               ▼
┌─────────────────────────────────────────────────────────────────────────────────┐
│  Traefik  —  entrypoint "postgres" :5432                                        │
│                                                                                 │
│  ┌─────────────────────────────────────────────────────────────────────────┐    │
│  │  IngressRouteTCP: pg-local-tls-term                                     │    │
│  │  match: HostSNI(`pg-local-demo-local-db-t.172-18-255-210.sslip.io`)     │    │
│  │                                                                         │    │
│  │  🔒 Traefik TERMINATES TLS                                              │    │
│  │  Server cert: pg-local-tls-term-server-tls (Vault PKI)                  │    │
│  │    CN=pg-local-demo-local-db-t.172-18-255-210.sslip.io                  │    │
│  │  mTLS: TLSOption mtls-verify                                            │    │
│  │    clientAuth: RequireAndVerifyClientCert                               │    │
│  │    CA: vault-pki-bundle (Root + Int CA 1 + Int CA 2)                    │    │
│  │                                                                         │    │
│  │  → Plaintext TCP → pg-local-rw:5432 (demo-local-db)                     │    │
│  └─────────────────────────────────────────────────────────────────────────┘    │
│                                                                                 │
│  ┌─────────────────────────────────────────────────────────────────────────┐    │
│  │  IngressRouteTCP: pg-local-tls-passthrough                              │    │
│  │  match: HostSNI(`pg-local-demo-local-db-p.172-18-255-210.sslip.io`)     │    │
│  │                                                                         │    │
│  │  🔓 Traefik DOES NOT terminate TLS (passthrough)                        │    │
│  │  SNI peek only → forward encrypted stream                               │    │
│  │                                                                         │    │
│  │  → Encrypted TLS → pg-local-rw:5432 (demo-local-db)                     │    │
│  └─────────────────────────────────────────────────────────────────────────┘    │
└─────────────────────────────────────────────────────────────────────────────────┘
                               │
              ┌────────────────┴────────────────┐
              │                                 │
              │  Route 1: Plaintext             │  Route 2: TLS (end-to-end)
              ▼                                 ▼
┌─────────────────────────────────────────────────────────────────────────────────┐
│  demo-local-db namespace                                                        │
│                                                                                 │
│  Service: pg-local-rw  (ClusterIP 10.96.119.153:5432)                           │
│                                                                                 │
│  CNPG Cluster: pg-local                                                         │
│  ┌─────────────────────────────────────────────────────────────────────────┐    │
│  │  PostgreSQL (cert-manager certs from Vault PKI)                         │    │
│  │                                                                         │    │
│  │  Server cert: pg-local-server-tls (Vault PKI)                           │    │
│  │    SANs: pg-local-rw, *.demo-local-db.svc.cluster.local,                │    │
│  │          pg-local-demo-local-db-p.172-18-255-210.sslip.io               │    │
│  │                                                                         │    │
│  │  Client CA: vault-pki-bundle (Root + Int CA 1 + Int CA 2)               │    │
│  │  Replication cert: pg-local-replication-tls (Vault PKI)                 │    │
│  │                                                                         │    │
│  │  pg_hba:                                                                │    │
│  │    hostssl replication streaming_replica all cert                       │    │
│  │    hostssl all cnpg_pooler_pgbouncer all cert                           │    │
│  │    hostssl all all all cert           ← mTLS for TLS connections        │    │
│  │    host    all all all scram-sha-256  ← plaintext (Route 1)             │    │
│  └─────────────────────────────────────────────────────────────────────────┘    │
│                                                                                 │
│  Pooler: pooler-local-rw (PgBouncer)                                            │
│  ┌─────────────────────────────────────────────────────────────────────────┐    │
│  │  Client-facing TLS (accepts connections from clients):                  │    │
│  │    clientTLSSecret: pg-local-pooler-client-tls (Vault PKI)              │    │
│  │    clientCASecret: vault-pki-bundle (full chain)                        │    │
│  │    → mTLS: clients must present Vault PKI client cert                   │    │
│  │                                                                         │    │
│  │  Server-facing TLS (connects to PostgreSQL):                            │    │
│  │    serverTLSSecret: pg-local-pooler-server-tls (Vault PKI)              │    │
│  │    serverCASecret: vault-pki-bundle (full chain)                        │    │
│  │    → verify-full: validates PostgreSQL server cert                      │    │
│  └─────────────────────────────────────────────────────────────────────────┘    │
└─────────────────────────────────────────────────────────────────────────────────┘
```

## CA Trust Chain

```
┌─────────────────────────────────────────────────────────────────────────────────┐
│                        COMPLETE CA TRUST CHAIN                                  │
│                                                                                 │
│  Root CA (self-signed, 10yr)                                                    │
│  └── O=CloudNativePG Playground CA, CN=CloudNativePG Playground CA Root CA      │
│      Source: step-ca-roots ConfigMap, vault-tls-ca Secret                       │
│                                                                                 │
│  Intermediate CA 1 (5yr)                                                        │
│  └── O=CloudNativePG Playground CA, CN=CloudNativePG Playground CA              │
│     Intermediate CA                                                             │
│      Issued by: Root CA                                                         │
│      Source: step-ca-roots ConfigMap                                            │
│                                                                                 │
│  Intermediate CA 2 / Vault PKI Signing CA (5yr)                                 │
│  └── CN=CloudNativePG Playground Intermediate CA                                │
│      Issued by: Intermediate CA 1                                               │
│      Source: vault-pki-int-ca Secret (extracted from Vault PKI)                 │
│      This is the CA that signs all Vault PKI server/client certs                │
│                                                                                 │
│  Server/Client Certs (30d, auto-renewed by cert-manager)                        │
│  └── Issued by: Intermediate CA 2 (Vault PKI pki_int/sign/cluster-certs)        │
└─────────────────────────────────────────────────────────────────────────────────┘
```

## trust-manager Bundle Architecture

```
┌─────────────────────────────────────────────────────────────────────────────────┐
│                     CA DISTRIBUTION VIA trust-manager                           │
│                                                                                 │
│  ┌─────────────────────────────────────────────────────────────────────────┐    │
│  │  Bundle: step-ca-bundle (UPDATE — add Secret target)                    │    │
│  │                                                                         │    │
│  │  Sources:                                                               │    │
│  │    └── ConfigMap: step-ca-roots (cert-manager ns)                       │    │
│  │        key: ca-certificates.crt                                         │    │
│  │        Contains: Root CA + Intermediate CA 1                            │    │
│  │                                                                         │    │
│  │  Targets:                                                               │    │
│  │    ┌─────────────────────────────────────────────────────────────────┐  │    │
│  │    │  ConfigMap: step-ca-bundle (all namespaces) ← EXISTING          │  │    │
│  │    │  Key: ca-certificates.crt                                       │  │    │
│  │    └─────────────────────────────────────────────────────────────────┘  │    │
│  │    ┌─────────────────────────────────────────────────────────────────┐  │    │
│  │    │  Secret: step-ca-bundle (all namespaces) ← NEW                  │  │    │
│  │    │  Key: ca.crt                                                    │  │    │
│  │    └─────────────────────────────────────────────────────────────────┘  │    │
│  └─────────────────────────────────────────────────────────────────────────┘    │
│                                                                                 │
│  ┌─────────────────────────────────────────────────────────────────────────┐    │
│  │  Bundle: vault-pki-bundle (NEW)                                         │    │
│  │                                                                         │    │
│  │  Sources:                                                               │    │
│  │    ├── ConfigMap: step-ca-roots (cert-manager ns)                       │    │
│  │    │    key: ca-certificates.crt                                        │    │
│  │    │    Contains: Root CA + Intermediate CA 1                           │    │
│  │    │                                                                    │    │
│  │    └── Secret: vault-pki-int-ca (cert-manager ns) ← NEW                 │    │
│  │         key: ca.crt                                                     │    │
│  │         Contains: Intermediate CA 2 (Vault PKI signing CA)              │    │
│  │                                                                         │    │
│  │  Combined bundle contains: Root CA + Int CA 1 + Int CA 2                │    │
│  │  (Complete chain for verifying any Vault PKI issued cert)               │    │
│  │                                                                         │    │
│  │  Targets:                                                               │    │
│  │    ┌─────────────────────────────────────────────────────────────────┐  │    │
│  │    │  ConfigMap: vault-pki-bundle (all namespaces)                   │  │    │
│  │    │  Key: ca-certificates.crt                                       │  │    │
│  │    │  → For psql clients, general CA trust distribution              │  │    │
│  │    └─────────────────────────────────────────────────────────────────┘  │    │
│  │    ┌─────────────────────────────────────────────────────────────────┐  │    │
│  │    │  Secret: vault-pki-bundle (all namespaces)                      │  │    │
│  │    │  Key: ca.crt                                                    │  │    │
│  │    │  → For CNPG clientCASecret/serverCASecret                       │  │    │
│  │    │  → For PgBouncer clientCASecret/serverCASecret                  │  │    │
│  │    │  → For Traefik TLSOption clientAuth.secretNames                 │  │    │
│  │    └─────────────────────────────────────────────────────────────────┘  │    │
│  └─────────────────────────────────────────────────────────────────────────┘    │
└─────────────────────────────────────────────────────────────────────────────────┘
```

## Resources to Create

| #   | Resource                   | Namespace     | Kind             | Change                                         |
| --- | -------------------------- | ------------- | ---------------- | ---------------------------------------------- |
| 0   | trust-manager              | cert-manager  | Helm values      | Enable `secretTargets`                         |
| 1   | step-ca-bundle             | (cluster)     | Bundle (update)  | Add `secret` target                            |
| 2   | vault-pki-int-ca           | cert-manager  | Secret           | Vault PKI Intermediate CA 2 cert               |
| 3   | vault-pki-bundle           | (cluster)     | Bundle (new)     | Full chain: step-ca roots + Vault PKI Int CA 2 |
| 4   | pg-local-server-tls        | demo-local-db | Certificate      | PostgreSQL server cert                         |
| 5   | pg-local-replication-tls   | demo-local-db | Certificate      | Replication client cert                        |
| 6   | pg-local-tls-term-server   | demo-local-db | Certificate      | Traefik TLS-termination cert                   |
| 7   | pg-local-pooler-client-tls | demo-local-db | Certificate      | PgBouncer client-facing cert                   |
| 8   | pg-local-pooler-server-tls | demo-local-db | Certificate      | PgBouncer server-facing cert                   |
| 9   | mtls-verify                | traefik       | TLSOption        | mTLS enforcement                               |
| 10  | traefik-postgres           | traefik       | Service          | Second LB on 172.18.255.210                    |
| 11  | pg-local-tls-term          | demo-local-db | IngressRouteTCP  | Route 1: TLS termination                       |
| 12  | pg-local-tls-passthrough   | demo-local-db | IngressRouteTCP  | Route 2: TLS passthrough                       |
| 13  | pg-local                   | demo-local-db | Cluster (update) | Switch to cert-manager certs + pg_hba          |
| 14  | pooler-local-rw            | demo-local-db | Pooler (update)  | Switch to Vault PKI certs                      |

## Detailed Resource Specs

### 0. trust-manager Helm Values Update

```yaml
secretTargets:
  enabled: true
  authorizedSecrets:
    - vault-pki-bundle
    - step-ca-bundle
```

### 1. Bundle: `step-ca-bundle` (UPDATE — add Secret target)

```yaml
apiVersion: trust.cert-manager.io/v1alpha1
kind: Bundle
metadata:
  name: step-ca-bundle
spec:
  sources:
    - configMap:
        key: ca-certificates.crt
        name: step-ca-roots
  target:
    configMap:
      key: ca-certificates.crt
    secret:                  # ← NEW: also sync as Secret
      key: ca.crt
```

Result: ConfigMap `step-ca-bundle` + Secret `step-ca-bundle` in every namespace, both containing Root CA + Intermediate CA 1.

### 2. Secret: `vault-pki-int-ca` (NEW — in cert-manager namespace)

Extract the Vault PKI Intermediate CA 2 cert and store it as a Secret in the trust namespace.

```bash
# Extract from an existing Vault PKI issued cert's ca.crt
kubectl get secret traefik-dashboard-tls -n traefik \
  -o jsonpath='{.data.ca\.crt}' | base64 -d > /tmp/vault-pki-int-ca.crt

kubectl create secret generic vault-pki-int-ca \
  --namespace=cert-manager \
  --from-file=ca.crt=/tmp/vault-pki-int-ca.crt \
  --dry-run=client -o yaml | kubectl apply -f -
```

YAML representation:

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: vault-pki-int-ca
  namespace: cert-manager
type: Opaque
data:
  ca.crt: <base64 of Intermediate CA 2 cert — CN=CloudNativePG Playground Intermediate CA>
```

> **Note**: This cert is valid for 5 years (until 2031). It's the Vault PKI Intermediate CA, which is long-lived and rarely rotates. If it does rotate, this Secret must be updated manually.

### 3. Bundle: `vault-pki-bundle` (NEW — full chain)

```yaml
apiVersion: trust.cert-manager.io/v1alpha1
kind: Bundle
metadata:
  name: vault-pki-bundle
spec:
  sources:
    - configMap:
        key: ca-certificates.crt
        name: step-ca-roots
    - secret:
        name: vault-pki-int-ca
        key: ca.crt
      namespace: cert-manager
  target:
    configMap:
      key: ca-certificates.crt
    secret:
      key: ca.crt
```

Result: ConfigMap `vault-pki-bundle` + Secret `vault-pki-bundle` in every namespace, containing the **complete chain**: Root CA + Intermediate CA 1 + Intermediate CA 2.

### 4. Certificate: `pg-local-server-tls`

```yaml
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: pg-local-server-tls
  namespace: demo-local-db
spec:
  commonName: pg-local-rw
  dnsNames:
    - pg-local-rw
    - pg-local-rw.demo-local-db
    - pg-local-rw.demo-local-db.svc
    - pg-local-rw.demo-local-db.svc.cluster.local
    - pg-local-r
    - pg-local-r.demo-local-db
    - pg-local-r.demo-local-db.svc
    - pg-local-r.demo-local-db.svc.cluster.local
    - pg-local-ro
    - pg-local-ro.demo-local-db
    - pg-local-ro.demo-local-db.svc
    - pg-local-ro.demo-local-db.svc.cluster.local
    - pg-local-demo-local-db-p.172-18-255-210.sslip.io
  issuerRef:
    kind: ClusterIssuer
    name: vault-pki
  secretName: pg-local-server-tls
  duration: 720h
  renewBefore: 168h
  privateKey:
    algorithm: ECDSA
    size: 256
```

### 5. Certificate: `pg-local-replication-tls`

```yaml
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: pg-local-replication-tls
  namespace: demo-local-db
spec:
  commonName: streaming_replica
  dnsNames:
    - pg-local-rw.demo-local-db.svc.cluster.local
  issuerRef:
    kind: ClusterIssuer
    name: vault-pki
  secretName: pg-local-replication-tls
  duration: 720h
  renewBefore: 168h
  privateKey:
    algorithm: ECDSA
    size: 256
```

### 6. Certificate: `pg-local-tls-term-server`

```yaml
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: pg-local-tls-term-server
  namespace: demo-local-db
spec:
  commonName: pg-local-demo-local-db-t.172-18-255-210.sslip.io
  dnsNames:
    - pg-local-demo-local-db-t.172-18-255-210.sslip.io
  issuerRef:
    kind: ClusterIssuer
    name: vault-pki
  secretName: pg-local-tls-term-server-tls
  duration: 720h
  renewBefore: 168h
  privateKey:
    algorithm: ECDSA
    size: 256
```

### 7. Certificate: `pg-local-pooler-client-tls`

```yaml
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: pg-local-pooler-client-tls
  namespace: demo-local-db
spec:
  commonName: pg-local-pooler
  dnsNames:
    - pooler-local-rw
    - pooler-local-rw.demo-local-db
    - pooler-local-rw.demo-local-db.svc
    - pooler-local-rw.demo-local-db.svc.cluster.local
  issuerRef:
    kind: ClusterIssuer
    name: vault-pki
  secretName: pg-local-pooler-client-tls
  duration: 720h
  renewBefore: 168h
  privateKey:
    algorithm: ECDSA
    size: 256
```

### 8. Certificate: `pg-local-pooler-server-tls`

```yaml
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: pg-local-pooler-server-tls
  namespace: demo-local-db
spec:
  commonName: cnpg_pooler_pgbouncer
  dnsNames:
    - pg-local-rw.demo-local-db.svc.cluster.local
  issuerRef:
    kind: ClusterIssuer
    name: vault-pki
  secretName: pg-local-pooler-server-tls
  duration: 720h
  renewBefore: 168h
  privateKey:
    algorithm: ECDSA
    size: 256
```

### 9. TLSOption: `mtls-verify`

```yaml
apiVersion: traefik.io/v1alpha1
kind: TLSOption
metadata:
  name: mtls-verify
  namespace: traefik
spec:
  minVersion: VersionTLS13
  alpnProtocols:
    - postgresql          # Required for psql clients; Traefik defaults to h2/http1.1/acme-tls only
  clientAuth:
    secretNames:
      - vault-pki-bundle    # ← trust-manager Bundle Secret (full chain)
    clientAuthType: RequireAndVerifyClientCert
```

> **ALPN note**: Traefik's default `alpnProtocols` list is `["h2", "http/1.1", "acme-tls/1"]`. PostgreSQL clients send ALPN `"postgresql"` during the TLS handshake. Without this entry, the handshake fails with `tlsv1 alert no application protocol`.

The `vault-pki-bundle` Secret in the `traefik` namespace contains Root CA + Int CA 1 + Int CA 2 — the complete chain needed to verify any Vault PKI issued client certificate.

### 10. Service: `traefik-postgres`

```yaml
apiVersion: v1
kind: Service
metadata:
  name: traefik-postgres
  namespace: traefik
spec:
  type: LoadBalancer
  loadBalancerIP: 172.18.255.210
  selector:
    app.kubernetes.io/instance: traefik-traefik
    app.kubernetes.io/name: traefik
  ports:
    - name: postgres
      port: 5432
      targetPort: 5432
      protocol: TCP
```

### 11. IngressRouteTCP: `pg-local-tls-term` (Route 1 — TLS Termination)

```yaml
apiVersion: traefik.io/v1alpha1
kind: IngressRouteTCP
metadata:
  name: pg-local-tls-term
  namespace: demo-local-db
spec:
  entryPoints:
    - postgres
  routes:
    - match: HostSNI(`pg-local-demo-local-db-t.172-18-255-210.sslip.io`)
      services:
        - name: pg-local-rw
          port: 5432
          namespace: demo-local-db
  tls:
    secretName: pg-local-tls-term-server-tls
    options:
      name: mtls-verify
      namespace: traefik
```

### 12. IngressRouteTCP: `pg-local-tls-passthrough` (Route 2 — TLS Passthrough)

```yaml
apiVersion: traefik.io/v1alpha1
kind: IngressRouteTCP
metadata:
  name: pg-local-tls-passthrough
  namespace: demo-local-db
spec:
  entryPoints:
    - postgres
  routes:
    - match: HostSNI(`pg-local-demo-local-db-p.172-18-255-210.sslip.io`)
      services:
        - name: pg-local-rw
          port: 5432
          namespace: demo-local-db
  tls:
    passthrough: true
```

### 13. Cluster: `pg-local` (update)

```yaml
spec:
  certificates:
    serverTLSSecret: pg-local-server-tls
    serverCASecret: vault-pki-bundle      # ← trust-manager Bundle Secret (full chain)
    clientCASecret: vault-pki-bundle      # ← trust-manager Bundle Secret (full chain)
    replicationTLSSecret: pg-local-replication-tls
  postgresql:
    pg_hba:
      - hostssl replication streaming_replica all cert
      - hostssl all cnpg_pooler_pgbouncer all cert
      - hostssl all all all cert
      - host all all all scram-sha-256
```

> **pg_hba explanation**:
> - `hostssl replication streaming_replica all cert` — CNPG fixed rule (preserved)
> - `hostssl all cnpg_pooler_pgbouncer all cert` — CNPG fixed rule (preserved)
> - `hostssl all all all cert` — **NEW**: require client cert for all TLS connections (mTLS)
> - `host all all all scram-sha-256` — allow plaintext (Route 1, after Traefik terminates TLS)

### 14. Pooler: `pooler-local-rw` (update)

```yaml
spec:
  pgbouncer:
    clientTLSSecret:
      name: pg-local-pooler-client-tls
    clientCASecret:
      name: vault-pki-bundle              # ← trust-manager Bundle Secret (full chain)
    serverTLSSecret:
      name: pg-local-pooler-server-tls
    serverCASecret:
      name: vault-pki-bundle              # ← trust-manager Bundle Secret (full chain)
    parameters:
      default_pool_size: "10"
      max_client_conn: "1000"
      client_tls_sslmode: "verify-full"
      server_tls_sslmode: "verify-full"
    poolMode: session
```

## Implementation Order

```
Phase 0: trust-manager Update
  ├── 0a. Enable secretTargets in trust-manager Helm values
  │      helm upgrade trust-manager --set secretTargets.enabled=true
  │      --set secretTargets.authorizedSecrets={vault-pki-bundle,step-ca-bundle}
  └── 0b. Wait for trust-manager to reconcile

Phase 1: CA Infrastructure (no disruption)
  ├── 1. Update Bundle step-ca-bundle (add Secret target)
  ├── 2. Create Secret vault-pki-int-ca (cert-manager namespace)
  ├── 3. Create Bundle vault-pki-bundle (full chain: step-ca roots + Vault PKI Int CA 2)
  └── Wait for both Bundles to sync to all namespaces ✓

Phase 2: Certificate Infrastructure (no disruption)
  ├── 4. Create Certificate pg-local-server-tls
  ├── 5. Create Certificate pg-local-replication-tls
  ├── 6. Create Certificate pg-local-tls-term-server
  ├── 7. Create Certificate pg-local-pooler-client-tls
  ├── 8. Create Certificate pg-local-pooler-server-tls
  └── Wait for all certificates Ready ✓

Phase 3: Traefik Configuration (no disruption)
  ├── 9. Create TLSOption mtls-verify
  ├── 10. Create Service traefik-postgres (LoadBalancer 172.18.255.210)
  ├── 11. Create IngressRouteTCP pg-local-tls-term
  └── 12. Create IngressRouteTCP pg-local-tls-passthrough

Phase 4: CNPG Cluster Update (rolling restart)
  └── 13. Update Cluster pg-local with certificates + pg_hba
      └── CNPG rolls out pods with Vault PKI certs

Phase 5: Pooler Update (rolling restart)
  └── 14. Update Pooler pooler-local-rw with Vault PKI certs
      └── PgBouncer pods restart with TLS enabled

Phase 6: Verification
  ├── 6a. Verify CA chain integrity
  │      Root CA (no pathlen) → Int CA 1 (pathlen:1) → Int CA 2 (pathlen:0) → Leaf
  ├── 6b. Verify certificate issuance (all certs Ready, correct SANs, ECDSA keys)
  ├── 6c. Verify trust-manager Bundle sync (vault-pki-bundle in all namespaces)
  ├── 6d. Test Route 1: psql with mTLS → TLS-termination endpoint
  └── 6e. Test Route 2: psql with mTLS → TLS-passthrough endpoint
```

## Phase 6: Verification Commands

### 6a. Verify CA Chain Integrity

```bash
# Check pathlen constraints on each CA in the chain
echo "Root CA (should have no pathlen):"
openssl x509 -in step-ca/pki/root_ca.crt -noout -text | grep -A1 "Basic Constraints"

echo "step-ca Int CA (should have pathlen:1):"
openssl x509 -in step-ca/pki/intermediate_ca.crt -noout -text | grep -A1 "Basic Constraints"

echo "Vault PKI Int CA (should have pathlen:0):"
awk '/BEGIN CERTIFICATE/{n++; if(n==1) found=1} found{print} /END CERTIFICATE/{if(found) found=0}' \
  vault/pki/intermediate.crt | openssl x509 -noout -text | grep -A1 "Basic Constraints"

# Verify full chain: Root → Int CA 1 → Int CA 2
cat step-ca/pki/root_ca.crt step-ca/pki/intermediate_ca.crt > /tmp/ca_chain.pem
openssl verify -trusted step-ca/pki/root_ca.crt \
  -untrusted step-ca/pki/intermediate_ca.crt \
  vault/pki/intermediate.crt

# Verify in-cluster CA bundle (3 certs: Root + Int CA 1 + Int CA 2)
kubectl get secret vault-pki-bundle -n default \
  -o jsonpath='{.data.ca\.crt}' | base64 -d | grep -c "BEGIN CERTIFICATE"
# Expected: 3

# Verify Authority Key Identifier chain
echo "step-ca Int CA Subject Key ID (should match Vault PKI Int CA Authority Key ID):"
openssl x509 -in step-ca/pki/intermediate_ca.crt -noout -text \
  | grep "Subject Key Identifier" -A1 | tail -1 | tr -d ' '

echo "Vault PKI Int CA Authority Key ID (should match above):"
awk '/BEGIN CERTIFICATE/{n++; if(n==1) found=1} found{print} /END CERTIFICATE/{if(found) found=0}' \
  vault/pki/intermediate.crt | openssl x509 -noout -text \
  | grep "Authority Key Identifier" -A1 | tail -1 | tr -d ' '
```

### 6b. Verify Certificate Issuance

```bash
# All certificates should be Ready
kubectl get certificate -n demo-local-db

# Verify each cert has correct SANs and ECDSA key type
for cert in pg-local-server-tls pg-local-replication-tls pg-local-tls-term-server \
            pg-local-pooler-client-tls pg-local-pooler-server-tls pg-local-client-app; do
  echo "=== $cert ==="
  kubectl get secret "$cert" -n demo-local-db \
    -o jsonpath='{.data.tls\.crt}' | base64 -d | openssl x509 -noout -subject -issuer
  kubectl get secret "$cert" -n demo-local-db \
    -o jsonpath='{.data.tls\.crt}' | base64 -d | openssl x509 -noout -text \
    | grep "Public Key Algorithm:"
  echo
done

# Verify server cert SANs include the passthrough hostname
kubectl get secret pg-local-server-tls -n demo-local-db \
  -o jsonpath='{.data.tls\.crt}' | base64 -d | openssl x509 -noout -text \
  | grep -A20 "Subject Alternative Name"

# Verify leaf certs validate against the in-cluster CA bundle
kubectl get secret vault-pki-bundle -n default \
  -o jsonpath='{.data.ca\.crt}' | base64 -d > /tmp/vault-pki-bundle-ca.crt

for cert in pg-local-server-tls pg-local-replication-tls pg-local-tls-term-server \
            pg-local-pooler-client-tls pg-local-pooler-server-tls pg-local-client-app; do
  echo -n "$cert: "
  kubectl get secret "$cert" -n demo-local-db \
    -o jsonpath='{.data.tls\.crt}' | base64 -d > /tmp/leaf.crt
  openssl verify -CAfile /tmp/vault-pki-bundle-ca.crt /tmp/leaf.crt
done
```

### 6c. Verify trust-manager Bundle Sync

```bash
# Both bundles should be Synced
kubectl get bundle -n cert-manager

# vault-pki-bundle should exist as Secret in demo-local-db namespace
kubectl get secret vault-pki-bundle -n demo-local-db -o jsonpath='{.data.ca\.crt}' \
  | base64 -d | grep -c "BEGIN CERTIFICATE"
# Expected: 3

# step-ca-bundle should exist as Secret in demo-local-db namespace
kubectl get secret step-ca-bundle -n demo-local-db -o jsonpath='{.data.ca\.crt}' \
  | base64 -d | grep -c "BEGIN CERTIFICATE"
# Expected: 2

# TLSOption should reference vault-pki-bundle
kubectl get tlsoption mtls-verify -n traefik -o yaml | grep -A3 clientAuth
```

### 6d. Test Route 1 — TLS Termination (Traefik terminates TLS)

```bash
# Extract client cert, key, and CA from the cluster
kubectl get secret pg-local-client-app-tls -n demo-local-db \
  -o jsonpath='{.data.tls\.crt}' | base64 -d > /tmp/client.crt
kubectl get secret pg-local-client-app-tls -n demo-local-db \
  -o jsonpath='{.data.tls\.key}' | base64 -d > /tmp/client.key
kubectl get secret vault-pki-bundle -n demo-local-db \
  -o jsonpath='{.data.ca\.crt}' | base64 -d > /tmp/vault-pki-ca.crt

# Test Route 1: TLS termination (Traefik verifies client cert, forwards plaintext to PG)
psql "host=pg-local-demo-local-db-t.172-18-255-210.sslip.io \
      port=5432 \
      dbname=app \
      user=app \
      sslmode=verify-ca \
      sslrootcert=/tmp/vault-pki-ca.crt \
      sslcert=/tmp/client.crt \
      sslkey=/tmp/client.key"
```

> Traefik verifies the client cert against Vault PKI CA chain (via TLSOption mtls-verify).
> Then forwards plaintext to PostgreSQL. The `host all all all scram-sha-256` pg_hba
> rule allows the plaintext connection.

### 6e. Test Route 2 — TLS Passthrough (end-to-end TLS)

```bash
# Test Route 2: TLS passthrough (client connects directly to PostgreSQL over TLS)
psql "host=pg-local-demo-local-db-p.172-18-255-210.sslip.io \
      port=5432 \
      dbname=app \
      user=app \
      sslmode=verify-full \
      sslrootcert=/tmp/vault-pki-ca.crt \
      sslcert=/tmp/client.crt \
      sslkey=/tmp/client.key"
```

> PostgreSQL verifies the client cert against Vault PKI CA chain (via `hostssl all all all cert`
> pg_hba rule). The server cert SAN includes `pg-local-demo-local-db-p.172-18-255-210.sslip.io`,
> so `verify-full` will match the hostname.

## Client Certificate Issuance

Extract CA from trust-manager Bundle (contains full chain):

```bash
# CA chain from trust-manager Bundle (Root + Int CA 1 + Int CA 2)
kubectl get secret vault-pki-bundle -n demo-local-db \
  -o jsonpath='{.data.ca\.crt}' | base64 -d > vault-pki-ca.crt
```

### Option A: Kubernetes Certificate Resource Template

```yaml
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: pg-local-client-<USERNAME>   # e.g., pg-local-client-app
  namespace: demo-local-db
spec:
  commonName: <USERNAME>              # e.g., app
  dnsNames: []                        # optional: add SANs if needed
  issuerRef:
    kind: ClusterIssuer
    name: vault-pki
  secretName: pg-local-client-<USERNAME>-tls
  duration: 720h                      # 30 days
  renewBefore: 168h                   # 7 days
  privateKey:
    algorithm: ECDSA
    size: 256
```

Extract after Ready:

```bash
kubectl get secret pg-local-client-app-tls -n demo-local-db \
  -o jsonpath='{.data.tls\.crt}' | base64 -d > client.crt
kubectl get secret pg-local-client-app-tls -n demo-local-db \
  -o jsonpath='{.data.tls\.key}' | base64 -d > client.key
kubectl get secret vault-pki-bundle -n demo-local-db \
  -o jsonpath='{.data.ca\.crt}' | base64 -d > vault-pki-ca.crt
```

### Option B: kubectl with cert-manager

```bash
cat <<EOF | kubectl apply -f -
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: pg-local-client-app
  namespace: demo-local-db
spec:
  commonName: app
  issuerRef:
    kind: ClusterIssuer
    name: vault-pki
  secretName: pg-local-client-app-tls
  duration: 720h
  renewBefore: 168h
  privateKey:
    algorithm: ECDSA
    size: 256
EOF

# Extract after Ready
kubectl get secret pg-local-client-app-tls -n demo-local-db \
  -o jsonpath='{.data.tls\.crt}' | base64 -d > client.crt
kubectl get secret pg-local-client-app-tls -n demo-local-db \
  -o jsonpath='{.data.tls\.key}' | base64 -d > client.key
kubectl get secret vault-pki-bundle -n demo-local-db \
  -o jsonpath='{.data.ca\.crt}' | base64 -d > vault-pki-ca.crt
```

### Option C: Vault CLI

```bash
# Issue a client certificate directly from Vault PKI
vault write pki_int/issue/cluster-certs \
  common_name="app" \
  ttl="720h" \
  -format=json | jq -r '.data.certificate' > client.crt

vault write pki_int/issue/cluster-certs \
  common_name="app" \
  ttl="720h" \
  -format=json | jq -r '.data.private_key' > client.key

vault write pki_int/issue/cluster-certs \
  common_name="app" \
  ttl="720h" \
  -format=json | jq -r '.data.ca_chain[]' > vault-pki-ca.crt
```

## Connecting with psql

### Route 1 — TLS Termination (Traefik terminates TLS)

```bash
psql "host=pg-local-demo-local-db-t.172-18-255-210.sslip.io \
      port=5432 \
      dbname=app \
      user=app \
      sslmode=verify-ca \
      sslrootcert=vault-pki-ca.crt \
      sslcert=client.crt \
      sslkey=client.key"
```

> Traefik verifies the client cert against Vault PKI CA chain. Then forwards plaintext to PostgreSQL. The `host all all all scram-sha-256` pg_hba rule allows the plaintext connection.

### Route 2 — TLS Passthrough (end-to-end TLS)

```bash
psql "host=pg-local-demo-local-db-p.172-18-255-210.sslip.io \
      port=5432 \
      dbname=app \
      user=app \
      sslmode=verify-full \
      sslrootcert=vault-pki-ca.crt \
      sslcert=client.crt \
      sslkey=client.key"
```

> PostgreSQL verifies the client cert against Vault PKI CA chain (via `hostssl all all all cert` pg_hba rule). The server cert SAN includes `pg-local-demo-local-db-p.172-18-255-210.sslip.io`, so `verify-full` will match.

## Restricting Plaintext Access (Documentation Only — Not Implemented)

Route 1 sends plaintext from Traefik to `pg-local-rw`. The `host all all all scram-sha-256` pg_hba rule allows any connection. To restrict:

### Option A: Network Policy

Limit ingress to Traefik pods only:

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-only-traefik-to-pg-local-rw
  namespace: demo-local-db
spec:
  podSelector:
    matchLabels:
      cnpg.io/cluster: pg-local
  policyTypes:
    - Ingress
  ingress:
    - from:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: traefik
      ports:
        - port: 5432
          protocol: TCP
```

### Option B: pg_hba with CIDR

Restrict plaintext rule to Traefik's pod CIDR:

```
host all all 10.244.0.0/16 scram-sha-256
```

### Option C: Separate listener

Use PgBouncer with TLS on a separate port for internal traffic, removing the plaintext pg_hba rule entirely.

## Key Design Decisions

| Decision                                           | Rationale                                                                                                                |
| -------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------ |
| All certs from Vault PKI                           | Single trust chain; step-ca reserved for external services                                                               |
| trust-manager distributes CA chains                | Single source of truth; automatic sync to all namespaces; both ConfigMap and Secret targets                              |
| `vault-pki-bundle` includes step-ca roots          | Vault PKI Int CA 2 chains to step-ca Int CA 1 → Root; clients need the full chain to verify                              |
| `step-ca-bundle` also gets Secret target           | Consistency; available as Secret for any component that needs step-ca trust anchor                                       |
| `vault-pki-int-ca` Secret in cert-manager ns       | trust-manager can only read Secrets in its trust namespace (`cert-manager`); this stores the Vault PKI Intermediate CA 2 |
| CNPG/PgBouncer reference `vault-pki-bundle` Secret | Contains full chain (Root + Int CA 1 + Int CA 2); works for both server and client verification                          |
| Traefik TLSOption references `vault-pki-bundle`    | Same full chain; trust-manager creates this Secret in the `traefik` namespace automatically                              |
| Separate LB IP (172.18.255.210)                    | Isolates postgres traffic from HTTP/HTTPS on 172.18.255.200; both routes share the same entrypoint differentiated by SNI |
| `hostssl all all all cert` pg_hba rule             | Enforces mTLS on all TLS connections to PostgreSQL; plaintext still allowed for Route 1                                  |
| ECDSA 256-bit keys                                 | Matches Vault PKI's ECDSA P-256 root; consistent algorithm across the chain                                              |