# Repository Guidelines

## Project Overview

This repository manages personal infrastructure as declarative code. Its main concerns are:

- a Talos Kubernetes cluster bootstrapped with Helmfile and reconciled by Flux;
- Kubernetes applications defined with Kustomize, Flux `Kustomization`, and `HelmRelease` resources;
- a separately isolated Ansible project that renders and safely applies Junos SRX1500 intent.

There is no conventional application server, package build, dependency-injection container, async event loop, or mutable application state store.

## Architecture & Data Flow

### Kubernetes

1. `bootstrap/helmfile/crds.yaml` installs CRDs out of band.
2. `bootstrap/helmfile/apps.yaml` bootstraps Cilium → CoreDNS → Spegel → cert-manager → External Secrets → Flux.
3. `kubernetes/apps/flux-system/flux-instance/app/helmrelease.yaml` points Flux at `./kubernetes/flux/cluster` on `main`.
4. `kubernetes/flux/cluster/ks.yaml` reconciles repositories, then applications through dependency-gated Flux `Kustomization` resources.
5. A typical app follows `kubernetes/apps/<namespace>/<app>/ks.yaml` → `app/kustomization.yaml` → `HelmRelease` or raw resources.

Preserve `dependsOn`, health checks, `prune`, namespace boundaries, and reconciliation order. Workload state belongs in PVC/Ceph resources; secrets come from External Secrets or existing `Secret` references. Images are normally digest-pinned.

### Junos

`ansible/junos/scripts/dispatch.sh` exposes a fixed action set. Live actions pass through `with-openbao-runtime.sh`, which validates OpenBao records, creates protected ephemeral files, and enforces NETCONF host-key checking. `junos_intent.py` resolves topology references, validates cross-domain invariants, and deterministically emits Junos `set` commands plus a SHA-256 digest. `roles/junos_intent/tasks/main.yml` verifies device identity/release before exclusive check, diff, or a 10-minute commit-confirmed deployment.

Never bypass digest confirmation, commit-confirmed verification, host-key checks, identity/release checks, or runtime cleanup.

## Key Directories

- `bootstrap/`: staged Talos/Kubernetes bootstrap and Helmfile definitions.
- `kubernetes/flux/`: root Flux reconciliation graph and repository sources.
- `kubernetes/apps/`: namespace-scoped application declarations and dependencies.
- `kubernetes/components/`: reusable Kustomize components.
- `talos/`: node inventory and Minijinja machine/network configuration templates.
- `ansible/junos/`: isolated inventory, intent, roles, scripts, fixtures, and tests for the SRX1500.
- `docs/`: focused operational guidance, including SOPS and observability migration notes.
- `scripts/`: repository-wide utilities such as the Gitleaks wrapper.

## Development Commands

Install exactly the locked toolchain; do not substitute Homebrew/system binaries:

```sh
mise trust
mise install --locked
just -l
```

Offline Junos validation:

```sh
just ansible junos bootstrap
just ansible junos test
just ansible junos lint
scripts/gitleaks-scan.sh
```

Junos operator flow (requires `bao login` and live access):

```sh
just ansible junos render
just ansible junos check
just ansible junos diff
just ansible junos deploy
just ansible junos verify
just ansible junos drift
just ansible junos backup
```

Cluster operations are exposed through `just bootstrap ...`, `just kube ...`, and `just talos ...`; inspect exact recipes with `just -l`. These may mutate live infrastructure and frequently require confirmation.

## Code Conventions & Common Patterns

- `.editorconfig`: UTF-8, LF, final newline, two-space indentation by default; four spaces for Markdown, shell, and Just files.
- Formatter width is 100 (`.oxfmtrc.json`); YAML lint allows up to 160 columns (`.yamllint.yml`).
- Shell and Just recipes use Bash with `set -euo pipefail`; quote variables, validate arguments early, trap cleanup, and keep temporary material under protected/ignored paths.
- Kubernetes resources use lowercase kebab-case names and layered `kustomization.yaml`/`ks.yaml`/`app/` boundaries. Follow an adjacent app rather than introducing a second layout.
- Flux expresses ordering asynchronously through `dependsOn`, readiness/health expressions, and reconciliation. Do not script around controller state.
- Junos intent is split by domain under `host_vars/srx1500/intent/`. Python renderer functions follow `render_<domain>` and raise `IntentError` for actionable validation failures.
- Junos object names are generally uppercase. Renderer output must remain ordered, duplicate-free, safely quoted, and deterministic.
- Ansible uses assertions and fatal failures for safety; sensitive device tasks use `no_log`. Live device execution is serialized with `serial: 1` and `any_errors_fatal: true`.
- No dependency-injection or application state-management framework exists. Configuration is injected through declarative manifests, environment variables, OpenBao, and Ansible variables; durable state uses cluster storage.

## Important Files

- `.mise.toml`, `mise.lock`: authoritative runtime versions, platforms, environment defaults, and artifact locks.
- `.justfile`: root command surface and module wiring.
- `bootstrap/helmfile/{crds,apps}.yaml`: bootstrap ordering.
- `kubernetes/flux/cluster/ks.yaml`: Flux root reconciliation graph.
- `kubernetes/apps/flux-system/flux-instance/app/helmrelease.yaml`: GitOps source/path.
- `ansible/junos/scripts/{dispatch.sh,junos_intent.py,with-openbao-runtime.sh}`: Junos command, rendering, and secret-runtime boundaries.
- `ansible/junos/roles/junos_intent/tasks/main.yml`: device safety and deployment workflow.
- `ansible/junos/ansible.cfg`: isolated inventory, collections, temp paths, and connection settings.
- `.github/workflows/{junos,gitleaks}.yaml`: CI behavior.
- `ansible/junos/README.md`: authoritative Junos operator handbook.

## Runtime/Tooling Preferences

- Required controller platforms: Apple Silicon macOS, x86-64 Linux, or WSL2 on the Linux filesystem; native Windows and WSL paths under `/mnt/c` are unsupported.
- `mise` version `2026.8.11` or newer is mandatory; `.mise.toml` and `mise.lock` define the toolchain.
- `just` is the sole task runner. There is no npm/Bun, Make, Taskfile, Go, Rust, or conventional Python-package workflow.
- Python 3.13 runs the Junos tooling. `uv` only resolves the hash-pinned `requirements-controller.lock`; do not treat it as a project runner.
- Regenerate that lock only with the command documented in `ansible/junos/requirements-controller.in`.
- Keep generated/runtime files untracked: root `kubeconfig`, `talosconfig`, `ansible/junos/.ansible/`, `ansible/junos/.build/`, and Python caches.
- SOPS uses `~/.config/sops/age/keys.txt`; Junos live secrets come from OpenBao, not SOPS. Never commit real topology, credentials, rendered secrets, or backups.

## Testing & QA

The only test suite is `ansible/junos/tests/`, using stdlib `unittest`.

- `test_intent.py`: deterministic rendering, ownership, ordering, quoting, duplicate prevention, topology validation, and password-hash exclusion.
- `topology.yml`: the sole synthetic fixture; keep it restricted to RFC documentation ranges and fake identifiers.
- `controller-smoke.yml` / `controller_smoke.py`: pinned dependency, import, XML, and PyEZ initialization smoke checks without connecting to a device.
- `just ansible junos test`: runs unit tests, renders twice, and compares SHA-256 output.
- `just ansible junos lint`: runs YAML lint, Ansible lint, and playbook syntax checks.
- `scripts/gitleaks-scan.sh`: verifies the scanner with a canary, then scans all Git history and the working tree.

CI runs Gitleaks, Junos bootstrap, tests, and lint. No coverage tool or threshold is configured. Tests must remain offline, deterministic, and secret-free; never replace `tests/topology.yml` with production data.
