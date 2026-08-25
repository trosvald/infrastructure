# Repository Guidelines

## Project Overview

This repository manages personal infrastructure as declarative code:

- a Talos Kubernetes cluster bootstrapped with Helmfile and reconciled by Flux;
- Kubernetes applications layered with Kustomize, Flux `Kustomization`, `HelmRelease`, and
  `OCIRepository` resources;
- c0 Docker services deployed from Git by Doco-CD: OpenBao, PowerDNS Authoritative, and Omada
  Controller;
- an isolated Ansible project that renders and safely applies Junos SRX1500 intent.

There is no conventional application server or package build. Controller reconciliation is
asynchronous, but repository shell, Python, Ansible, and Just flows are synchronous and fail-fast.
There is no dependency-injection container, async framework, or local application state store.

## Architecture & Data Flow

### Talos, bootstrap, and Flux

1. `talos/` renders machine configuration from Minijinja templates and per-node inventory.
2. `bootstrap/helmfile/crds.yaml` installs required CRDs out of band.
3. `bootstrap/helmfile/apps.yaml` orders Cilium → CoreDNS → Spegel → cert-manager → External
   Secrets → Flux.
4. `kubernetes/apps/flux-system/flux-instance/app/helmrelease.yaml` syncs
   `./kubernetes/flux/cluster`.
5. `kubernetes/flux/cluster/ks.yaml` reconciles repositories, then `./kubernetes/apps`.
6. A normal app follows `kubernetes/apps/<namespace>/<app>/ks.yaml` →
   `app/kustomization.yaml` → `HelmRelease` or raw resources.

Preserve `dependsOn`, health checks, `prune`, namespace boundaries, and reconciliation order.
State belongs in PVC/Ceph resources; secrets come from External Secrets/1Password references or
existing `Secret` resources. Images are normally digest-pinned.

### Docker on c0

`docker/c0/.doco-cd.yaml` owns host deployment settings, while the bootstrap-owned controller
source lives in `docker/c0/.doco-cd/`. Doco-CD polls published `origin/main`; application projects
are direct children of `docker/c0/`, and host prerequisites live under `docker/c0/.host/`.

- OpenBao: Git → Doco-CD → Compose control plane; Raft and ACME data live in preserved named
  volumes. Certificate installation uses validated, fsynced generations and atomic symlink changes.
- PowerDNS: five canonical files under `docker/c0/powerdns/zones/` are the only zone-content source.
  `reconcile.sh` builds and validates a fresh SQLite candidate, then atomically replaces the live
  database. API, webserver, and host ports remain disabled.
- Blocky: DNS proxy with conditional forwarding of `monosense.io` and reverse zones to
  PowerDNS at `10.25.13.33`; external resolution via Cloudflare and Quad9 DoH; HaGeZi Multi NORMAL
  blocklist; read-only root, no named volumes, no persistent state.
- Omada Controller: preserved named volumes hold controller state; the rootless container attaches
  only to its dedicated external MGMT IPvlan network and publishes no host ports.

Never delete service volumes to solve deployment failures. Follow the component runbooks for
encrypted online backups and stopped restore procedures.

### Junos

`ansible/junos/scripts/dispatch.sh` exposes a fixed action set. Live actions pass through
`with-openbao-runtime.sh`, which validates OpenBao records, creates protected ephemeral files, and
enforces NETCONF host-key checking. `junos_intent.py` resolves topology references, validates
cross-domain invariants, and deterministically emits `ANSIBLE_SRX1500` Junos `set` commands plus a
SHA-256 digest. `roles/junos_intent/tasks/main.yml` verifies device identity and release before
exclusive check, diff, or a 10-minute commit-confirmed deployment.

Never bypass digest confirmation, commit-confirmed verification, host-key checks, identity/release
checks, or runtime cleanup.

## Key Directories

- `bootstrap/`: staged Talos/Kubernetes bootstrap and Helmfile ordering.
- `kubernetes/flux/`: root Flux reconciliation graph and repository sources.
- `kubernetes/apps/`: namespace/app declarations and dependency-gated reconciliation.
- `kubernetes/components/`: reusable Kustomize components.
- `talos/`: node inventory and machine/network Minijinja templates.
- `docker/c0/.doco-cd/`: bootstrap-owned Doco-CD controller source.
- `docker/c0/.host/`: c0 host prerequisites that Doco-CD must not manage.
- `docker/c0/`: host Doco configuration and direct-child OpenBao, PowerDNS, Blocky, and Omada
  Controller applications.
- `ansible/junos/`: isolated inventory, intent, roles, scripts, fixtures, and tests.
- `docs/`: operational, backup/restore, secret-custody, and migration runbooks.
- `scripts/`: repository-wide utilities, including the fail-closed Gitleaks wrapper.

## Development Commands

Install exactly the locked toolchain; mise manages tools, while Just executes repository tasks:

```sh
mise trust
mise install --locked
just -l
```

Primary validation:

```sh
just docker validate-c0
just ansible junos bootstrap
just ansible junos test
just ansible junos lint
scripts/gitleaks-scan.sh
```

Junos operator flow, after `bao login` and live-access preflight:

```sh
just ansible junos render
just ansible junos check
just ansible junos diff
just ansible junos deploy
just ansible junos verify
just ansible junos drift
just ansible junos backup
```

Cluster operations use `just bootstrap ...`, `just kube ...`, and `just talos ...`. Inspect exact
recipes with `just -l`; apply, delete, reset, upgrade, and bootstrap recipes may mutate live systems
and may require explicit confirmation.

## Code Conventions & Common Patterns

- `.editorconfig`: UTF-8, LF, final newline, two-space indentation by default; four spaces for
  Markdown, shell, and Just files.
- Formatter width is 100 (`.oxfmtrc.json`); Junos YAML lint permits 160 columns.
- Shell/Just code uses Bash with `set -euo pipefail`; POSIX service scripts use `set -eu`. Quote
  variables, validate inputs before mutation, use protected temporary directories, and trap cleanup.
- Kubernetes names are lowercase kebab-case. Preserve the adjacent
  `ks.yaml`/`app/kustomization.yaml` layout rather than creating another convention.
- Flux ordering belongs in `dependsOn` and health expressions. Do not script around controller
  readiness or replace declarative ownership with imperative mutations.
- Junos intent is split under `host_vars/srx1500/intent/`; Python renderers use `render_<domain>`,
  remain synchronous/deterministic, and raise `IntentError` with actionable messages.
- Junos object names are generally uppercase. Output must stay ordered, duplicate-free, safely
  quoted, and digest-stable.
- Ansible uses assertions and fatal failures; sensitive tasks use `no_log`. Live execution uses
  `serial: 1` and `any_errors_fatal: true`.
- Configuration is injected through manifests, environment variables, OpenBao, External Secrets,
  and Ansible variables. Durable state stays in Kubernetes storage, named Docker volumes, OpenBao
  Raft, or the managed device.
- Follow an adjacent implementation. Do not add Node/Bun tooling, a DI framework, or another state
  system to solve a declarative configuration problem.

## Important Files

- `.mise.toml`, `mise.lock`: authoritative tools, platforms, versions, checksums, and environment.
- `.justfile`, `*/mod.just`: public command surface and module wiring.
- `bootstrap/helmfile/{crds,apps,default}.yaml`: bootstrap content and ordering.
- `kubernetes/flux/cluster/ks.yaml`: root repository/application reconciliation.
- `kubernetes/apps/flux-system/flux-instance/app/helmrelease.yaml`: Flux source/path.
- `talos/machineconfig.yaml.j2`, `talos/networking.yaml.j2`: Talos machine/network defaults.
- `docker/c0/{openbao,powerdns,omada-controller}/compose.yml`: c0 service isolation and dependencies.
- `docker/c0/powerdns/scripts/reconcile.sh`: Git-to-SQLite authoritative reconciliation.
- `ansible/junos/scripts/{dispatch.sh,junos_intent.py,with-openbao-runtime.sh}`: Junos boundaries.
- `ansible/junos/roles/junos_intent/tasks/main.yml`: device safety and deployment workflow.
- `ansible/junos/ansible.cfg`: isolated inventory, collections, temp paths, and host-key checking.
- `.github/workflows/{docker,junos,gitleaks}.yaml`: CI validation behavior.
- `ansible/junos/README.md`, `docs/{OPENBAO,POWERDNS,OMADA}.md`: authoritative component guides.

## Runtime/Tooling Preferences

- Supported controllers: Apple Silicon macOS, x86-64 Linux, or WSL2 on the Linux filesystem.
  Native Windows and WSL paths under `/mnt/c` are unsupported.
- `mise` 2026.8.11+ and `mise.lock` are mandatory. Do not substitute Homebrew/system binaries.
- `just` is the sole task runner. Do not use `mise exec` as the repository execution interface.
- Python 3.13 runs Junos tooling. `uv` only resolves the hash-pinned
  `ansible/junos/requirements-controller.lock`; it is not a project runner.
- Regenerate dependency locks only with the command documented beside their input file.
- There is no npm/Bun, Make, Taskfile, Go, Rust, or conventional Python-package workflow.
- Keep runtime output untracked: root `kubeconfig`, `talosconfig`, `ansible/junos/.ansible/`,
  `ansible/junos/.build/`, Docker backup material, and Python caches.
- SOPS uses `~/.config/sops/age/keys.txt`; Junos live secrets come from OpenBao. Never commit real
  topology, credentials, Shamir material, rendered secrets, plaintext backups, or private keys.

## Testing & QA

- `just ansible junos test`: stdlib `unittest`, synthetic topology, two renders, and SHA-256
  determinism comparison.
- `just ansible junos lint`: yamllint, ansible-lint, and syntax checks for playbooks plus controller
  smoke configuration.
- `ansible/junos/tests/topology.yml` is synthetic only; keep RFC documentation addresses and fake
  identifiers. Tests must remain offline, deterministic, and secret-free.
- `just docker validate-c0`: OpenBao certificate installer unit/integration checks, SOPS/Compose
  structural assertions, disposable PowerDNS SQLite reconciliation/failure-atomicity checks, and
  Omada Controller Compose and external-network lifecycle checks.
- `scripts/gitleaks-scan.sh`: proves detection with a runtime canary before scanning all Git history
  and the working tree with redaction.
- CI runs Docker validation, Junos bootstrap/test/lint, and Gitleaks through path-scoped workflows.
  Python tests use stdlib `unittest`; there is no pytest/Molecule or coverage threshold.
- Static validation is not live proof. For infrastructure changes, also exercise the documented
  controller/device/service health and rollback path appropriate to the affected surface.
