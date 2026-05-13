[![CloudNativePG](./logo/cloudnativepg.png)](https://cloudnative-pg.io/)

# Local Learning Environment for CloudNativePG

Welcome to **`cnpg-playground`**, a local learning environment designed for
learning and experimenting with CloudNativePG using Docker and Kind.

## Prerequisites

Ensure you have the latest available versions of the following tools installed
on a Unix-based system:

- [Docker](https://www.docker.com/)
- [Git](https://git-scm.com/)
- [Helm](https://helm.sh/docs/intro/install/)
- [Kubectl](https://kubernetes.io/docs/tasks/tools/)
- [The `cnpg` plugin for `kubectl`](https://cloudnative-pg.io/documentation/current/kubectl-plugin/)
- [Kind](https://kind.sigs.k8s.io/)

You don't need superuser privileges to run the scripts, but elevated
permissions may be required to install the prerequisites.

### Additional Tools

For an improved experience with the CNPG Playground, it's recommended to
install the following tools:

- **[`curl`](https://curl.se/)**: Command-line tool for data transfer.
- **[`jq`](https://jqlang.github.io/jq/)**: JSON processor for handling API
  outputs.
- **[`stern`](https://github.com/stern/stern)**: Multi-pod log tailing tool.
- **[`kubectx`](https://github.com/ahmetb/kubectx)**: Kubernetes context
  switcher.

Recommended `kubectl` plugins:

- **[`view-secret`](https://github.com/elsesiy/kubectl-view-secret)**: Decodes
  Kubernetes secrets.
- **[`view-cert`](https://github.com/lmolas/kubectl-view-cert)**: Inspects TLS
  certificates.

These tools streamline working with the CNPG Playground.

## Local Environment Overview

This environment emulates a two-region infrastructure (EU and US), with each
region containing:

- An object storage service powered by [RustFS](https://rustfs.com/) containers
- A Kubernetes cluster, deployed using [Kind](https://kind.sigs.k8s.io/),
  consisting of:

    - One control plane node
    - One node for infrastructure components
    - One node for applications
    - Three nodes dedicated to PostgreSQL

The architecture is illustrated in the diagram below:

![Local Environment Architecture](images/cnpg-playground-architecture.png)

## Usage

This playground environment is managed by three main scripts located in the
`/scripts` directory.

| Script       | Description                                                  |
| :----------- | :----------------------------------------------------------- |
| `setup.sh`   | Creates and configures the multi-region Kubernetes clusters. |
| `info.sh`    | Displays status and access information for active clusters.  |
| `teardown.sh`| Removes clusters and all associated resources.               |

### Setting Up the Learning Environment

The `setup.sh` script provisions the entire environment. By default, it creates
two regional clusters: `eu` and `us`.

```bash
# Create the default two-region environment (eu, us)
./scripts/setup.sh
```

You can easily customize this by providing your own list of region names as
arguments.

```bash
# Create a custom environment with 'it' and 'de' regions, simulating Italy and Germany
./scripts/setup.sh it de

# Create a single-region environment
./scripts/setup.sh local
```

### Connecting to the Kubernetes Clusters

To configure and interact with both Kubernetes clusters during the learning
process, you will need to connect to them. After setup, you can run the
`info.sh` script at any time to see the status of your environment.

It automatically detects all running playground clusters and displays their
access instructions, and node status.

```bash
./scripts/info.sh
```

### Inspecting Nodes in a Kubernetes Cluster

To inspect the nodes in a Kubernetes cluster, you can use the following
command:

```bash
kubectl get nodes
```

For example, when connected to the `k8s-eu` cluster, this command will display
output similar to:

```console
NAME                   STATUS   ROLES           AGE     VERSION
k8s-eu-control-plane   Ready    control-plane   10m     v1.34.0
k8s-eu-worker          Ready    infra           9m58s   v1.34.0
k8s-eu-worker2         Ready    app             9m58s   v1.34.0
k8s-eu-worker3         Ready    postgres        9m58s   v1.34.0
k8s-eu-worker4         Ready    postgres        9m58s   v1.34.0
k8s-eu-worker5         Ready    postgres        9m58s   v1.34.0
```

In this example:
- The control plane node (`k8s-eu-control-plane`) manages the cluster.
- Worker nodes have different roles, such as `infra` for infrastructure, `app`
  for application workloads, and `postgres` for PostgreSQL databases. Each node
  runs Kubernetes version `v1.34.0`.

### Cleaning Up the Environment

When you're finished, the `teardown.sh` script can remove the resources. It can
be run in two ways:

#### Full Cleanup

Running the script with no arguments will auto-detect and remove all playground
clusters and their resources, returning your system to its initial state.

```bash
# Destroy all created regions
./scripts/teardown.sh
```

#### Selective Cleanup

You can also remove specific clusters by passing the region names as arguments.

```bash
# Destroy only the 'it' cluster
./scripts/teardown.sh it
```

## Monitoring with Prometheus and Grafana

The [`monitoring`](./monitoring/) directory provides instructions and resources
for setting up a monitoring environment based on Prometheus and Grafana.
Although this component is optional, it is highly recommended—especially for
demonstration and learning purposes—as it offers valuable insight into the
system's behavior and performance.

## Demonstration with CNPG Playground

The **CNPG Playground** offers a great environment for exploring the
**CloudNativePG operator** and the broader concept of running PostgreSQL on
Kubernetes.
It allows you to create custom scenarios and demo environments with ease.

To help you get started, we've included a demo scenario that showcases the
[**distributed topology** feature](https://cloudnative-pg.io/documentation/current/replica_cluster/).
This walkthrough guides you through deploying a **PostgreSQL cluster
distributed across two regions** within the playground. The symmetric
architecture also includes **continuous backup** using the
[Barman Cloud Plugin](https://cloudnative-pg.io/plugin-barman-cloud/).

For complete instructions and supporting resources, refer to the
[demo folder](./demo/README.md).

## Installing CloudNativePG on the Control Plane

If you plan to use the CNPG Playground without the demo mentioned earlier,
you'll need to install CloudNativePG manually.

To install the latest stable version of the CloudNativePG operator on the
control plane nodes in both Kubernetes clusters, execute the following
commands:

```bash
for region in eu us; do
   kubectl cnpg install generate --control-plane | \
      kubectl --context kind-k8s-${region} apply -f - --server-side

   kubectl --context kind-k8s-${region} rollout status deployment \
      -n cnpg-system cnpg-controller-manager
done
```

These commands will deploy the CloudNativePG operator with server-side apply on
both the `kind-k8s-eu` and `kind-k8s-us` clusters.

Ensure that you have the latest version of the `cnpg` plugin installed on your
local machine.

## Nix Flakes

Do you use Nix flakes? If you do, this package have a configured
dev shell that can be used with:

```
nix develop .
```

## Using Linux or WSL2

You may need:

```
sudo sysctl fs.inotify.max_user_watches=524288
sudo sysctl fs.inotify.max_user_instances=512
```

More information in the [relative ticket comment](https://github.com/kubernetes-sigs/kind/issues/3423#issuecomment-1872074526).

## Using Rancher Desktop

You may need to follow the instructions [in the Rancher Desktop
Guide](https://docs.rancherdesktop.io/how-to-guides/increasing-open-file-limit/)
to increase the open file limit.

```
provision:
- mode: system
  script: |
    #!/bin/sh
    cat <<'EOF' > /etc/security/limits.d/rancher-desktop.conf
    * soft     nofile         82920
    * hard     nofile         82920
    EOF
    sysctl -w vm.max_map_count=262144
    sysctl fs.inotify.max_user_watches=524288
    sysctl fs.inotify.max_user_instances=512
```

## Full Observability Stack

The [`monitoring`](./monitoring/) directory ships a production-grade
observability stack that goes beyond basic Prometheus and Grafana. All
components are deployed by `monitoring/setup.sh` and torn down by
`monitoring/teardown.sh`.

| Component | Role | Scope |
| :-------- | :--- | :---- |
| [Alloy](https://grafana.com/docs/alloy/) | Metrics scraper + log collector; sole scraper (no Prometheus pod) | Every region |
| [Mimir](https://grafana.com/docs/mimir/) | Long-term metrics store, multi-tenant | Hub region only |
| [Loki](https://grafana.com/docs/loki/) | Log aggregation (S3 backend via RustFS, 3-day retention) | Every region |
| [Tempo](https://grafana.com/docs/tempo/) | Distributed tracing backend | Hub region only |
| OTel Collector | OTLP tail-sampling gateway for non-hub regions | Hub region only |
| Grafana Operator | Manages Grafana instances, datasources, and dashboards declaratively | Every region |

### Metrics architecture

Alloy discovers `ServiceMonitor`, `PodMonitor`, and `Probe` CRs in
namespaces labelled `monitoring/scrape=enabled` and remote-writes to Mimir
with per-region tenant scoping (`X-Scope-OrgID: <region>`).
`PrometheusRule` CRs are synced to the Mimir Ruler automatically.

```
ServiceMonitors ──┐
PodMonitors    ───┼──> Alloy (per region) ──remote_write──> Mimir hub
Probes         ──┘
```

### Tracing architecture

Traefik emits OTLP traces. Hub region sends directly to
`tempo-distributor.tempo.svc.cluster.local:4317`; non-hub regions push via
an HTTP/4318 IngressRoute on the hub. The OTel Collector provides tail-based
sampling before forwarding to Tempo. Tempo's `metricsGenerator` emits span
metrics to Mimir (tenant `tempo`), enabling histogram exemplars that link
directly to traces in Grafana.

### Deploying the stack

```bash
# Deploy monitoring for the default two-region environment
./monitoring/setup.sh

# Deploy for custom regions
./monitoring/setup.sh it de
```

Access Grafana via port-forward (commands are printed by `setup.sh`):

```bash
kubectl port-forward service/grafana-service 3001:3000 -n grafana --context kind-k8s-eu
```

Default credentials: **admin / admin** (Grafana prompts for a password change on first login).

For full details — namespace allowlist, dashboard catalogue, Traefik access
log pipeline, PII warnings, and federated rules — see
[`monitoring/README.md`](./monitoring/README.md).

## Vault Integration

The [`vault/`](./vault/) directory and the scripts below deploy a standalone
[HashiCorp Vault](https://www.vaultproject.io/) container in dev-TLS mode,
connected to the `kind` Docker network and wired into every Kubernetes cluster
via a Kubernetes `Service` and a Traefik TCP `IngressRoute` on port 8200.

| Script | Description |
| :----- | :---------- |
| `scripts/vault-setup.sh` | Deploy Vault container and register it in each cluster |
| `scripts/vault-pki-setup.sh` | Bootstrap root + intermediate PKI engines; issue a `ClusterIssuer` for cert-manager |
| `scripts/vault-oidc-setup.sh` | Configure Vault OIDC auth method backed by Dex |
| `scripts/vault-eso-setup.sh` | Wire Vault's KV and Database engines to the External Secrets Operator |
| `scripts/vault-teardown.sh` | Remove the Vault container and all associated Kubernetes resources |

### Setup sequence

```bash
# 1. Start Vault (must be running before any other vault-* scripts)
./scripts/vault-setup.sh

# 2. Bootstrap PKI and cert-manager ClusterIssuer
./scripts/vault-pki-setup.sh

# 3. (Optional) Wire OIDC with Dex — requires dex-setup.sh to run first
./scripts/vault-oidc-setup.sh

# 4. Wire ESO (requires ESO to be installed — see below)
./scripts/vault-eso-setup.sh
```

The PKI setup creates a root CA, signs an intermediate CA, and registers a
`ClusterIssuer` in cert-manager that issues certificates via Vault's PKI
engine over `http://<vault-host>:8201`.

## External Secrets Operator (ESO)

[ESO](https://external-secrets.io/) is installed by `scripts/setup.sh` as
part of the base infrastructure. The `vault/eso/` directory contains the
`ClusterSecretStore` template that authenticates to Vault using an AppRole.

After Vault is running and `vault-eso-setup.sh` has been executed, ESO can
sync KV secrets and dynamic Database credentials from Vault into Kubernetes
`Secret` objects automatically.

```bash
# Install ESO for a specific region (called automatically by setup.sh)
REGION=eu CONTEXT_NAME=kind-k8s-eu ./scripts/eso-setup.sh
```

The `demo/eso-vault.sh` script provides a higher-level workflow that combines
Vault KV secret management with ESO-backed `ExternalSecret` resources for a
running CNPG cluster.

## Dex OIDC

The [`dex/`](./dex/) directory contains configuration for a
[Dex](https://dexidp.io/) identity provider. Dex is deployed as a container
on the `kind` Docker network and exposed via a sslip.io `IngressRoute`.

```bash
# Deploy Dex
./scripts/dex-setup.sh

# Remove Dex
./scripts/dex-teardown.sh
```

Once running, `vault-oidc-setup.sh` can wire Vault's OIDC auth method to Dex,
allowing Vault logins via the OIDC flow.

## Self-Service Multi-Tenant Demo

`demo/self-service-setup.sh` demonstrates a multi-tenant self-service pattern
combining Vault (KV + Database secrets engine), ESO, and CNPG. It provisions
a PostgreSQL cluster named `verstappen` in the `rbr-ver-db` namespace with
per-tenant Vault policies, AppRole credentials, and ESO-managed secrets.

```bash
# Full setup
./demo/self-service-setup.sh setup local

# Verify superuser connectivity
./demo/self-service-setup.sh verify local

# Print dynamic database credentials
./demo/self-service-setup.sh creds local <tenant-admin|group-admin|readonly>

# Rotate an ESO-managed credential
./demo/self-service-setup.sh rotate local <app|readonly>

# Trigger an on-demand backup
./demo/self-service-setup.sh backup local

# Remove all resources
./demo/self-service-setup.sh teardown local
```

The demo also deploys Grafana datasources and dashboards for the
`rbr-ver` namespace via `demo/yaml/self-service/grafana/`, enabling
per-tenant observability in the second Grafana instance (`grafana-rbr-ver`).

## pgAdmin

`demo/pgadmin-setup.sh` deploys [pgAdmin 4](https://www.pgadmin.org/) as a
web UI for the local PostgreSQL clusters. By default it targets all detected
playground clusters; pass region names to limit the scope.

```bash
# Deploy pgAdmin for all clusters
./demo/pgadmin-setup.sh

# Deploy pgAdmin for a specific region
./demo/pgadmin-setup.sh local

# Set a custom admin email
PGADMIN_EMAIL=you@example.com ./demo/pgadmin-setup.sh local

# Remove pgAdmin
./demo/pgadmin-teardown.sh
```

pgAdmin is exposed via a Traefik `IngressRoute` and pre-configured with
a `servers.json` that registers the cluster's primary PostgreSQL service
automatically.
