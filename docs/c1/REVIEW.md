# c1 Independent Architecture Review

Date: 2026-08-26  
Final design gate: `APPROVED_WITH_CONDITIONS`

Scope: `DISCOVERY.md`, `DESIGN-AND-PLAN.md`, `SECRET-CONTRACT.md`, `LIBREFS.md`,
`FUTURE-EDGE.md`, adjacent c0 conventions, OpenBao policy patterns, Docker validation, and the Junos
adoption gate. This is a design review, not an implementation review or live authorization.

## Review history

The first independent pass returned `BLOCKED` with six HIGH and four MEDIUM findings. The main
orchestrator corrected the documents. A focused recheck found two HIGH closures incomplete; those
were corrected and a final independent pass found no remaining CRITICAL/HIGH design defect.

## Findings and disposition

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

Initial defect: effective engine configuration and post-smoke rollback were underspecified.

Disposition: `CLOSED`. Read-only follow-up recorded the effective roots, socket, snapshotter,
containerd CRI setting, absent daemon config, units, and drop-ins. The plan uses minimal root-only
overrides and performs an old-root rollback rehearsal before the no-production-write boundary, then
recopies authoritative old roots for final cutover.

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

### HIGH-6 — GPT approval binding

Initial defect: the mandatory two-device phrase did not explicitly bind the observed 512 GB GPT or
the exact destructive plan.

Disposition: `CLOSED`. The plan computes a digest over identities, roles, models/sizes, signatures,
GPT state, actions, mount paths, and OS exclusion. Approval includes the mandatory identity phrase,
plan digest, observed signature states, and explicit wipe acknowledgement. Apply recomputes and
requires a byte-identical digest immediately before writes.

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

## Verified strengths

- OS disk exclusion and stable-identity/digest-bound destruction gate.
- Docker and containerd persistent roots both included.
- Hard mount dependencies and no root-disk bind fallback.
- Exact Doco 0.111.0 and libreFS amd64 tag/digest pins.
- Correct Doco OpenBao syntax and narrow KV v2 policy.
- Tested libreFS UID/GID 1000, read-only root, dropped capabilities, file secrets, and Bash health.
- Conservative LACP, MTU, offload, and performance claims.
- Explicit off-host restore status cap.
- HAProxy-only future edge and unchanged Junos `adopted: false` gate.

## Implementation review

The independent implementation pass initially returned `BLOCKED` with four HIGH and two MEDIUM
findings. Corrections and focused rechecks closed all of them. Final implementation gate:
`APPROVED_WITH_CONDITIONS`.

- `CLOSED` — Docker restart is disabled for Doco; a real systemd unit owns foreground Compose and
  runs the TTL gate after storage and shim prerequisites on every start.
- `CLOSED` — replacement token/API-secret rotation force-enables the provider canary, requires the
  exact active provider mapping on public `main`, waits for controller health, triggers a tracked
  Doco poll, and requires success before old-token revocation.
- `CLOSED` — destructive storage apply atomically persists the approved plan, records pending UUID
  state, resumes only verified intermediates, and never reformats complete state.
- `CLOSED` — a filesystem mounts and passes UUID/XFS/RW checks before its hard fstab entry is
  committed; the forced mount-failure test proves fstab remains byte-identical.
- `CLOSED` — the persistent shim rejects any L3 address on `bond0.2513` before mutation.
- `CLOSED` — a CSPRNG API secret is atomically installed root-only before the controller starts.

The final recheck found no new CRITICAL or HIGH defect. Repository tests cover exact network/shim
state, storage approval/resume/idempotence, engine configuration installation, token renewal/TTL,
controller provider-source/run gates, OpenBao policy, rendered Compose, and libreFS hardening.

## Conditions before live mutation or real data

1. NVMe health evidence and exact stable identities.
2. Proven provenance/disposability of the 512 GB GPT and both target disks.
3. Conclusive `.65` and `.66` collision checks.
4. Authenticated OpenBao KV v2, audit, token-limit, policy, and renewal evidence.
5. Passing Doco/Compose secret-persistence canary.
6. Passing required cleartext source/denied reachability matrix, or tested TLS/enforceable control.
7. Passing implementation review with no CRITICAL/HIGH finding.
8. Required storage, OpenBao, push, merge, reboot, and optional failover approvals.
9. Off-host target and restore proof for any status above `OPERATIONAL_WITHOUT_DURABILITY`.

These are enforced stop conditions, not implied approvals. Repository implementation may proceed;
live storage/OpenBao/network mutation may not proceed until its corresponding condition and explicit
checkpoint are satisfied.
