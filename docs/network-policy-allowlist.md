# Ingress allow-list + default-deny (Calico)

Hardening plan item 1b (`docs/local-hardening-plan.md` §D/§E phase 10), bead `i23`.

Every workload pod outside `kube-system`, `calico-system`, `tigera-operator` and
`metallb-system` only accepts ingress that a policy allows. Egress stays open.

| File (`k8s/calico/policies/`) | What |
|---|---|
| `00-default-deny-ingress.yaml` | `default-deny-ingress`, order 10000, explicit `Deny` |
| `10-cluster-wide.yaml` | nodes (`GlobalNetworkSet cluster-nodes`) and Prometheus → any pod |
| `20-edge.yaml` | world → Traefik `8000/8443/5432`, world → OTLP `4317/4318` (MetalLB entry points) |
| `30-platform-namespaces.yaml` | Traefik → routed backends, same-namespace, Loki/Mimir/Tempo writers and readers, `:4319` for tenants |

Tenant namespaces get one generated policy each: `scripts/netpol.sh` renders
`allow-tenant-<tenant>` per Capsule tenant (same tenant, plus traefik / cnpg-system /
external-secrets / monitoring), because "same tenant" cannot be written statically — Calico
selectors compare against literals, not the destination's own label value. It mirrors the
NetworkPolicy that `manifests/kyverno/generate-default-networkpolicy.yaml` generates, but does
not depend on Kyverno and ArgoCD having synced. Kubernetes NetworkPolicies (order 1000) are
evaluated before the default-deny, so the Kyverno one's allows still count once it lands.

Tenant namespaces are created after `scripts/setup.sh` applies the set, so
`demo/self-service-setup.sh setup` re-runs `netpol.sh enforce` right after creating them.

The point of the set is the observability backends: Loki, Mimir and Tempo take the tenant from
the `X-Scope-OrgID` header. Before this change a tenant pod could read the platform's logs with
`curl -H 'X-Scope-OrgID: platform' http://loki.grafana.svc:3100/...` (verified: HTTP 200).

## Usage

```bash
scripts/netpol.sh stage   local   # StagedGlobalNetworkPolicy: nothing dropped, would-be denies reported
scripts/netpol.sh enforce local   # GlobalNetworkPolicy (what scripts/setup.sh applies)
scripts/netpol.sh off     local   # remove everything (fully reversible)
scripts/netpol.sh status  local
```

`scripts/setup.sh` applies the set after the platform, before `info.sh`:
`NETPOL_MODE=enforce` (default) | `stage` | `off`.

## Flow logs (Calico Goldmane)

`scripts/flowlogs.sh` calls the flow-logs API (`goldmane.Flows/List`, proto pinned in
`k8s/calico/goldmane/api.proto` for v3.32.2) through a port-forward, with the operator-issued
`whisker-backend-key-pair` client certificate (Goldmane is mTLS-only). Needs `grpcurl` (mise).

```bash
scripts/flowlogs.sh pending --since 600   # flows the STAGED set would deny
scripts/flowlogs.sh denied  --since 600   # flows the dataplane denied
scripts/flowlogs.sh all --ns grafana --json
```

Each line is `src_ns/src -> dst_ns/dst:port/proto  action [reporter] tier/deciding-policy`;
`end-of-tier(<policy>)` names the policy whose selection triggered the tier's implicit deny.
Goldmane keeps about an hour, in 15 s buckets: query windows that start after the last
`stage`/`enforce`, or old flows show up against the previous policy version.

Changing the allow-list: `stage`, drive the affected path (UI via Traefik, Grafana queries,
`demo/self-service-setup.sh verify|backup|rotate app local`), check `pending` is empty, `enforce`.

## Verified on a from-scratch rebuild (2026-09-20)

`teardown.sh local` + `setup.sh local --with-tenant` (policies enforced before monitoring and
the tenant install) finished with exit 0 and every pod Ready, all five ArgoCD apps
Synced/Healthy, the CNPG cluster healthy at 3/3, and every Traefik route answering. Through
Grafana: 85 scrape targets up, Loki labels, 11 span-metric series, Tempo traces from demo-app
and traefik-edge. The only flow the dataplane dropped was the probe — a tenant pod calling
`loki.grafana.svc:3100` with `X-Scope-OrgID: platform`, which returned HTTP 200 before this
change and now times out.

Unrelated to the policies, two things surfaced in that rebuild and are worth knowing:
the tenant Grafana datasources/dashboards are created before the Grafana CR exists, so they
sit at `NoMatchingInstance` until the operator's next resync (an annotation touch forces it);
and the Grafana MCP holds the token it resolved at launch, so it needs a reconnect after a
cluster rebuild.

## Findings from building it

- **Host → local pod is not policed.** Kubelet probes (source = node IP) pass regardless; the
  plan's ★ probe rule was not needed. Host → *remote* pod is policed: the apiserver calling
  webhooks/aggregated APIs on other nodes arrives from the control-plane node IP, hence
  `allow-from-nodes`.
- **A default-tier policy that selects an endpoint puts it under the tier's end-of-tier deny.**
  The first draft of `allow-from-nodes` used `selector: all()` without a `namespaceSelector`;
  the staged run showed every DNS query to CoreDNS as would-be-denied. All policies now carry
  the default-deny's namespace exemption or select specific namespaces.
- **`destination.namespaceSelector` in an ingress rule did not match the local endpoint**; use
  `destination.selector: projectcalico.org/namespace == '<ns>'`.
- **The tenant NetworkPolicy is generated by Kyverno via ArgoCD, so it does not exist during
  tenant onboarding.** The rebuild caught this: the CNPG cluster hung on "Instance Status
  Extraction Error: HTTP communication issue" while the flow logs showed
  `cnpg-system/cnpg-operator -> rbr-ver-db/verstappen-1:8000 Deny`. Hence the per-tenant
  policy above; platform control paths must not depend on a GitOps-delivered policy.
- Radar reads Caretta's VictoriaMetrics (`caretta-vm:8428`) — only visible in the flow logs.
- Goldmane reports host sources only as `Network/pvt`, no IPs; the node set is rendered from
  the node InternalIPs instead of trusting the whole kind subnet (host containers live there).
