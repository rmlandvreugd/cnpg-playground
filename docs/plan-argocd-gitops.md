# ArgoCD GitOps Plan (local region)

Status: plan 2026-06-18. Identity per `plan-tenant-personas-authelia.md`; reconciles tenant
resources from Capsule/Kyverno/app/Grafana plans.

## Role in the platform

ArgoCD becomes the **GitOps engine** for self-service tenant resources. `self-service-setup.sh`
stops applying those with direct `helm`/`kubectl`; instead it bootstraps ArgoCD and applies a single
**root Application**, and ArgoCD reconciles the rest from this repo. This avoids double-management.

**Boundary:** ArgoCD + (optionally) Argo Rollouts now. **Argo Events + Workflows stay Phase 2** —
the event-driven pgAdmin provisioning in `plan-self-service-dynamic-creds-pgadmin.md` is unchanged
and not wired here.

## Install

- Helm `argo/argo-cd` in namespace `argocd` (Phase 0 of `scripts/setup.sh`), system namespace.
- Traefik IngressRoute on `argocd.<IP_DASHED>.sslip.io` (TLS via cert-manager; `server.insecure=true`
  behind Traefik TLS, or configure ArgoCD TLS).
- **SSO via Authelia** (`argocd-cm`):
  ```yaml
  oidc.config: |
    name: Authelia
    issuer: https://authelia.${IP_DASHED}.sslip.io
    clientID: argocd
    clientSecret: $oidc.authelia.clientSecret   # from a secret seeded by setup
    requestedScopes: ["openid","profile","email","groups"]
    requestedIDTokenClaims: { groups: { essential: true } }
  ```
- **RBAC** (`argocd-rbac-cm`): `g, argocd-admin, role:admin`. Optionally
  `g, rbr-ver-dev, role:rbr-ver-sync` (a project-scoped role that can sync the `rbr-ver` app only).
- Authelia OIDC client `argocd` (redirect `…/auth/callback`).

## App-of-apps

`manifests/argocd/root-app.yaml` (an Application pointing at `manifests/argocd/apps/`) →
child Applications:

| Child app | Source | Destination | Notes |
|---|---|---|---|
| `tenant-rbr` | `manifests/capsule-tenant-rbr.yaml` + namespace labels | in-cluster | Capsule Tenant + labels |
| `kyverno-policies` | `manifests/kyverno/` | in-cluster | exclude Kyverno-generated children from diff |
| `demo-app` | `app/helm/demo-app` (values `values-rbr-ver.yaml`) | `rbr-ver` | the running sample app |
| `grafana-rbr-ver` | `demo/yaml/self-service/grafana/` | `grafana` | tenant org/datasources/dashboards |

AppProject `rbr` restricts sources to this repo and destinations to `rbr-*` + `grafana` namespaces.

## Script handoff (`self-service-setup.sh`)

| Verb | ArgoCD interaction |
|---|---|
| `setup local` | install/confirm ArgoCD → build + `kind load` demo-app image → `kubectl apply` root Application → wait for `Synced/Healthy`. |
| `verify local` | `argocd app get rbr-root` (or `kubectl get applications -n argocd`) all `Synced/Healthy`; demo-app pods Running in `rbr-ver`. |
| `teardown local` | `kubectl delete -f manifests/argocd/root-app.yaml` (cascades child apps) → then namespaces/Tenant. |

Image note: ArgoCD deploys the chart, but the **image** must already be loaded into Kind — the
script builds `app/Dockerfile` and `kind load docker-image` (or pushes to a local registry) before
ArgoCD syncs. ArgoCD does not build images.

## Avoiding double-management / sync loops

- Resources ArgoCD owns are **removed from direct `helm`/`kubectl`** in the script.
- Kyverno-**generated** resources (RoleBindings, NetworkPolicies) are owned by Kyverno → add
  `ignoreDifferences` / resource exclusions so ArgoCD doesn't fight Kyverno.
- ESO-managed Secrets (`verstappen-app`) are not in Git → not tracked by ArgoCD.

## Monitoring

ArgoCD components expose `/metrics`; add ServiceMonitors and (optionally) the upstream ArgoCD
Grafana dashboard.

## Phase 2 (deferred)

Argo Events (NATS EventBus + resource EventSource watching `verstappen-app`) → Sensor → Argo
Workflows `WorkflowTemplate` re-running the pgAdmin provisioning steps natively, + Argo Rollouts for
progressive delivery of demo-app. Documented in `plan-self-service-dynamic-creds-pgadmin.md` §Phase 2.

## Verification

- ArgoCD UI loginable via Authelia as `admin` (`role:admin`).
- `kubectl get applications -n argocd` → `rbr-root` + children `Synced/Healthy`.
- demo-app reachable in `rbr-ver`; editing chart values + git change re-syncs.
- `teardown local` removes child apps cleanly (no orphaned tenant resources).

## Sources

- ArgoCD: https://argo-cd.readthedocs.io/
- OIDC config: https://argo-cd.readthedocs.io/en/stable/operator-manual/user-management/#existing-oidc-provider
- App-of-apps: https://argo-cd.readthedocs.io/en/stable/operator-manual/cluster-bootstrapping/
- AppProject RBAC: https://argo-cd.readthedocs.io/en/stable/operator-manual/rbac/
