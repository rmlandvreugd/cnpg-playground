<!-- generated-by: gsd-doc-writer -->
# Getting Started

This guide walks you from zero to a running CloudNativePG playground environment.

---

## Prerequisites

### Required tools

The following tools must be present on a Unix-based system before running any script. No superuser privileges are required to run the scripts themselves, but you may need elevated permissions to install these tools.

| Tool | Purpose |
| :--- | :------ |
| `docker` or `podman` | Container runtime (either is supported) |
| `kind` | Creates local Kubernetes clusters |
| `kubectl` | Interacts with Kubernetes clusters |
| `kubectl cnpg` plugin | CloudNativePG-specific kubectl commands |
| `helm` | Installs Kubernetes components via charts |
| `git` | Clones this repository |
| `jq` | Parses JSON output from scripts |
| `envsubst` | Template substitution used by setup scripts |
| `sed`, `grep` | Text processing used by setup scripts |

The setup script validates all required commands on startup and exits with a clear error if any are missing.

### Recommended tools

| Tool | Purpose |
| :--- | :------ |
| `curl` | Data transfer and API testing |
| `stern` | Multi-pod log tailing |
| `kubectx` | Kubernetes context switching |
| `k9s` | Terminal UI for Kubernetes |
| `kubectl view-secret` plugin | Decodes Kubernetes secrets |
| `kubectl view-cert` plugin | Inspects TLS certificates |

### System requirements (Linux / WSL2)

Kind clusters require higher inotify limits than the Linux defaults. The `scripts/common.sh` checks these values and calls `scripts/tune-sysctl.sh` automatically if they are too low. If you need to set them manually:

```bash
sudo sysctl fs.inotify.max_user_watches=524288
sudo sysctl fs.inotify.max_user_instances=512
```

### System requirements (Rancher Desktop)

Add a provisioning script in Rancher Desktop settings to raise the open file limit and inotify values. See the [Rancher Desktop guide](https://docs.rancherdesktop.io/how-to-guides/increasing-open-file-limit/) for details.

### Nix flake (optional)

If you use Nix flakes, a pre-configured dev shell provides all required and recommended tools:

```bash
nix develop .
```

---

## Installation steps

1. Clone the repository:

   ```bash
   git clone https://github.com/cloudnative-pg/cnpg-playground.git
   cd cnpg-playground
   ```

2. Verify required tools are available (the setup script performs this check automatically, but you can confirm manually):

   ```bash
   for cmd in kind kubectl helm git grep sed envsubst jq; do
     command -v "$cmd" || echo "MISSING: $cmd"
   done
   ```

3. Confirm a container runtime is available:

   ```bash
   docker version   # or: podman version
   ```

---

## First run

Provision the default two-region environment (`eu` and `us`):

```bash
./scripts/setup.sh
```

This single command creates two Kind clusters (`k8s-eu`, `k8s-eu`) each with six nodes, starts RustFS object-storage containers for backup storage, and sets up MetalLB, Traefik, cert-manager, and the CloudNativePG operator.

When setup completes, verify the clusters are healthy:

```bash
./scripts/info.sh
```

Expected node output for the `k8s-eu` cluster:

```console
NAME                   STATUS   ROLES           AGE     VERSION
k8s-eu-control-plane   Ready    control-plane   10m     v1.34.0
k8s-eu-worker          Ready    infra           9m58s   v1.34.0
k8s-eu-worker2         Ready    app             9m58s   v1.34.0
k8s-eu-worker3         Ready    postgres        9m58s   v1.34.0
k8s-eu-worker4         Ready    postgres        9m58s   v1.34.0
k8s-eu-worker5         Ready    postgres        9m58s   v1.34.0
```

---

## Common setup issues

**Missing required command**
The script exits immediately with `❌ Error: Missing required command: <name>`. Install the missing tool and re-run `./scripts/setup.sh`.

**Existing playground clusters detected**
If a previous run left clusters behind, setup refuses to proceed:

```
❌ Error: Found N existing playground cluster(s).
Please run './scripts/teardown.sh' to remove the existing environment before running setup.
```

Run `./scripts/teardown.sh` and then retry setup.

**inotify limits too low**
The setup script auto-detects this and calls `scripts/tune-sysctl.sh`. If that script cannot apply changes (e.g., no sudo), apply the values manually:

```bash
sudo sysctl fs.inotify.max_user_watches=524288
sudo sysctl fs.inotify.max_user_instances=512
```

**No container runtime found**
Both `docker` and `podman` are checked. If neither is on `PATH`, setup exits with:

```
❌ Error: Missing container provider. Supported providers are: docker, podman
```

Install Docker or Podman and ensure it is available on your `PATH`.

---

## Cleanup

Remove all playground clusters and their resources:

```bash
./scripts/teardown.sh
```

Remove a specific region only:

```bash
./scripts/teardown.sh eu
```

---

## Next steps

- **[DEVELOPMENT.md](../CONTRIBUTING.md)** — how to contribute changes to this repository
- **[Configuration Reference](CONFIGURATION.md)** — every configurable environment variable and its default
- **[Architecture](architecture.md)** — system design and component diagram
- **Demo** — run `./demo/setup.sh` for a full distributed PostgreSQL topology walkthrough
- **Monitoring** — run `./monitoring/setup.sh` to deploy the observability stack (Mimir, Tempo, Loki, Grafana)
