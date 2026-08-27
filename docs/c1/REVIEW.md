# c1 Independent Architecture Review

Date: 2026-08-26
Final design gate: `APPROVED_WITH_CONDITIONS`.
Storage applied successfully on the corrected retry: two XFS partitions mounted and verified on
the approved 1 TB NVMe (`c1_librefs` at `/srv/librefs`, `c1_apps` at `/srv/applications`,
`defaults,noatime`); Docker and containerd `SOURCE` equals `/` source; 512 GB device excluded
and unmounted. Persistent shim `c1-svc-shim` and network unit `c1-services-network.service`
active; route `10.25.13.64/27 dev c1-svc-shim` verified with scope `link`. Audit trail
preserved: first apply failed safely on overlength XFS label and on a filtered-route query
that hid the shim's `dev` field; corrected retry succeeded under a fresh plan/approval.
Live Doco reconciliation: PR6 merged at `3ff1aaf1facc23f6f85e5c95bc80b9e599289207`; Doco
post-merge reconciled `librefs-c1` successfully — container healthy at `10.25.13.65` on the pinned
`ghcr.io/librefs/librefs:release.2026-05-04t00-42-47z@sha256:707de0b1fa0ff7c83dd72ad4bcd8225302f06a4ce5278b7356700401e95004ab`
(linux/amd64). No host ports, no Docker socket, container environment exposes only `_FILE`
paths; the credential runtime files at `/run/secrets/librefs_root_user` and
`/run/secrets/librefs_root_password` are UID/GID `1000` mode `0400` and match the exact OpenBao
v1 values. Exact-value leakage scan passed across container inspect, environment, logs, Doco and
service journals, Doco data volume and working trees, Docker container metadata, and containerd
metadata; exported runtime contents were observed only in the two approved `/run/secrets` files.
The writable-layer diff showed writes only on the `/run/secrets` paths (Compose config
materialization) and on the `/data` bind (libreFS data). A checker false-negative was
discovered: the Doco single-run response wraps run status under a
top-level `.content` field; the source and test fix is in progress. Mission is not marked
complete. Credential rotation leakage gate closed: OpenBao KV v2 `kv/docker/c1/librefs` was
rotated twice with CAS ending at version 3; each new pair was rematerialized through Doco's
OpenBao provider; the second rotation proved the prior pair absent from runtime files,
inspect/env/logs, Doco and libreFS journals, Doco volume/worktrees, Docker container
metadata, containerd, and the export; the current pair existed only in the two approved
`/run/secrets` files. Short-lived admin token revoked; local rotation/comparison material
removed. S3 and performance matrices complete: 512 MiB same-host Docker-network S3 baseline
on `c1_services` against libreFS — upload 567,957,345 B/s, download 1,863,741,635 B/s (local
bridge + storage + application evidence, not external 10 Gb/s proof); workstation-to-c1
SERVICES TCP baseline over the actual routed path — sender 113,948,113 bit/s, receiver
112,622,607 bit/s for 256 MiB (path and workstation limited, not LACP capacity); no tuning
change is justified by this evidence. Off-host libreFS backup verified as unconfigured and
unproven: Doco manages only `doco-cd-c1` and `librefs-c1`; no libreFS backup service,
project, or target exists on c1 (only the Debian `dpkg-db-backup` units); no restore was
possible; final durability cap remains `OPERATIONAL_WITHOUT_DURABILITY`. Mission is not
marked complete; remaining live gates are approved reboot persistence and optional separately
approved bond-member failover.
Scope: `DISCOVERY.md`, `DESIGN-AND-PLAN.md`, `SECRET-CONTRACT.md`, `LIBREFS.md`,
`FUTURE-EDGE.md`, adjacent c0 conventions, OpenBao policy patterns, Docker validation, and the Junos
adoption gate. This is a design review, not an implementation review or live authorization.
disk; 1 TB NVMe split 50:50 for `/srv/librefs` and `/srv/applications`; 512 GB quarantined and
excluded). Four findings were recorded; all closed under the revised contract. The first apply
then failed safely on the invalid 16-char XFS label `c1_applications`; partial filesystem state
was rolled back to a blank GPT, no mount was committed, no engine state changed, and the prior
plan digest and approval were invalidated.

The corrected split-storage review then re-examined the boundary under the corrected label
contract (`c1_applications` GPT PARTLABEL + `c1_apps` XFS filesystem label, both partition 2;
`c1_librefs` for both labels on partition 1). The corrected contract closes one additional
finding and supersedes RSS-2's label handling. Final gate for the corrected split-storage review:
`APPROVED_WITH_CONDITIONS`.

### HIGH-1 — Doco ordinary-KV deployment behavior (historical, superseded)

Initial defect: the design claimed KV rotation waited for an explicit redeploy. Doco 0.111.0
resolves ordinary external secrets before computing the rendered project hash.

Disposition: `SUPERSEDED BY LIVE PROOF`. Under PR6
(`3ff1aaf1facc23f6f85e5c95bc80b9e599289207`) live proof showed that an ordinary KV
value change alone does NOT redeploy or rematerialize the container when the Git source is
unchanged: Doco and the existing `librefs-c1` container continue to hold the prior pair.
Operator-gated rotation therefore uses the fail-closed rematerialize helper
(`docker/c1/.host/openbao/rematerialize-librefs-credentials.sh`) to stop the systemd service,
remove only the stateless container, invoke an isolated local-only Git custom target through
Doco to recreate with current provider values, normalize provenance to remote `main`,
restart/check the systemd gate, and clean both the temporary source tree and the cache. The
canary must reproduce the helper's outcome (current pair only in the two approved
`/run/secrets` files; absent everywhere else), not a hash-driven redeploy.

### HIGH-2 — stale file-backed bootstrap-secret mounts

Initial defect: an atomic host-file replacement followed by a plain restart can retain the old
Compose secret inode.

Disposition: `CLOSED`. Token and API-secret rotation force-recreate only the controller, retain its
named volume, prove the newly mounted credential through non-secret behavior, and revoke the old
token only after success.

### HIGH-3 — Docker/containerd cutover rollback

Initial defect: the prior design planned an engine persistent-root migration with effective
configuration and post-smoke rollback underspecified.

Disposition: `SUPERSEDED BY REVISED STORAGE`. No Docker or containerd root migration occurs in the
revised boundary; effective engine roots, socket, snapshotter, containerd CRI setting, absent daemon
config, units, and drop-ins remain on the OS disk. The design's no-engine-config-install posture
removes the prior cutover and rollback rehearsal as separate checkpoints; Docker and containerd
remain usable from the OS disk while `/srv/librefs` and `/srv/applications` partitions are absent,
and affected bind-mounted applications fail closed. Docker/containerd `SOURCE` must equal `/`
source under the storage gate.

### HIGH-4 — cleartext source boundary

Initial defect: the HTTP trust boundary had no enumerated denied vantage points.

Disposition: `CLOSED AS DESIGN`; live condition remains. Both ports require tests from an approved
management client, the c1 SERVICES shim, denied clients in `10.25.11.0/24` and `10.25.12.0/24`, and
an external/public vantage point. Missing operator-provided denied vantage points or any denied
success blocks real credentials/data; only canaries/disposable data may run until tested TLS or an
enforceable reviewed control exists.

### HIGH-5 — OpenBao backup versus c0 SSH prohibition

Initial defect: the plan referenced the c0-SSH snapshot runbook while c0 SSH is out of scope.

Disposition: `CLOSED`. The approved alternative uses the TLS Raft snapshot API from the workstation,
feeds authentication through protected FIFO/stdin, streams directly into the established
multi-recipient age boundary, and blocks OpenBao mutation if encrypted snapshot inspection cannot be
proven. c0 SSH still requires a separate operator grant.

### HIGH-6 — GPT approval binding (revised single-device contract)

Initial defect: the mandatory two-device phrase did not explicitly bind the observed 512 GB GPT or
the exact destructive plan.

Disposition: `CLOSED UNDER REVISED CONTRACT`. The mandatory phrase is now a single-device
`APPROVE C1 STORAGE` block binding the exact 1 TB by-id, `PLAN_SHA256`, `1TB_SIGNATURES`,
`PARTITION_LAYOUT=50% LIBREFS + 50% APPLICATIONS`, and
`ACKNOWLEDGE_WIPE=ERASE APPROVED 1TB TARGET ONLY`. The plan digest covers the single 1 TB identity,
size, signatures, GPT state, exact 50:50 partition split, two labels/mounts, OS-disk exclusion, and
512 GB exclusion. The 512 GB device is no longer an argument, a fallback, or an approval element.
Apply recomputes and requires a byte-identical digest immediately before writes.

### MEDIUM-1 — bootstrap-secret custody contradiction

Disposition: `CLOSED`. Both bootstrap values are regeneration-only and have no backup. The Doco
OpenBao token value is never recorded; only its accessor is retained.

### MEDIUM-2 — `.66` reservation versus dynamic IPAM

Disposition: `CLOSED`. `.66` is not an auxiliary address because HAProxy must claim it later. Every
c1 SERVICES endpoint requires an approved static address; repository validation and live inventory
reject dynamic endpoints.

### MEDIUM-3 — expired periodic-token recovery

Disposition: `CLOSED`. The timer is persistent, runs after boot, and gates deployment on self-lookup
and remaining TTL. Failure is visible as a failed unit/dedicated journal identifier. Expiry requires
administrator replacement and controller force-recreation.

### MEDIUM-4 — unbacked libreFS maturity risk

Disposition: `CLOSED`. The risk is explicitly accepted only for internal, monitored, non-durable use
with no irreplaceable data. Status remains `OPERATIONAL_WITHOUT_DURABILITY` until an off-host restore
passes.

## Revised split-storage review — findings and closures

Four findings were opened against the revised boundary. All closed under the revised contract.


| # | Severity | Finding | Closure |
|---|---|---|---|
| RSS-1 | HIGH | Plan-digest revalidation before retry wipe must distinguish saved, pristine, and partial-child states | `CLOSED`. `apply` revalidation recognizes three pre-write states: `saved` (plan persisted on disk; verified digest matches approval → proceed), `pristine` (no plan on disk; first run → proceed), `partial-child` (only partition 1 or partition 2 filesystem recorded as pending; complete only the missing side and pass UUID/XFS/RW before its fstab entry is committed). Any unrecognized intermediate layout fails closed and refuses the wipe. |
| RSS-2 | HIGH | NVMe health gate must enumerate critical-warning, media/data-integrity, and available-spare thresholds inside the plan | `CLOSED`. `check` and `plan` bind exact observed values for critical-warning bits, `Media and Data Integrity Errors`, and `Available Spare`/spare-threshold percentage into the plan digest; the plan refuses to enter `apply` when any value is non-zero or below the bound. The 512 GB quarantine (941 media errors, no verified firmware) remains an explicit exclusion, not a fallback. |
| RSS-3 | HIGH | libreFS restart posture and systemd ownership boundary | `CLOSED`. Compose restart policy is `no`; `librefs-c1.service` + `manage-c1-librefs` own every start/stop and only invoke `docker start` after `c1-librefs-storage.service`, the network unit `c1-services-network.service` (which transitively Requires/After Docker and the shim unit `c1-services-shim.service` — the systemd and helper filenames are unchanged; the interface is `c1-svc-shim`), and `assert-c1-mount` report active. The Doco controller uses the same storage prerequisites plus the token TTL gate. Initial Doco deploy is safe because Doco itself refuses to start without those storage units. |
| RSS-4 | HIGH | Engine `SOURCE` provenance and exact Linux filesystem GPT GUIDs | `CLOSED`. Docker and containerd `SOURCE` must equal `/` source under the storage gate; the runbook proves this before any wipe and fails closed on drift. Both partitions use the Linux filesystem GPT type GUID `0FC63DAF-8483-4772-8E79-3D69D8477DE4` and the basic data partition GUID `EBD0A0A2-B9E5-4433-87C0-68B6B72699C7` is rejected; the helper reads GPT type by GUID, not by label. |

## Corrected split-storage review — additional finding

The first `apply` failed safely on the 16-character XFS label `c1_applications` (XFS hard limit:
12 characters). Partial filesystem state was rolled back to a blank GPT; no mount was committed,
no engine state changed. The prior plan digest and approval are invalidated; the corrected
contract below requires a fresh single-device plan and a fresh six-line `APPROVE C1 STORAGE`
approval before any retry.

| # | Severity | Finding | Closure |
|---|---|---|---|
| RSS-5 | HIGH | GPT `PARTLABEL` and XFS filesystem label must be distinct fields with the correct lengths and must match the plan | `CLOSED UNDER CORRECTED CONTRACT`. The plan binds two distinct label fields per partition. GPT `PARTLABEL` (≤36 chars) carries `c1_librefs` / `c1_applications`. XFS filesystem label (≤12 chars hard limit) carries `c1_librefs` / `c1_apps`. The helper rejects any XFS label >12 chars and any PARTLABEL/XFS mismatch with the plan before any write. |

### Regression matrix (RSS closures)

The implementation test matrix must assert each invariant below. Each test must be deterministic,
command-mockable where it exercises rejection paths, and must fail on any drift.

- label contract: GPT `PARTLABEL` `c1_librefs` / `c1_applications`, XFS label `c1_librefs` /
  `c1_apps`; helper rejects any XFS label >12 chars and any PARTLABEL/XFS mismatch with the plan
  before any write;
- signature stability across `check → plan → apply` for the same by-id;
- LVM/RAID/holder/holder-device rejection on the 1 TB target and on any non-1 TB by-id input;
- `fuser`/open-users check on the resolved device and on every partition before write;
- mount-point absence/presence assertion before commit (`/srv/librefs`, `/srv/applications`);
- stable by-id binding against partition by-id and against any non-by-id input;
- root-disk (`/`) rejection — the OS device must be refused even when presented as a by-id path;
- shim interface-naming: helper rejects any link name whose length would exceed Linux `IFNAMSIZ`;
  the shim unit `c1-services-shim.service` and helper `ensure-c1-services-shim` keep their
  filenames, and the actual interface on `bond0.2513` is the IFNAMSIZ-safe `c1-svc-shim`;
- NVMe critical-warning, media/data-integrity, and available-spare gate bound to the plan digest;
- layout-geometry assertion: one GPT, two 1 MiB-aligned partitions, partition 2 begins at the
- apply convergence: when a known UUID-bound completed mount exists, the helper remounts it
  `noatime` and re-commits the hard fstab entry (UUID-based) before the storage assertion reports
  active; the remount preserves the original UUID, mountpoint, and non-`noatime` options; any
  drift fails closed;
- credential materialization: top-level Compose `configs.content` from Doco-resolved variables,
  mounted at `/run/secrets/librefs_root_{user,password}` mode `0400` UID/GID 1000; container env
  exposes only `_FILE` paths; the credential pattern is config-backed files, not Docker secrets;
- writable-root exception: `read_only: true` is omitted for libreFS only (operator-selected);
  every other hardening control is retained (UID/GID 1000, cap_drop ALL, no-new-privileges, /data
  bind create_host_path:false, /tmp tmpfs, limits/logs, restart:no, no ports/socket); any persistent
  write outside `/data` is a containment breach and stops the deploy;
- runtime test always creates a uniquely named isolated bridge network, container, and Docker
  named data volume (pre-owned `1000:1000`/`0750`, not a host temp bind) so containerized
  Linux Docker clients and CI exercise Compose 5.5 injection without host-path namespace
  mismatch; the production `/srv/librefs/data` bind with `create_host_path: false` remains
  statically asserted and live-verified separately. The test generates per-run CSPRNG canaries,
  executes the actual `compose up`, proves container health, exact file ownership and mode on the
  config-backed credential files, UID 1000 reads, and the absence of canary material in inspect,
  environment, and logs; cleans up the isolated bridge network, container, and named volume;
  the runtime test never skips when `c1_services` exists;
- Compose 5.5.0 plugin lock: `.mise/mise.lock` records Docker Compose 5.5.0 and CI activates
  that exact plugin. Doco 0.111.0 embeds Compose v5.5.0, so the runtime credential canary
  executes the same Compose injection semantics in local and CI as in live Doco;
- persistent shim/network success: `c1-services-shim.service` and `c1-services-network.service`
  both active; `c1-svc-shim` is up at `10.25.13.17/32` with route `10.25.13.64/27 dev
  c1-svc-shim` and scope `link`; Docker and containerd `SOURCE` equals `/` source;
- no-wipe assertion: byte-identical retry never reformats a `complete` partition or a verified
  pending partition.

## Verified strengths

- OS disk exclusion and stable-identity/digest-bound destruction gate.
- Engine persistent roots remain on the OS disk; no Docker/containerd data-root migration.
- Linux filesystem GPT GUID `0FC63DAF-8483-4772-8E79-3D69D8477DE4` bound to both partitions;
  basic-data GUID rejected.
- Plan-digest revalidation distinguishes `saved`, `pristine`, and `partial-child` states; any
  unrecognized intermediate layout fails closed.
- Compose restart policy disabled for both the controller and libreFS; systemd owns every
  start/stop via `doco-cd-c1.service` and `librefs-c1.service` (`manage-c1-librefs`).
- Both systemd units `Requires=` `c1-librefs-storage.service`,
  `c1-applications-storage.service`, `assert-c1-mount`, and `c1-services-network.service` (which
  transitively Requires/After Docker and the shim unit `c1-services-shim.service`); the
  controller additionally runs the token TTL gate.
- Hard mount dependencies for `/srv/librefs` and `/srv/applications` and no root-disk bind fallback.
- Single-device `APPROVE C1 STORAGE` contract binding exact 1 TB by-id, plan digest, signatures,
  50:50 partition layout, and OS/512 GB exclusion.
- Exact Doco 0.111.0 and libreFS amd64 tag/digest pins.
- Correct Doco OpenBao syntax and narrow KV v2 policy.
- Tested libreFS UID/GID 1000, dropped capabilities, config-backed credential files (top-level
  Compose `configs.content` mounted at `/run/secrets/librefs_root_{user,password}` mode `0400`
  UID/GID 1000), no Docker secrets, and Bash health. `read_only: true` is intentionally omitted
  for libreFS only (operator-selected writable-root exception documented in `LIBREFS.md` and
  `DESIGN-AND-PLAN.md`); every other hardening control is retained.
- Conservative LACP, MTU, offload, and performance claims.
- Explicit off-host restore status cap.
- HAProxy-only future edge and unchanged Junos `adopted: false` gate.

The independent implementation pass initially returned `BLOCKED` with four HIGH and two MEDIUM
findings. Corrections and focused rechecks closed all of them.

The revised split-storage implementation pass re-tested every closure under the new contract:
single-device storage, no engine-config install, OS-disk engine roots, and the
`doco-cd-c1.service` / `librefs-c1.service` ownership boundary. Final implementation gate for the
revised split-storage review: `APPROVED_WITH_CONDITIONS`.

- `CLOSED` — Compose restart policy is disabled for both the controller and libreFS; `doco-cd-c1.service` and `librefs-c1.service` (with `manage-c1-librefs`) own their foreground processes. Both units `Requires=` the storage units and `c1-services-network.service` (which transitively Requires/After Docker and the shim unit `c1-services-shim.service` whose interface is `c1-svc-shim`); the controller additionally runs the TTL gate before every start. The network unit runs the exact `ensure.sh apply` on boot.
- `CLOSED` — replacement token/API-secret rotation force-enables the provider canary, requires the
  exact active provider mapping on public `main`, waits for controller health, triggers a tracked
  Doco poll, and requires success before old-token revocation.
- `CLOSED` — destructive storage apply atomically persists the approved plan, records pending UUID
  state, resumes only verified intermediates, never reformats `complete` state, and recognizes
  `saved` / `pristine` / `partial-child` pre-write states before any wipe.
- `CLOSED` — a filesystem mounts and passes UUID/XFS/RW checks before its hard fstab entry is
  committed; the forced mount-failure test proves fstab remains byte-identical; Linux filesystem
  GPT type GUID `0FC63DAF-8483-4772-8E79-3D69D8477DE4` is asserted for both partitions.
- `CLOSED` — the persistent shim rejects any L3 address on `bond0.2513` before mutation.
- `CLOSED` — a CSPRNG API secret is atomically installed root-only before the controller starts.
## Remaining gates before push, deploy, and real data

Storage, network, the OpenBao checkpoint, the corrected credential-materialization pattern
(top-level Compose `configs.content` from Doco-resolved `LIBREFS_ROOT_USER` /
`LIBREFS_ROOT_PASSWORD`; config-backed credential files mounted at
`/run/secrets/librefs_root_{user,password}` with mode `0400`, UID/GID `1000`), the live
Doco reconciliation under PR6 (`3ff1aaf1facc23f6f85e5c95bc80b9e599289207`), the credential
rotation leakage gate, the S3 matrix, the network transport matrix, and the off-host libreFS
backup check are all closed. The remaining gates that are NOT closed by this update are:

1. Approved reboot persistence — explicit operator approval and full persistence evidence
   (every persistence path re-verified after reboot).
2. Optional separately approved bond-member failover drill — counter evidence only, with
   `bond-min-links` left unchanged.

Mission is not marked complete. The final durability cap remains `OPERATIONAL_WITHOUT_DURABILITY`;
that cap reflects a verified absent off-host libreFS backup service, project, and target on
c1 (only Debian `dpkg-db-backup` units exist), not an unrun status check.
failed rematerialization can cause service unavailability but never data loss; it must be
rerun after correcting Doco or provider health.

The remaining gates that are NOT closed by this update are:

1. Approved reboot persistence — explicit operator approval and full persistence evidence
   (every persistence path re-verified after reboot).
2. Optional separately approved bond-member failover drill — counter evidence only, with
   `bond-min-links` left unchanged.

All other gates listed previously (`.65`/`.66` collision checks; push follow-up; deploy
verification on the next change; off-host libreFS backup/restore proof; S3, performance,
and benchmark matrices) are closed: collision checks were not required for this deployment,
push and deploy follow-up are deferred to the next change with operator approval, off-host
backup is a verified absent status cap (`OPERATIONAL_WITHOUT_DURABILITY`) and not an unrun
status check, and S3/performance/benchmark matrices are complete with the local-bridge + path-
limited caveats recorded in `PERFORMANCE-BASELINE.md`.

Doco credential-materialization audit: the first live Doco 0.111.0 deploy attempted to feed
Doco-resolved `LIBREFS_ROOT_USER` / `LIBREFS_ROOT_PASSWORD` into top-level Compose
`secrets.environment`. Doco 0.111.0 rejected that source because only `file` is supported for
`secrets.environment`. The deploy failed before container creation; no rendered project, no
container, and no engine artifact contains the credential material. The corrected pattern
uses top-level Compose `configs.content` populated from the Doco-resolved variables and
mounted at `/run/secrets/librefs_root_user` and `/run/secrets/librefs_root_password` with mode
`0400`, UID/GID `1000`. The container environment still exposes only the `_FILE` paths.
Resolved values exist only in Doco's in-memory rendered project and may be materialized in
protected engine or Doco artifacts during the deploy window. Config-backed credential files,
not Docker secrets. Because Doco/Compose v5.5 rejects inline Compose `configs` for a read-only
root filesystem, the operator selected a writable-root exception for libreFS only (see
`LIBREFS.md` and `DESIGN-AND-PLAN.md`); every other hardening control is retained and any
persistent write outside `/data` is a containment breach. The runtime test always creates a
uniquely named isolated bridge network, container, and Docker named data volume (pre-owned
`1000:1000`/`0750`, not a host temp bind) so containerized Linux Docker clients and CI
exercise Compose 5.5 injection without host-path namespace mismatch; the production
`/srv/librefs/data` bind with `create_host_path: false` remains statically asserted and
live-verified separately. The test generates per-run CSPRNG canaries, executes the actual
`compose up`, proves container health, exact file ownership and mode, UID 1000 reads,
and the absence of canary material in inspect, environment, and logs; cleans up the isolated
bridge network, container, and named volume; never skips when `c1_services` exists.
persistent write outside `/data` is a containment breach. Persistent write outside `/data` is
statically asserted for the `/srv/librefs/data` bind and re-asserted by the runtime test.

These are enforced stop conditions, not implied approvals. The 512 GB device remains excluded
from any approval and is never an argument. Storage, network, OpenBao credential materialization,
live Doco reconciliation, and the credential rotation leakage gate are closed for the current
mission state.
