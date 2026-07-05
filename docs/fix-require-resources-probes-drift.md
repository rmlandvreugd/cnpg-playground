# Fix: `kyverno-policies` app stuck OutOfSync on `require-resources-probes` spec-default drift

Bead: **`cnpg-playground-t80`** (P3 bug)

## Context
After the `anu` fix (aggregated ClusterRole giving the kyverno background-controller
`get/list/watch` on rolebindings + `bind` on admin/edit), the `kyverno-policies`
ArgoCD app **syncs successfully** (`operationState.phase=Succeeded`) and
`generate-tenant-rolebindings` reaches `Synced`. But the app as a whole still
reports **`OutOfSync`**, now for a distinct, benign reason: the
`require-resources-probes` ClusterPolicy drifts against git.

Kyverno's admission webhook injects spec defaults that are absent from the git
manifest (`manifests/kyverno/require-resources-probes.yaml`):

| field | git | live (kyverno-defaulted) |
|---|---|---|
| `spec.admission` | absent | `true` |
| `spec.emitWarning` | absent | set |
| `spec.rules[].skipBackgroundRequests` | absent | set |

The app already sets `ignoreDifferences` for `/status` on ClusterPolicy, but not
for these spec fields, so ArgoCD keeps flagging drift. This is purely cosmetic
GitOps noise — the policy is `Ready=True` and enforcing correctly.

Note: `managedFieldsManagers: [kyverno]` will **not** work — on the persisted
object kyverno only owns the `status` subresource; the defaulted spec fields are
owned by `argocd-controller` (applied during admission). The fix must name the
fields explicitly.

## Recommended fix
Extend `ignoreDifferences` on the `kyverno-policies` Application
(`manifests/argocd/apps/kyverno-policies.yaml`) to cover the kyverno-defaulted
spec fields for **all** ClusterPolicies (future-proof, not just this one), using
`jqPathExpressions` so per-rule paths aren't index-fragile:

```yaml
  ignoreDifferences:
    - group: kyverno.io
      kind: ClusterPolicy
      jsonPointers:
        - /status
      jqPathExpressions:
        - .spec.admission
        - .spec.emitWarning
        - .spec.rules[].skipBackgroundRequests
```

Do **not** ignore `spec.background` — it is set explicitly in git and should stay
diffed.

### Alternative (rejected)
Pin the defaulted values directly in each git manifest (`admission: true`,
`emitWarning: false`, `skipBackgroundRequests: ...`). Rejected: kyverno may change
its defaults across chart versions, reintroducing drift; `ignoreDifferences` is
the ArgoCD-recommended pattern for controller-defaulted fields.

## Changes
- `manifests/argocd/apps/kyverno-policies.yaml` — add the `jqPathExpressions`
  block above to the existing `ignoreDifferences[0]`.

This is a GitOps manifest change, so it **requires a commit + push**; ArgoCD picks
it up from `targetRevision: feature/self-service` on the next refresh.

## Verification
1. Commit + push, then `kubectl annotate application kyverno-policies -n argocd
   argocd.argoproj.io/refresh=hard --overwrite`.
2. `kubectl get application kyverno-policies -n argocd` → `SYNC STATUS = Synced`,
   `HEALTH = Healthy`.
3. Per-resource: `require-resources-probes` → `Synced`; no policy spec was edited.
