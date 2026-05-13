# Contributing to CloudNativePG

Thank you for your interest in contributing! 💖

To ensure consistency across the project, all CloudNativePG repositories follow
a common set of guidelines regarding code of conduct, AI usage, and
contribution workflows.

Please review the [CloudNativePG Project contributing guidelines](https://github.com/cloudnative-pg/governance/blob/main/CONTRIBUTING.md)
before searching for issues, reporting bugs, or submitting a pull request.

## Development Setup

See README.md for prerequisites and first-run instructions.

The playground is a shell-script and YAML-driven Kind-based environment. No
package manager install step is required. To get started:

1. Clone the repository: `git clone https://github.com/cloudnative-pg/cnpg-playground`
2. `cd cnpg-playground`
3. Run `./scripts/setup.sh` to bring up the full cluster stack.

See README.md for the full prerequisite tool list (kind, kubectl, helm, etc.).

## Coding Standards

This repository contains shell scripts and Kubernetes/Helm YAML manifests. No
automated linter is configured. Follow these conventions:

- Shell scripts: use `bash` shebang (`#!/usr/bin/env bash`), `set -euo pipefail`, and source `scripts/common.sh` for shared helpers.
- YAML manifests: indent with 2 spaces; keep resource definitions in the directory that matches their concern (`monitoring/`, `demo/`, `vault/`, etc.).
- Template files: use `.tpl` suffix for files that require variable substitution before applying.
- No convention documented for automated formatting enforcement.

## PR Guidelines

- Branch from `main`; use descriptive branch names (e.g., `feat/mimir-alerting`, `fix/otel-endpoint`).
- Keep commits focused — one logical change per commit.
- Reference the relevant issue or context in the PR description.
- Test your changes locally by running the affected setup scripts against a fresh Kind cluster before submitting.
- All PRs require at least one review from a `@cloudnative-pg/maintainers` member (see CODEOWNERS).
- Follow the upstream [contribution workflow](https://github.com/cloudnative-pg/governance/blob/main/CONTRIBUTING.md) for commit signing and DCO requirements.

## Issue Reporting

Report bugs and request features via [GitHub Issues](https://github.com/cloudnative-pg/cnpg-playground/issues).

When reporting a bug, include:

- Steps to reproduce (which script or manifest, exact command run)
- Expected behavior
- Actual behavior (error output, kubectl describe output, etc.)
- Environment: OS, Docker/Podman version, Kind version, kubectl version
