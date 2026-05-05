# Capsule Tenant Management: Research Plan

Status: research planned 2026-05-04; not yet executed
Scope: evaluate and document Capsule integration into the self-service demo

## Why Capsule

Current self-service design uses Vault policies (`rbr-db-admin`, `rbr-ver-db-admin`) and separate
namespaces (`rbr-ver-db`, `rbr-ver`) to isolate tenants. Capsule adds Kubernetes-native multi-tenancy:

- `Tenant` CRD wraps namespace groups under one owner subject
- Admission webhook enforces RBAC, resource quotas, and networking rules per tenant
- Tenant users see only their namespaces via `kubectl get namespaces` (with capsule-proxy)
- Complements Vault policies — Vault controls DB credential issuance; Capsule controls K8s API access

This research determines whether Capsule integrates cleanly with the existing stack (CNPG, ESO,
Traefik, Dex, Grafana Operator) before any implementation work starts.

---

## Existing Stack (constraints)

- Runtime: rootless Podman + Kind
- Networking: MetalLB + Traefik v3.3.0 (Helm-managed), `allowCrossNamespace: true`
- Auth: Dex OIDC (staticPasswords with `groups` field)
- Secrets: ESO + Vault AppRole (`ClusterSecretStore vault-approle-rbr`)
- DB: CNPG (cluster-scoped operator), PostgreSQL 18 + pgaudit
- Monitoring: Grafana Operator (cluster-scoped), Loki + Alloy (planned)
- Already installed: cert-manager (Capsule depends on it)
- NetworkPolicy: out of scope for first slice (explicit decision in self-service-research.md)

Tenant model:

- Constructor = tenant: `rbr`
- Driver abbreviation = group: `ver`
- DB namespace: `rbr-ver-db`; app namespace: `rbr-ver`
- Future: `rbr-had-db`, `mer-ant-db`

---

## Research Areas and Questions

### R1: Installation + Compatibility

**Blocking questions:**

- What is the current stable Capsule release? Is it compatible with CNPG 1.29 + Traefik v3.3.0?
- Does Capsule require cert-manager? Which version minimum?
- Does Capsule admission webhook conflict with CNPG, ESO, Grafana Operator, or cert-manager webhooks?
  All four register `MutatingWebhookConfiguration` / `ValidatingWebhookConfiguration`. Check for
  `failurePolicy: Fail` combinations that could deadlock webhook chains.
- Does rootless Podman + Kind expose any known issues with Capsule webhook delivery
  (certificate SANs, kube-apiserver → webhook pod reachability)?
- Helm chart name, repo URL, and install namespace (typically `capsule-system`).

**Deliverable:** pinned version + confirmed install command + webhook conflict table.

---

### R2: Tenant Model Mapping

**Blocking questions:**

- Can one Capsule `Tenant` own multiple namespaces (`rbr-ver-db` + `rbr-ver`) simultaneously?
  Or does Capsule model per-namespace ownership?
- `Tenant.spec.owners`: subjects are `User`, `Group`, or `ServiceAccount`. Can a Dex-issued OIDC group
  claim (`rbr-db-admin`) map directly to a Capsule owner `Group` subject?
  Requires: Kubernetes API server `--oidc-groups-claim=groups` flag — is this set in Kind config?
- `TenantAccessControlList`: how do group-level admins (`rbr-ver-db-admin`) get namespace access
  without being Tenant `owner`? Can ACL entries reference OIDC groups?
- Does Capsule support separate `Tenant` objects per driver group (`rbr-ver`, `rbr-had`) under
  a parent tenant (`rbr`)? Is there a hierarchy concept, or is each `Tenant` flat?
- Can the same namespace belong to two `Tenant` objects? (Relevant if `rbr` tenant admin needs
  access to `rbr-ver-db` alongside `rbr-ver-db-admin` group.)

**Deliverable:** confirmed `Tenant` YAML skeleton for `rbr-ver` + `rbr-ver-db` namespaces,
owner subject strategy (Dex group or Vault userpass), ACL design for group-admin access.

---

### R3: Cluster-Scoped Operator Compatibility

CNPG and ESO are cluster-scoped operators that create and manage resources inside tenant namespaces.
Capsule admission webhook may block operations from service accounts outside the tenant.

**Blocking questions:**

- Does Capsule webhook intercept resource creation by `cnpg-system` service accounts inside
  `rbr-ver-db`? Does it require explicit allowlisting?
- Does Capsule block `ClusterSecretStore` (ESO) from writing `Secret` resources into tenant namespaces?
- Does the `capsule.clastix.io/skip-webhook` annotation exist? Which resources/service accounts
  need it?
- Does Capsule block Grafana Operator from creating `GrafanaDatasource` resources in the `grafana`
  namespace (which would NOT be a tenant namespace)?
- Does Capsule interfere with cert-manager `CertificateRequest` / `Order` resources created in
  tenant namespaces (e.g., if TLS certs are provisioned per-tenant later)?

**Deliverable:** list of service accounts / namespaces that need Capsule exemptions;
confirmed annotation or CRD field for exemptions.

---

### R4: Traefik + Networking

**Blocking questions:**

- `IngressRouteTCP` is a custom CRD, not a Kubernetes `Ingress` resource. Does Capsule's
  IngressClass enforcement apply to `IngressRouteTCP`? (Likely no, but confirm.)
- Capsule can enforce `allowedIngressClasses`. Does this block or interfere with Traefik
  routes defined in the `traefik` namespace targeting services in `rbr-ver-db`?
- If Capsule generates NetworkPolicy for tenants, does it block:
  - Traefik → `verstappen-rw.rbr-ver-db:5432` (TCP passthrough)
  - pgBouncer pooler (`rbr-ver`) → `verstappen-rw` (`rbr-ver-db`) cross-namespace
  - CNPG metrics exporter → kube-prometheus-stack in `monitoring`
- Can Capsule NetworkPolicy generation be disabled per-tenant or globally while keeping
  other Capsule features (RBAC, quota)?
- `capsule-proxy`: is it required for the demo (for tenant users to `kubectl get namespaces`)
  or optional?

**Deliverable:** NetworkPolicy impact matrix; confirmed Capsule config to disable auto-NetworkPolicy;
decision on capsule-proxy inclusion in demo.

---

### R5: Kind OIDC Configuration

Capsule Tenant `Group` subjects require the Kubernetes API server to extract group claims from OIDC tokens.

**Blocking questions:**

- Does the current Kind cluster config (`scripts/setup.sh`) set `--oidc-issuer-url`,
  `--oidc-client-id`, `--oidc-groups-claim`, and `--oidc-username-claim`?
- If not: can Kind cluster config be extended without rebuilding from scratch? Which flags are needed?
- Alternative: use Capsule `TenantAccessControlList` with explicit `User` subjects (email-based)
  instead of `Group` subjects, avoiding the OIDC groups-claim requirement. Trade-off?
- Does Dex issue a `groups` claim that Kubernetes will accept as the group subject name
  (format: `rbr-db-admin`, `rbr-ver-db-admin`)?

**Deliverable:** Kind cluster config patch (or confirmed existing flags); OIDC-vs-ACL decision.

---

### R6: Shared / System Namespaces

`vault`, `traefik`, `dex`, `grafana`, `monitoring`, `cert-manager-system`, `metallb-system`,
`capsule-system`, `cnpg-system`, `external-secrets` are NOT tenant namespaces.

**Blocking questions:**

- How does Capsule distinguish system namespaces from tenant namespaces? Is it automatic
  (namespaces without `capsule.clastix.io/tenant` label are unmanaged)?
- `GlobalTenantResource` CRD: can it propagate shared ConfigMaps or Secrets from a system namespace
  into all tenant namespaces? Is this useful for this demo?
- Can a Capsule Tenant owner modify resources in system namespaces? (Should be blocked by normal
  Kubernetes RBAC, but confirm Capsule does not loosen this.)

**Deliverable:** confirmed namespace isolation model; list of system namespaces that need
no Capsule config; `GlobalTenantResource` usefulness assessment for demo.

---

### R7: Vault Policy Boundary

**Design questions (no external research needed, but must be decided before implementation):**

- Capsule enforces K8s API access; Vault enforces DB credential issuance. The boundary is:
  - Capsule: who can `kubectl apply` to `rbr-ver-db` / `rbr-ver`
  - Vault: who can `vault read database/creds/rbr-ver-db-admin`
- Are these two access layers configured independently (K8s RBAC via Capsule, Vault RBAC via
  Vault policies)? Or does Capsule userpass/OIDC identity need to map to a Vault entity?
- Should the demo show both layers (K8s namespace access via Capsule + DB creds via Vault)
  as a combined self-service flow?

**Deliverable:** documented two-layer access model; demo flow showing both Capsule K8s access
and Vault DB credential issuance.

---

### R8: Teardown + Demo Script Impact

**Blocking questions:**

- Does deleting a Capsule `Tenant` cascade-delete all owned namespaces? Is this the desired
  behavior for `demo/self-service-setup.sh teardown local`?
- Can tenant deletion be non-cascading (preserve namespaces, only remove Capsule ownership)?
- Which existing `demo/self-service-setup.sh` verbs need a Capsule step:
  - `setup local`: add `Tenant` manifest apply after namespace creation
  - `teardown local`: delete `Tenant` before or after namespace deletion?
  - `verify local`: add `kubectl get tenant rbr-ver` check

**Deliverable:** teardown behavior spec; updated verb table for `demo/self-service-setup.sh`.

---

## Research Queue (parallel agent assignments)

Each item is independently researchable. Run in parallel.

| ID | Topic | Method | Key output |
|----|-------|--------|------------|
| RC1 | Installation + webhook conflicts | Web: Capsule docs + CNPG/ESO GitHub issues | Version, Helm cmd, conflict table |
| RC2 | Tenant model + owner subjects | Web: Capsule API reference + TenantAccessControlList docs | Tenant YAML skeleton |
| RC3 | CNPG + ESO + Grafana Operator compatibility | Web: Capsule docs exemptions + GitHub issues | Exemption annotation list |
| RC4 | Traefik + networking + NetworkPolicy | Web: Capsule networking docs + IngressRouteTCP | NetworkPolicy disable method |
| RC5 | Kind OIDC + groups-claim config | Codebase: `scripts/setup.sh` + Kind config docs | Kind config patch or ACL alternative |
| RC6 | Teardown behavior | Web: Capsule docs on tenant deletion | Cascade behavior + teardown order |

---

## Decisions Needed Before Implementation

1. **Owner subject type**: Dex OIDC group (`Group` subject, requires Kind OIDC flags) vs explicit
   user list (`User` subject, simpler but no dynamic group membership).
2. **Hierarchy**: one `Tenant` per constructor (`rbr`) with multiple namespace groups, or one
   `Tenant` per constructor+driver pair (`rbr-ver`).
3. **capsule-proxy**: include in demo (richer UX, extra component) or exclude (simpler).
4. **NetworkPolicy**: keep disabled (existing decision) and confirm Capsule NetworkPolicy generation
   can be turned off independently.
5. **Phase placement**: Capsule install in `scripts/setup.sh` (Phase 0) or separate
   `scripts/capsule-setup.sh`.

---

## Phase Impact (preliminary)

| Existing phase | Change if Capsule added |
|----------------|------------------------|
| Phase 0: Pre-impl checks | + Capsule install + OIDC Kind config |
| Phase 1: Static manifests | + `Tenant` CRD manifest for `rbr-ver` |
| Phase 2: Vault setup | No change (Vault layer independent) |
| Phase 3: Demo script | + `setup`/`verify`/`teardown` Capsule verbs |
| Phase 4: pgAdmin | No change |
| Phase 5: Grafana + Dex | Possible: Dex groups → Capsule Group subjects |
| Phase 6: Docs | + Capsule tenant model in architecture diagram |

---

## Source Links

- Capsule GitHub: https://github.com/projectcapsule/capsule
- Capsule docs overview: https://projectcapsule.dev/docs/overview/
- Capsule Tenant API reference: https://projectcapsule.dev/docs/tenants/tenant-api/
- Capsule + Dex/OIDC: https://projectcapsule.dev/docs/guides/oidc-authentication/
- Capsule proxy: https://projectcapsule.dev/docs/proxy/
- Capsule networking: https://projectcapsule.dev/docs/tenants/networking/
- GlobalTenantResource: https://projectcapsule.dev/docs/tenants/global-tenant-resource/
- Kind extraArgs (OIDC): https://kind.sigs.k8s.io/docs/user/configuration/#api-server
