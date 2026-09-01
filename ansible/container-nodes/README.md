# Container-node Ansible

This isolated project manages Debian hosts `c0` and `c1`. It owns host state and resident lifecycle gates. Doco-CD remains the only owner of application Compose deployment, creation, and recreation; these playbooks never run application Compose lifecycle commands.

## Controller setup

Use the repository's locked mise environment. Galaxy dependencies are pinned centrally in `ansible/requirements.yml`; this project uses `ansible.posix` 2.2.2 for sysctl and mount behavior and does not use `community.docker` because immutable Docker-network drift must fail instead of disconnecting endpoints or recreating networks.

```console
mise trust
mise install --locked
just ansible container-nodes bootstrap
```

Bootstrap verifies Python 3.13 and ansible-core 2.21, installs the central pinned collections into this project's private `.ansible/collections`, and verifies required module documentation. A clean c0 bootstrap may use `10.25.10.100` only as a temporary operator-controlled resolver while Blocky is unavailable. Remove it immediately after Blocky acceptance; routine baseline deployment requires only `10.25.13.35` and fails if the bootstrap resolver remains.

## Trust and adoption gates

The inventory connects as `monosense` over the management addresses `10.25.10.20` and `10.25.10.101`. `ansible.cfg` forces the committed `inventory/known_hosts` file, strict host-key checking, host-IP checking, and disabled host-key updates. That trust file is intentionally empty until both public host keys are independently verified; live commands therefore fail closed rather than using TOFU.

`adoption.yml` tracks c0 and c1 independently. Each record binds `adopted`, contract version, audit schema version, and the lowercase SHA-256 of the reviewed deterministic sanitized audit. The repository never updates adoption automatically. Before setting one host to `adopted: true`:

1. independently verify and commit its SSH host key and reviewed `monosense` public login keys;
2. populate the complete audited `/etc/network/interfaces` text, its SHA-256, physical activation order, and container-path probes in that host's variables;
3. run `audit`, review the sanitized artifact, and copy its exact digest into only that host's adoption record;
4. adopt c1 first, preserving staged networks and storage, then c0 without recreating `c0_services`.

Every mutating action immediately re-audits the host and refuses a missing, malformed, stale, or cross-host digest. Live plays are serial and fail the entire run on the first host error.

## Fixed actions

```console
just ansible container-nodes <action>
```

| Action | Behavior |
|---|---|
| `bootstrap` | Validate and install the locked controller environment. |
| `test` | Run deterministic offline Python and shell fixtures. |
| `lint` | Lint YAML/Ansible, parse shell entrypoints, and syntax-check every playbook. |
| `audit` | Collect read-only canonical sanitized evidence and a per-host digest. |
| `check` | Run check-mode-safe preflight and declared-state comparison before or after adoption. |
| `diff` | Show redacted check-mode file/config differences and role-reported imperative changes. |
| `deploy` | Converge adopted non-secret host state without network activation, Docker restart, storage provisioning, secret changes, or application recreation. |
| `verify` | Verify host prerequisites; optionally select application or OpenBao checks as described below. |
| `drift` | Compare declared state read-only and fail on adopted identity-critical drift. |
| `provision-storage` | Enter the c1-only plan/digest/private typed-approval storage transaction. |
| `provision-secrets` | Validate records and transactionally install scoped protected runtime material. |
| `rotate-secrets` | Stage, verify, commit, and compensate scoped credential rotation before old-accessor revocation. |
| `prepare-applications` | Start c1 Doco and require the published TLS libreFS contract without stopping libreFS on failure. |
| `rollout-applications` | Start the adopted c1 Doco controller, wait for Doco-created projects, start exact prerequisite gates, and compensate by stopping gates/controller on failure. |
| `activate-network` | Require reviewed OOB proof, arm rollback, activate one host, and prove a fresh management path. |
| `upgrade` | Install only the reviewed exact package versions and report service impact. |
| `reboot` | Reboot one adopted host at a time and verify recovery and rollback paths. |

The dispatcher rejects unknown actions and all trailing arguments. Destructive storage inputs are private Ansible prompts, not command-line arguments.

`verify` defaults to host-only checks. Select explicit non-host checks without weakening dispatcher grammar:

```console
CONTAINER_NODES_VERIFY_SCOPE=applications just ansible container-nodes verify
CONTAINER_NODES_VERIFY_SCOPE=openbao \
CONTAINER_NODES_OPENBAO_TOKEN_FILE=/private/ephemeral/token \
  just ansible container-nodes verify
CONTAINER_NODES_VERIFY_SCOPE=all \
CONTAINER_NODES_OPENBAO_TOKEN_FILE=/private/ephemeral/token \
  just ansible container-nodes verify
```

The OpenBao token path is controller-local protected runtime input and is never stored in inventory. OpenBao must be explicitly unsealed for OpenBao or application-secret verification.

Direct `provision-secrets`, `rotate-secrets`, and OpenBao verification actions require
`CONTAINER_NODES_OPENBAO_TOKEN_FILE` to name a root/user-protected ephemeral controller file.
The public `just provision-container-secrets` and `just verify-container-applications` recipes
authenticate as `monosense-infra`, stage that file, and revoke the short-lived token afterward.

On first c1 provisioning, protected files and scoped tokens are committed before Doco creates the
Forgejo container. The one-time administrator transition is therefore skipped only while that
container is absent. After Doco creates Forgejo, rerun `provision-secrets`; it must then complete
the final-password transition, revoke its temporary token, and remove every bootstrap projection.

First application bootstrap is ordered:

1. `just provision-openbao-applications` creates the absent application records through
   `monosense-infra`, creates the scoped libreFS backup identity through a protected SSH tunnel to
   the pre-TLS service, and publishes the initial wildcard certificate.
2. `just provision-container-secrets` materializes protected files, the wildcard certificate, and
   service tokens while Forgejo is absent.
3. `just prepare-container-applications` normalizes the protected Doco API secret, refreshes its
   scoped token, starts Doco, and proves the published TLS libreFS contract.
4. `just ansible container-nodes rollout-applications` starts the exact project gates and waits for
   representative application health.
5. Rerun `just provision-container-secrets` to complete and verify the one-time Forgejo
   administrator transition.

## Safety boundaries

Before deploy changes any managed file, it atomically captures the exact
allowlisted non-secret host files under
`/var/lib/monosense-ansible/rollback/<generation>/`. The canonical manifest,
file metadata/checksums, and fsynced completion marker bind the generation to
the host, contract, and reviewed audit digest. Only the newest five complete
root-only generations are retained. Application/engine state and
`/opt/doco-cd/secrets` are structurally forbidden from this rollback path.

Routine deploy never activates interfaces, restarts Docker, partitions or formats storage, reads ordinary protected files, deploys applications, or reconciles Doco stacks. Critical network, storage, firewall, SSH trust, secret custody, Docker-network, and Doco-ownership drift blocks mutation. The c1 storage action alone can reach destructive behavior and requires the exact by-id device, reviewed plan digest, and typed approval. Public CI runs secret scan, bootstrap, test, and lint only; it receives no SSH key, SOPS identity, OpenBao token, or live-host credential.
