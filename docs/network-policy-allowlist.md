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

Tenant namespaces are covered by the NetworkPolicy the Capsule Tenant renders
(`default-deny-with-exceptions`); Kubernetes NetworkPolicies (order 1000) are evaluated before
the default-deny, so their allows still count.

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
- Radar reads Caretta's VictoriaMetrics (`caretta-vm:8428`) — only visible in the flow logs.
- Goldmane reports host sources only as `Network/pvt`, no IPs; the node set is rendered from
  the node InternalIPs instead of trusting the whole kind subnet (host containers live there).
