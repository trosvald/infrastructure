# c1 Operations

Date: 2026-08-26
Historical 2026-08-26 status: mission live gates completed under the predecessor host contract;
container-node Ansible adoption and convergence remain unclaimed. The recorded final status was
`OPERATIONAL_WITHOUT_DURABILITY` solely because
no off-host libreFS backup target/restore exists on c1 (no durability claim). User approved
controlled c1 reboot; outage and SSH recovery observed. Post-reboot verification passed: both
XFS noatime mounts and assertion units, Docker, c1 SERVICES network/shim, exact management
default route, active-backup bond/VLAN with two 10 Gb members and zero link-failure counts,
Doco/OpenBao token/controller canaries, healthy pinned `librefs-c1` at `.65` with no host ports and
credential files UID/GID 1000 mode 0400. Exact-value leakage and writable-root containment
scans passed again after reboot. Scoped S3 ready/upload/stat/download/checksum/delete/denial
passed again after reboot; 512 MiB observed 542,280,200 B/s upload and 2,014,577,014 B/s download
(post-reboot confirmation, not a replacement of the pre-reboot baseline of 567,957,345 B/s
upload and 1,863,741,635 B/s download). User explicitly skipped optional bond-member
failover; record intentionally not exercised, not a blocker. PR8 merged at
`599fff0e01301d77f5a2e204bac5df9a519f1823`; its then-installed libreFS rematerialization helper is
historical live evidence, now maintained under `ansible/container-nodes/roles/runtime_assets/`.
Those earlier mission gates do not claim that the later container-node Ansible contract is adopted
or converged. The pre-reboot S3/perf/backup evidence is preserved:
512 MiB same-host Docker-network S3 baseline on `c1_services` against libreFS — upload
567,957,345 B/s, download 1,863,741,635 B/s (local bridge + storage + application evidence,
not external 10 Gb/s proof); workstation-to-c1 SERVICES TCP baseline over the actual routed
path — sender 113,948,113 bit/s, receiver 112,622,607 bit/s for 256 MiB (path and workstation
limited, not bond-capacity evidence); off-host libreFS backup verified as unconfigured and unproven
(Doco manages only `doco-cd-c1` and `librefs-c1`; only Debian `dpkg-db-backup` units exist
on c1; no restore was possible). User explicitly skipped optional bond-member failover.

This runbook is subordinate to `DESIGN-AND-PLAN.md`, `REVIEW.md`, `SECRET-CONTRACT.md`, and
`LIBREFS.md`. Repository validation is safe, offline, and pinned: `docker/c1` activates the
exact Docker Compose 5.5.0 plugin locked in `.mise/mise.lock`. Doco 0.111.0 embeds Compose
v5.5.0, so the runtime credential canary executes the same Compose injection semantics in
local and CI as in live Doco:
```sh
just docker validate-c1
```

Do not continue past any failed checkpoint. All supported host operations run from the trusted
controller through the fixed dispatcher; unknown actions and trailing arguments are rejected:

```sh
just ansible container-nodes bootstrap
just ansible container-nodes audit
just ansible container-nodes check
just ansible container-nodes diff
```

`bootstrap` installs only the locked controller environment. `audit`, `check`, and `diff` are
non-mutating and permitted before adoption. Review c1's independently verified SSH host key,
complete network/baseline inventory, sanitized canonical audit, and digest. Adoption is per-host:
the reviewed digest, contract version, and audit schema must match `adoption.yml`; the repository
never changes that record automatically. Adopt c1 before c0 and preserve the staged empty networks,
mounts, quotas, interface fragment, units, and stopped Doco controller.

## Storage checkpoint

Routine deployment can assert and converge the already-installed c1 UUID, XFS mounts, fstab,
project mappings, quotas, bind sources, and resident gates, but cannot partition or format:

```sh
just ansible container-nodes deploy
just ansible container-nodes verify
```

`deploy` requires the adoption digest, re-audits identity-critical state, writes checksummed
non-secret rollback generations, and refuses root-disk, UUID/label/filesystem, mount, quota,
symlink, or fallback-directory drift. It does not restart Docker or start/recreate applications.

Destructive storage is reachable only through:

```sh
just ansible container-nodes provision-storage
```

That c1-only action uses private Ansible prompts for the exact stable by-id device and mandatory
typed approval. It generates and displays a reviewed plan and SHA-256, revalidates the OS-disk and
quarantined-device exclusions immediately before mutation, applies one host serially, persists
pending state, and verifies each filesystem before committing fstab. Changed evidence invalidates
approval; retries never reformat completed state. Formatting cannot recover unknown prior content,
and routine `deploy`, tags, handlers, drift checks, or retries cannot reach this action.

## Network and external-network checkpoint

Ansible owns the complete c1 ifupdown intent and the `c1_services`, EDGE, Forgejo frontend, and host
shim contracts under `ansible/container-nodes/roles/network/`. First review:

```sh
just ansible container-nodes audit
just ansible container-nodes check
just ansible container-nodes diff
```

Routine `deploy` writes reviewed configuration without activating interfaces, bouncing networking,
restarting Docker, deleting a drifted Docker network, or disconnecting endpoints. Existing exact
networks are adopted in place; creation occurs only after an exact not-found result and immediate
post-create verification. Immutable drift, a parent address, wrong VLAN/MTU, unexpected endpoints,
or management-route/DNS drift blocks.

Network activation is a distinct maintenance transaction:

```sh
just ansible container-nodes activate-network
```

It requires independently confirmed console/OOB access, captures pre-change state, arms a timed
rollback, activates one host serially, then proves fresh SSH, management route, Blocky DNS, VLAN
identity, shim routes, and container paths before cancelling rollback. Never use direct `ifup`,
host scripts, or manual systemd changes as a substitute. There is no routine network-removal
action; attached networks are never removed to repair drift.

## EDGE, Forgejo, wildcard, and monitoring checkpoint

The c1 uplink bond is active-backup across TOR1/TOR2, not LACP. Do not change the bond. Before
installation, capture read-only switch evidence that VLAN 2515 `EDGE` is tagged on both SRX TOR
trunks and the c1 uplinks. Missing membership blocks all host and SRX mutation.

Do not install or start individual files, helpers, timers, or units. After the switch evidence and
adoption digest are reviewed, use the explicit host gates:

```sh
just ansible container-nodes deploy
just ansible container-nodes activate-network
just ansible container-nodes provision-secrets
CONTAINER_NODES_VERIFY_SCOPE=all \
CONTAINER_NODES_OPENBAO_TOKEN_FILE=/private/ephemeral/token \
  just ansible container-nodes verify
```

`deploy` installs the additive network intent, storage/quota assertions, repository firewall,
Doco controller, and resident runtime helpers from `ansible/container-nodes/roles/`, but neither
activates networking nor deploys/recreates applications. `activate-network` requires OOB proof and
must establish VLAN 2515 with no host L3 address while preserving the active-backup bond and
management path.

Application KV values remain operator-entered through the approved Bao workflow. Ansible does not
create or update them. `provision-secrets` requires OpenBao to be explicitly unsealed, authenticates
controller-side through protected OpenBao/SOPS material, validates exact record schemas/versions,
named token roles, capabilities, shared values, and consumer prerequisites, then atomically installs
the scoped publisher/reader/application material. It uses `no_log`, disabled diffs/fact caching,
exact 0700 parents and 0400/0600 files, staged verification, compensation, and old-accessor
retention. A failed wildcard fetch or validation keeps the prior generation.

Activate private infrastructure in this order:

1. publish the reviewed application commit to `origin/main`;
2. complete adopted non-secret host `deploy`, then the separately approved `activate-network`;
3. complete `provision-secrets` and all host verification while OpenBao is explicitly unsealed;
4. let Doco poll and perform the first EDGE/Forgejo application deployment with WAN destination NAT
   absent—Ansible never substitutes application Compose commands;
5. use `provision-secrets` for the one-time Forgejo administrator transaction: generate the
   temporary password/token under `no_log`, set the final OpenBao-held password through Forgejo's
   API, revoke the token, verify the administrator, and remove all bootstrap projections;
6. configure and prove the one-way public GitHub mirror while GitHub remains authoritative;
7. allow the Ansible-installed backup timer only after a first verified backup and isolated
   Forgejo/PostgreSQL restore; then prove the Gatus heartbeat;
8. run application-scoped `verify` and keep all dependent projects stopped on any prerequisite
   failure.

Candidate A is `edge.public_enabled: false`. Deploy it through the existing commit-confirmed
workflow and prove: `irb.2515` at `10.25.15.1/24`; no WAN-to-EDGE policy or destination NAT;
internal access only to HAProxy TCP 22/80/443; HOME access to Gatus HTTPS; and no EDGE-initiated
MGMT/PROD/HOME/DEV sessions. Prove HAProxy approved SNI, missing/unlisted SNI rejection, forged
forwarding-header replacement, 20-current/60-per-10-second connection limits,
300-requests-per-10-second limiting, generic AppSec denial, SPOA-only bypass, country denial,
PROXYv2 SSH, and the 10 GiB upload boundary.

Candidate B requires all prior evidence plus the stable MYREP IPv4 from OpenBao, external
reachability of TCP 22/80/443, an active CrowdSec/AppSec path, healthy Vector/Gatus evidence, and a
verified backup. Run `just enable-junos-public-edge`, review `just ansible junos diff`, and deploy
the exact digest commit-confirmed. `just disable-junos-public-edge` renders the rollback candidate;
deploy that candidate before removing public DNS if any public check fails. After direct-origin
tests pass, create DNS-only `edge.monosense.io A <MYREP IPv4>`, then
`edge-test.monosense.io CNAME edge.monosense.io` and
`git.monosense.io CNAME edge.monosense.io`, with `proxied=false` and no AAAA records. Remove the
temporary `edge-test` record and echo backend after acceptance. Retain the private deployment
during rollback.

The Kopia repository at `https://s3.monosense.io` uses a scoped non-root identity, retains 30 daily
and 12 monthly snapshots, and deletes staging only after snapshot verification. It is on the same
c1 host and physical 1 TB device as the source. It does not survive host or disk loss and is not
off-host durability.

## Forgejo front-page customization recommendation

Keep `LANDING_PAGE = home` and the configured `APP_NAME` for initial acceptance. Do not customize
the login template or replace Forgejo's embedded assets before the private web, Git, mail, mirror,
backup, and restore checks pass.

For a later branded landing page, use one Git-owned, read-only custom directory mounted at
`/var/lib/gitea/custom`. Pin `templates/home.tmpl` to the exact Forgejo release and keep any CSS in
`public/assets/css/`; do not edit files inside the image, inject remote JavaScript, use a CDN, or
make the custom directory application-writable. The page should contain only:

- a short monosense identity and purpose statement;
- sign-in and public-repository links;
- the public status-page link;
- no private repository names, recent activity, service topology, software versions, internal
  hostnames, monitoring details, or operator email.

Template overrides are an unsupported, upgrade-coupled Forgejo surface. On every Forgejo patch,
compare the pinned upstream `home.tmpl`, render the anonymous and authenticated home pages at mobile
and desktop widths in both themes, verify login and public-repository navigation, and reject the
upgrade if the override produces template errors or omits security/navigation controls. Prefer
supported `app.ini` branding and a small CSS override when they meet the requirement; use a full
`home.tmpl` only when custom page structure is necessary.

## OpenBao token lifecycle

OpenBao checkpoint completed: policy `doco-c1` installed; KV v2 `kv/docker/c1/librefs` v1
provisioned with the exact `root_user`/`root_password` keys; orphan periodic 24h token issued
with self-lookup and self-renew only; policy allows only `kv/data/docker/c1/librefs` (read),
`auth/token/lookup-self`, and `auth/token/renew-self`; all unrelated capabilities are denied;
audit file device enabled. Multi-recipient Raft snapshot captured to the workstation and
encrypted under the offline-recovery age boundary; structural verification passed
(`meta.json`, `state.bin`, `SHA256SUMS`, `SHA256SUMS.sealed`); internal SHA256SUMS verified
(no snapshot-inspect on the installed bao; structural and internal checksums are the reviewed
evidence). The first capabilities-self call returned 403 because the no-default Doco policy
cannot call `capabilities-self`; recovery used a short-lived admin token via
`sys/capabilities-accessor` and did not broaden the Doco policy. The short-lived admin token
was revoked and removed. No secrets, recipients, hashes, or token values are recorded here.
Off-host libreFS backup/restore remains separate and unproven.

Application KV values enter only through the approved operator Bao workflow and are never printed.
Container-node Ansible validates exact schemas and versions and consumes scoped outputs; it does
not create or update application KV records. OpenBao must be explicitly unsealed for either
secret action:

```sh
just ansible container-nodes provision-secrets
just ansible container-nodes rotate-secrets
```

`provision-secrets` installs the controller API secret, exact Doco token, renewal/TTL gates,
publisher/readers, application files, and resident systemd assets transactionally. It requires the
adopted-host digest; TLS/SNI, KV v2, audit, role/policy/period, allowed and denied capability,
shared-value, record-version, consumer, and encrypted-recovery gates must all pass. Plaintext stays
in a controller-side protected ephemeral directory under `no_log` with diffs and fact caching
disabled. Staging uses exact 0700 parents, 0400/0600 files, fsync, atomic rename, and compensation.

`rotate-secrets` retains old accessors, validates and stages replacements, commits one consumer at a
time, verifies its runtime state, and revokes old accessors only after success. Failure restores the
prior protected file and consumer state, verifies the restoration, and revokes the replacement.
The Doco provider canary requires public `main` to contain the exact mapping, controller health, and
a successful authenticated tracked poll.

Doco 0.111.0 does not rematerialize changed ordinary KV values when Git is unchanged. For libreFS,
the action invokes the resident helper sourced from
`ansible/container-nodes/roles/runtime_assets/files/rematerialize-c1-librefs-credentials`. It stops
the exact project through the authenticated lifecycle gate, removes only the stateless container,
lets Doco recreate with current values, normalizes provenance to remote `main`, verifies, and
cleans temporary state. Operators never invoke that helper directly. `/data`, named volumes, and
application Compose ownership are untouched. An unverified replacement is compensated or left
stopped for correction.

Ordinary `deploy` remains independent of OpenBao availability, preserves protected files without
reading them, and never starts/recreates Doco applications. At boot, Ansible-installed lifecycle
units call only Doco's authenticated project start/stop API for already-created containers after
storage, network, firewall, token, and certificate gates. Missing first deployments remain Doco's
poll responsibility; prerequisite failure leaves dependents stopped and journals the cause.

## Controller and libreFS checkpoint

Live Doco 0.111.0 rejected the original Compose `secrets.environment` source for the libreFS
credentials (only `file` is supported). The first deploy failed before container creation; no
credential material was rendered. The corrected pattern uses top-level Compose `configs.content`
populated from the Doco-resolved `LIBREFS_ROOT_USER` and `LIBREFS_ROOT_PASSWORD` variables and
mounted at `/run/secrets/librefs_root_user` and `/run/secrets/librefs_root_password` with mode
`0400`, UID/GID `1000`. These are config-backed credential files, not Docker secrets. The
container environment still exposes only the `_FILE` paths. Resolved values exist only in
Doco's in-memory rendered project and may be materialized in protected engine or Doco artifacts
during the deploy window. A full exact-value leakage scan covering container environment,
rendered Compose output, project labels, runtime secret/config metadata, Doco logs/working
trees/data volume/persisted deployment artifacts, Docker and containerd metadata, journald,
application logs, temporary directories, and backup inputs was a blocking live canary at PR6
design time. PR6 (`3ff1aaf1facc23f6f85e5c95bc80b9e599289207`) is merged; the scan passed on
the merged artifact. The credential rotation leakage gate is closed: OpenBao KV v2
`kv/docker/c1/librefs` was rotated twice with CAS ending at version 3, and each rotation
proved the prior pair absent from every location while the current pair existed only in the two
approved `/run/secrets` files.

The runtime test always creates a uniquely named isolated bridge network, container, and
Docker named data volume (pre-owned `1000:1000`/`0750`, not a host temp bind) so
containerized Linux Docker clients and CI exercise Compose 5.5 injection without host-path
namespace mismatch; the production `/srv/librefs/data` bind with `create_host_path: false`
remains statically asserted and live-verified separately. The test generates per-run CSPRNG
canaries, executes the actual `compose up`, and proves container health, exact file ownership
and mode on the config-backed credential files at
`/run/secrets/librefs_root_{user,password}`, UID 1000 reads, and the absence of canary material
in inspect, environment, and logs. The runtime test then cleans up the isolated bridge
network, container, and named volume. The runtime test never skips when `c1_services` exists;
the isolated test network and named volume are always freshly created and torn down.

Do not deploy libreFS with real credentials until the exact-value leakage scan passes and the
complete allowed and denied cleartext source matrix is verified. Before `main` contains the app,
the explicitly weakened initial check proves API authentication and Git polling only; no prior
token may be revoked on that evidence. After merge, the default checker refuses to run unless
public `main` contains the exact provider-backed mapping, and its successful tracked poll proves
OpenBao resolution.

Controller host-state rollback must remain inside the adopted Ansible transaction: restore the
reviewed declared revision, run `audit`, `check`, and `diff`, then use `deploy` only when the
identity digest and rollback generation match. The role compensates failed file/service changes and
retains `doco-cd-c1-data`; there is no supported direct copy or systemd sequence.

Application rollback is still Doco-owned: publish the prior reviewed libreFS image/config to
`origin/main`, retain `/srv/librefs/data`, and let Doco reconcile only that application after host
prerequisites verify. Never run `docker compose down -v`, create a fallback data directory, delete
an attached network, reformat a disk, or remove the Doco volume to recover from an application
failure. Final status remains `OPERATIONAL_WITHOUT_DURABILITY` until an approved off-host restore
succeeds.
