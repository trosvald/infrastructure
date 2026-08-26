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
Mission no longer blocked on storage or network; remaining gates are OpenBao writes, push,
merge, deploy, reboot, and off-host backup/restore.
Scope: `DISCOVERY.md`, `DESIGN-AND-PLAN.md`, `SECRET-CONTRACT.md`, `LIBREFS.md`,
`FUTURE-EDGE.md`, adjacent c0 conventions, OpenBao policy patterns, Docker validation, and the Junos
adoption gate. This is a design review, not an implementation review or live authorization.

The first independent pass returned `BLOCKED` with six HIGH and four MEDIUM findings. The main
orchestrator corrected the documents. A focused recheck found two HIGH closures incomplete; those
were corrected and a final independent pass found no remaining CRITICAL/HIGH design defect.

The revised split-storage review then re-examined the boundary change (Docker/containerd on OS
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

### HIGH-1 — Doco ordinary-KV deployment behavior

Initial defect: the design claimed KV rotation waited for an explicit redeploy. Doco 0.111.0 resolves
ordinary external secrets before computing the rendered project hash, so a changed value can cause
recreation on the next poll.

Disposition: `CLOSED`. Discovery, secret, libreFS, and plan documents now use one contract: stop Doco
before a KV CAS write, then start/recreate it only when service recreation is intended. The canary
must reproduce the hash-driven deployment behavior.

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
  first aligned sector at or after the midpoint of the usable GPT range, partition 1 ends
  immediately before it;
- filesystem-type assertion: both partitions `XFS` with the reviewed options;
- apply convergence: when a known UUID-bound completed mount exists, the helper remounts it
  `noatime` and re-commits the hard fstab entry (UUID-based) before the storage assertion reports
  active; the remount preserves the original UUID, mountpoint, and non-`noatime` options; any
  drift fails closed;
- shim exact-state: route query must not filter on `dev`; real JSON must include
  `dev: c1-svc-shim`; validators require address `ifname`, route `dev`, and scope `link`;
- persistent shim/network success: `c1-services-shim.service` and `c1-services-network.service`
  both active; `c1-svc-shim` is up at `10.25.13.17/32` with route `10.25.13.64/27 dev
  c1-svc-shim` and scope `link`; Docker and containerd `SOURCE` equals `/` source;
- no-wipe assertion: byte-identical retry never reformats a `complete` partition or a verified
  pending partition.

## Verified strengths

- OS disk exclusion and stable-identity/digest-bound destruction gate.
- Engine persistent roots remain on the OS disk; no Docker/containerd data-root migration.
- Docker/containerd `SOURCE` equal to `/` source asserted under the storage gate.
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
- Tested libreFS UID/GID 1000, read-only root, dropped capabilities, file secrets, and Bash health.
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
- `CLOSED` — Docker and containerd `SOURCE` equal `/` source under the storage gate; the runbook
  proves this before any wipe and fails closed on drift.
- `CLOSED` — NVMe critical-warning, media/data-integrity, and available-spare are read inside the
  plan digest and bound to the `apply` gate.

Repository tests cover exact network/shim state, single-device storage approval/resume/idempotence
(no engine configuration installation), the RSS regression matrix (signature, LVM/RAID/holder,
`fuser`, mount, identity, root-disk, critical/media/spare, pending-digest state, layout geometry,
filesystem type, no-wipe), token renewal/TTL, controller provider-source/run gates, OpenBao
policy, rendered Compose, and libreFS hardening.

## Remaining gates before push, deploy, and real data

Storage and network are applied successfully. The remaining gates are:

1. Conclusive `.65` and `.66` collision checks.
2. Authenticated OpenBao KV v2, audit, token-limit, policy, and renewal evidence.
3. Passing Doco/Compose secret-persistence canary.
4. Passing required cleartext source/denied reachability matrix, or tested TLS/enforceable control.
5. Passing implementation review with no CRITICAL/HIGH finding.
6. Required OpenBao, push, merge, deploy, reboot, and optional failover approvals.
7. Off-host target and restore proof for any status above `OPERATIONAL_WITHOUT_DURABILITY`.

These are enforced stop conditions, not implied approvals. The 512 GB device remains excluded
from any approval and is never an argument. Storage or network mutation is no longer required
for the current mission state.
