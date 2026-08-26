# c1 Design and Plan

Date: 2026-08-26
Status: storage boundary revised (1 TB only, 50:50 split; 512 GB quarantined/excluded); first apply
failed safely on the invalid 16-char XFS label `c1_applications`; partial state rolled back to blank
GPT; prior plan digest and approval invalidated; ready for focused re-review on the corrected label
contract (`c1_apps` XFS label, `c1_applications` GPT PARTLABEL); mission blocked pending fresh
single-device plan/approval.

This plan follows `docs/c1/DISCOVERY.md`. It does not authorize storage, OpenBao, network, push,
merge, reboot, or link-failure mutation.

## Target architecture

```text
GitHub public main, polled every 180 seconds
                    |
                    v
c1 Doco-CD 0.111.0, bootstrap-owned
- 127.0.0.1:8080 API
- 127.0.0.1:9120 metrics
- Docker socket
- ./docker/c1 discovery, depth 1
- root-only API secret and OpenBao token files
                    |
       +------------+-------------------+
       |                                |
       v                                v
Docker + containerd                 OpenBao TLS
persistent roots remain on OS       kv/docker/c1/*
       |
       +-- external IPvlan c1_services
       |     parent bond0.2513, MTU 1496
       |     allocation 10.25.13.64/27
       |     host shim 10.25.13.17/32
       |     `-- libreFS 10.25.13.65
       |           /data -> 1 TB NVMe partition 1
       |
       `-- future application binds -> 1 TB NVMe partition 2
```

Management remains `eno1`, `10.25.10.101/24`, default gateway `10.25.10.1`, DNS
`10.25.10.100`. Nothing in this design rewrites that interface, address, route, or resolver.

## Storage decision

### Revised layout

The operator revised the storage boundary after the 512 GB health finding. Docker engine state stays
on the OS disk. The healthy 1 TB NVMe is split approximately 50:50 for libreFS and explicit
application bind data.
| Physical role | Partition/filesystem | GPT PARTLABEL | XFS label | Mount | Persistent content |
|---|---|---|---|---|---|
| 500 GB SATA OS disk | unchanged | n/a | n/a | existing mounts | OS, `/var/lib/docker`, `/var/lib/containerd`, container writable layers, images, Doco named volume |
| approved 1 TB NVMe partition 1 | aligned XFS, CRC/reflink, `ftype=1` | `c1_librefs` | `c1_librefs` (≤12 chars) | `/srv/librefs` | libreFS `/srv/librefs/data` only |
| approved 1 TB NVMe partition 2 | aligned XFS, CRC/reflink, `ftype=1` | `c1_applications` | `c1_apps` (≤12 chars) | `/srv/applications` | future explicit application/database bind directories |
| 512 GB NVMe | unchanged and unmounted | n/a | n/a | none | quarantined; not used by this mission |

The split uses one GPT and two aligned partitions. Partition 2 begins at the first 1 MiB-aligned
sector at or after the midpoint of the usable GPT range; partition 1 ends immediately before it.
The resulting capacities differ only by alignment/GPT overhead rather than promising identical byte
counts.

Use filesystem UUIDs in `/etc/fstab`. The stable 1 TB by-id path identifies the only destructive
input and remains root-only host state, not Git. Two label fields exist on each partition and the
plan must bind both: the GPT `PARTLABEL` (≤36 chars) holds the operator-facing name — `c1_librefs`
for partition 1 and `c1_applications` for partition 2 — and the XFS filesystem label (≤12 chars,
hard XFS limit) holds the runtime name — `c1_librefs` for partition 1 and `c1_apps` for partition 2.
The old partition-2 XFS label `c1_applications` (16 chars) exceeds the XFS limit and was rejected
at first apply; the helper treats any pre-write label mismatch, XFS label overflow, or PARTLABEL
mismatch as a stop condition. Labels are diagnostic only. Mount options are `defaults,noatime`;
no `nofail` and no continuous `discard`. Enable and verify `fstrim.timer`.

**Failed first apply — fresh approval required.** The first `apply` run failed safely on the
invalid XFS label `c1_applications` (exceeds 12-character XFS limit). Partial filesystem state
was rolled back to a blank GPT; no partition data survived, no mount was committed, and no engine
state changed. The prior plan digest and the prior approval are invalidated; a fresh single-device
plan digest and a fresh six-line `APPROVE C1 STORAGE` approval are required before any retry.

### Docker and application-state boundary

No Docker or containerd root migration occurs:

```text
Docker data-root: /var/lib/docker
containerd root: /var/lib/containerd
containerd state: /run/containerd
```

No c1 Docker daemon configuration or containerd root override is installed. Docker images, layers,
container writable state, and named volumes—including the Doco volume—remain on the OS disk.

`/srv/applications` is not a Docker engine root. Future Mattermost, Forgejo, PostgreSQL, and other
ordinary application state use explicit reviewed bind directories below it. A container receives no
path there unless its Compose project declares that exact bind with `create_host_path: false`.

libreFS uses `/srv/librefs/data:/data` with `bind.create_host_path: false`. Provisioning creates the
directory only while `/srv/librefs` is the verified first partition, then sets UID/GID 1000 and mode
`0750`. The directory is absent beneath an unmounted mountpoint, preventing OS-disk fallback.

### Provisioning interface

- `check <1TB-by-id>`: read-only identity, health, use, signature, NVMe critical-warning,
  media/data-integrity, and available-spare checks; rejects any non-zero critical-warning,
  non-zero media/data-integrity counter, or below-bound available-spare;
- `plan <1TB-by-id>`: a digest-bound destructive plan containing exact identity, size, signatures,
  sector split, GPT type GUID `0FC63DAF-8483-4772-8E79-3D69D8477DE4` for both partitions (basic-data
  GUID `EBD0A0A2-B9E5-4433-87C0-68B6B72699C7` rejected), NVMe health gate values, two GPT
  PARTLABELs (`c1_librefs`, `c1_applications`) and two XFS filesystem labels (`c1_librefs`,
  `c1_apps`, each ≤12 chars), two labels/mounts, actions, and OS/512 GB exclusions;
- `apply <1TB-by-id> <PLAN_SHA256>`: protected-stdin approval, immediate plan recomputation,
  pre-write revalidation distinguishing `saved` (verified digest matches approval → proceed),
  `pristine` (no plan on disk → proceed), and `partial-child` (only one partition recorded as
  pending → complete only the missing side and verify UUID/XFS/RW before its fstab entry commits),
  and only the approved single-device operation. Any unrecognized intermediate layout fails closed;
- `verify`: non-destructive UUID/XFS/RW/fstab/directory verification for both partitions, and
  Docker/containerd `SOURCE` must equal `/` source.

Initial planning rejects the root/boot/swap disk, unstable or partition by-id input, mounts,
partitions, signatures, LVM, RAID, holders, open users, failed health (non-zero critical-warning,
non-zero media/data-integrity counter, or below-bound available-spare), size/model mismatch,
non-Linux-filesystem GPT type GUID, XFS label overflow (>12 chars), GPT PARTLABEL / XFS label
mismatch with the plan, changed evidence, and Docker/containerd `SOURCE` not equal to `/` source.
The 1 TB target currently has no recognized signature.

Before the first write, apply atomically persists the complete approved plan. It creates the GPT and
both partition entries in one step, then provisions each partition independently. Each filesystem
records an atomic pending UUID immediately after formatting, mounts by partition, and passes
UUID/XFS/RW checks before its hard fstab entry is committed. Only after fstab verification does
pending state become complete. A byte-identical retry resumes verified pending state or skips a
verified complete partition; it never reformats complete state. Any unrecognized intermediate
layout fails closed.

The 512 GB device is never an argument, an implicit fallback, or a backup candidate. Its historical
media/data-integrity counter (941), existing GPT, and successful short/extended self-tests remain
documented, but it stays quarantined/unmounted/excluded. Firmware VC400618 has no verified official
updater; release depends on a documented replacement or future verified update path.

### Rollback

Before formatting, rollback is no-op: no engine or OS configuration changes exist. After GPT or
filesystem creation, formatting cannot recover prior unknown content. The root-only pre-write
signature/GPT evidence documents the destructive boundary but is not a data backup.

If mount/fstab application fails, the pending-state transaction resumes only with the same plan
digest and approval. A verified complete partition is never reformatted by retry. If either mount is
later wrong or absent, Docker continues on the OS disk while libreFS and affected bind-mounted
applications fail closed; keep those applications stopped and repair the mount rather than creating
fallback directories.

## Network decision

### Docker network

`docker/c1/.host/networks/services/ensure.sh` owns this exact immutable state:

| Field | Required value |
|---|---|
| name/driver/scope | `c1_services` / `ipvlan` / local |
| IPv4/IPv6 | enabled / disabled |
| subnet/gateway/range | `10.25.13.0/24` / `10.25.13.1` / `10.25.13.64/27` |
| auxiliary reservation | `c1-shim=10.25.13.17` |
| parent | `bond0.2513` |
| options | `ipvlan_mode=l2`, `ipvlan_flag=bridge` |
| MTU contract | parent and created links remain 1496 |
| labels | bootstrap-managed and c1 SERVICES purpose |
| other flags | not internal, attachable, ingress, or config-only |

The script verifies parent existence, UP state, VLAN identity, MTU 1496, and absence of a host L3
address. It creates only when absent, reinspects every immutable field, and fails on zero/multiple
matches, drift, create failure, or post-create mismatch. It never repairs by deletion. Attached drift
requires an approved outage, owner shutdown, zero endpoints, explicit removal, recreate, and
redeploy.

Tests cover absent/create, exact match, every field drift, ambiguous list, parent missing/down/wrong
MTU, create failure, post-create failure, attached network, and Docker/IP command failure.

### Host shim

A root-owned idempotent oneshot creates an IPvlan L2 shim on `bond0.2513`:

```text
link: c1-services-shim
MTU: 1496
address: 10.25.13.17/32
route: 10.25.13.64/27 dev c1-services-shim
```

It matches exact existing link/address/route state and fails on drift; it does not hide drift with
`route replace`. Persistence is a systemd unit ordered after network-online and `bond0.2513`, before
Doco deployment, and additive to existing ifupdown configuration. It never adds an address or
default route to `bond0` or the VLAN.

Before and after application, assert the unchanged management interface/address/default route/DNS,
LACP membership/aggregator, VLANs, and MTUs. OpenBao `.34` remains outside the shim `/27` and uses
the existing management default route.

`.65` and `.66` need conclusive duplicate-address detection before network creation. `.65` becomes
libreFS; `.66` remains unassigned for future HAProxy. The current network cannot reserve `.66` as an
auxiliary address because that would also prevent HAProxy from claiming it later. Instead, every
c1 application attached to `c1_services` must have an approved static address, and validation/live
inventory fails on any dynamic endpoint or address outside the explicit reservation table.

## Doco-CD decision

Retain the c0 compatibility pin and leave c0 unchanged:

```text
ghcr.io/kimdre/doco-cd:0.111.0@sha256:8c31f63f6bde1b67f0802619bad0599bf5e41503f5532be9cc58d0f063b1eeea
```

c1 controller contract:

- project/container/volume names include c1;
- bootstrap source `docker/c1/.doco-cd/docker-compose.app.yaml` is not auto-discoverable;
- `working_dir: ./docker/c1`, base directory `./docker/c1/`;
- public `refs/heads/main`, 180-second interval, watch false;
- auto-discovery depth 1, delete false, force-recreate false, reconciliation disabled;
- API `127.0.0.1:8080`, metrics `127.0.0.1:9120` only;
- built-in `/doco-cd healthcheck`;
- persistent c1-named data volume and bounded JSON logs;
- Docker socket is present only in the bootstrap controller;
- no c0 SOPS identity;
- `SECRET_PROVIDER=openbao`;
- `SECRET_PROVIDER_SITE_URL=https://vault.monosense.io:8200`;
- `SECRET_PROVIDER_ACCESS_TOKEN_FILE=/run/secrets/openbao_token`;
- scoped `extra_hosts` mapping `vault.monosense.io` to `10.25.13.34`, preserving TLS SNI;
- API and token values mounted from root-only files.
- Docker restart policy disabled for both the controller and libreFS; `doco-cd-c1.service` and
  `librefs-c1.service` (with `manage-c1-librefs`) own their foreground processes. systemd requires
  Docker, `c1-librefs-storage.service`, `c1-applications-storage.service`, `assert-c1-mount`, and
  `c1-services-shim.service`, then runs the real token TTL gate before every controller start;
  `librefs-c1.service` only invokes `docker start` after the same storage units, the shim, and the
  mount assertion have all reported active. An initial Doco deploy is safe because Doco itself
  refuses to start without those storage prerequisites;

The token file is read when Doco constructs its OpenBao client. Atomically replacing a file-backed
Compose secret followed by a plain container restart can retain the old inode. Token and API-secret
changes therefore restart the systemd-owned service, whose foreground Compose command force-recreates
only the controller while preserving the named data volume. Replacement-token success first
requires public `main` to contain the exact reviewed provider-backed libreFS mapping, then requires
container health and an authenticated tracked Doco poll that exercises OpenBao resolution. The old
token is not revoked on a pre-merge Git-only poll.

Doco 0.111.0 resolves ordinary KV values before computing its rendered project hash; a changed
value can trigger recreation on the next poll. Credential rotation is gated by stopping Doco before
the KV write and starting/recreating it only when the application recreation is intended. The
initial canary must reproduce this behavior.

Rollback stops the systemd service, restores the prior image/config, and starts the service, which
force-recreates the controller while retaining its named data volume. Never delete the volume during
normal rollback.

## OpenBao decision

`docs/c1/SECRET-CONTRACT.md` is binding. Initial policy: read only
`kv/data/docker/c1/librefs`, plus self-lookup/self-renew required by the reviewed 24-hour periodic
machine-token lifecycle. No metadata/list/write/delete/sudo/future/c0/Junos capability.

Authenticated work is a separate explicit approval. It validates TLS/SNI, KV v2, audit enablement,
server token limits, exact allowed/denied capabilities, renewal, and an audit record before use.
Credentials enter through hidden input/stdin only. OpenBao remains on c0; no c0 SSH occurs. After
mutation, use the authenticated TLS Raft snapshot API
`GET /v1/sys/storage/raft/snapshot` from the workstation, feeding the admin token through a
protected FIFO/stdin header source and streaming the response directly into the existing
multi-recipient age encryption boundary. Inspect the encrypted snapshot through protected
decryption input and record only sanitized integrity evidence. If this API path or encryption/inspect
flow cannot be proven, OpenBao writes remain blocked; the c0-SSH runbook is not invoked without a
separate operator grant.

## libreFS decision

`docs/c1/LIBREFS.md` is binding. The immutable tested image is:

```text
ghcr.io/librefs/librefs:release.2026-05-04t00-42-47z@sha256:707de0b1fa0ff7c83dd72ad4bcd8225302f06a4ce5278b7356700401e95004ab
```

Use `linux/amd64`, command `server /data --console-address :9001`, static `.65`, no host ports,
UID/GID 1000, read-only root, all capabilities dropped, no-new-privileges, hardened `/tmp`, exact
bind, Compose secrets, resource/PID/nofile ceilings, 60-second grace, and bounded logs. The
Bash `/dev/tcp` HTTP readiness check is proven against this image.

Initial cleartext access is allowed only from management `10.25.10.0/24` and SERVICES
`10.25.13.0/24`; every other routed source and the public internet must fail for both API and
console. The required matrix uses one management client, the c1 SERVICES shim, one denied client in
`10.25.11.0/24`, one denied client in `10.25.12.0/24`, and one external/public vantage point. This
mission does not authorize those denied hosts; unavailable operator-provided vantage points block
real credentials/data rather than narrowing the matrix. Any denied success has the same effect.
Proceeding then requires tested TLS or another enforceable reviewed non-SRX control. No public use,
DNAT, public DNS, or certificate is part of this mission. Console remains internal.

## Future design

`docs/c1/FUTURE-EDGE.md` is binding. `.66` is reserved for HAProxy only. CrowdSec SPOA/AppSec,
Mattermost, Forgejo, and PostgreSQL remain private and undeployed. Their secrets remain blocked until
exact future versions and consumers are reviewed. No SRX mutation can occur while the Junos adoption
gate is false.

## Performance plan

No tuning precedes a baseline. Preserve MTU 1496, offloads, rings, channels, coalescing, IRQ
placement, qdiscs, sysctls, LACP hash, and in-kernel mlx4 driver.

### Network transport matrix

With approved peers whose real link paths are recorded:

- one stream and 4/8/16 parallel streams;
- both directions;
- three 60-second repetitions per case;
- at least two simultaneous peers if aggregate LACP capacity is evaluated;
- record throughput distribution, CPU, IRQs, retransmits, per-member bytes, errors, drops, and
  latency.

One flow is expected on one member. Aggregate 20 Gb/s is claimed only when measured traffic is
spread across both members and peers can source/sink it.

### S3 matrix

Use a pinned client, scratch bucket, scoped non-root credential, and deterministic non-secret data:

- 4 KiB, 1 MiB, and 64 MiB objects plus large multipart objects;
- PUT, GET, LIST, DELETE, mixed load, and checksum verification;
- documented concurrency sweep and multiple clients when available;
- record throughput/ops, p50/p95/p99, errors, CPU/RAM, NVMe latency/queue/utilization, network
  utilization, and bond-member distribution.

Acceptance thresholds are measured lower bounds constrained by disk, CPU, and actual peers; no
universal Gb/s target is invented. Change one candidate at a time. Retain only reproducible
improvement without error, tail-latency, management, thermal, or resource regression. Otherwise
revert it. Write results to `docs/c1/PERFORMANCE-BASELINE.md` after live testing.

## Repository change matrix

| Purpose | Planned files |
|---|---|
| libreFS | `docker/c1/librefs/.doco-cd.yaml`, `compose.yml`, `tests/validate.sh`, `librefs-c1.service`, `manage-c1-librefs` |
| network prerequisite | `docker/c1/.host/networks/services/ensure.sh`, tests, shim/systemd templates |
| storage prerequisite | `docker/c1/.host/storage/ensure.sh`, tests, and single-device approval/assertion helpers (no engine config install) |
| token lifecycle | `docker/c1/.host/openbao/` renewal/install scripts and systemd templates |
| OpenBao policy | `docker/c0/openbao/policies/doco-c1.hcl` plus offline capability assertions |
| validation | `docker/mod.just`, `.github/workflows/docker.yaml`, `docker/README.md` |
| design/operations | `docs/c1/*.md`, `CHANGELOG.md` |

Paths may be narrowed to stronger adjacent conventions during implementation; no second framework is
introduced.

## Repository test plan

`just docker validate-c1` must prove:

- storage regression matrix: signature stability across `check → plan → apply`; rejection of LVM/
  RAID/holder/`fuser`/open users on the 1 TB device and any non-1 TB by-id input; mount-source
  absence assertion before commit (`/srv/librefs`, `/srv/applications`); stable by-id binding
  against partition by-id and any non-by-id input; root-disk device rejection; NVMe
  critical-warning, media/data-integrity, and available-spare bound to the plan digest;
  `saved`/`pristine`/`partial-child` pending-digest state revalidation; one GPT with two
  1 MiB-aligned partitions geometry assertion; `XFS` filesystem-type assertion; no-wipe assertion
  on byte-identical retry;
- exact Doco image, names, paths, polling, loopback listeners, provider file auth, no SOPS identity,
  volume/log/health behavior, and bootstrap discovery exclusions;
- storage check/plan/apply approves only the single 1 TB by-id, rejects the OS device, every
  non-1 TB by-id input, and the 512 GB device; the approval parser enforces the exact six-line
  APPROVE C1 STORAGE block, rejects any 512GB line, and rejects mismatched PARTITION_LAYOUT;
- no committed stable IDs, UUIDs, serials, secrets, or approval tokens;
- OpenBao policy permits only intended read and self-renew paths and denies metadata/list/write,
- rendered libreFS image/platform/IP/network/mount/no-port/no-socket/non-root/read-only/security,
  limits/logs/health/secrets, absence of `latest` or plaintext credentials, and `restart: no` so
  Docker cannot auto-restart libreFS;
- Compose render uses safe non-secret CI canaries;
- no recognized Compose filename under `.doco-cd` or `.host`;
- rendered `librefs-c1.service` and `manage-c1-librefs` ordering requires
  `c1-librefs-storage.service`, `c1-applications-storage.service`, `assert-c1-mount`, and
  `c1-services-shim.service` active before `docker start`; `doco-cd-c1.service` requires the same
  storage prerequisites plus the token TTL gate before its controller start;
- existing `validate-c0`, Gitleaks, yamllint, shell syntax, and actionlint remain in CI.

The pre-existing c0 exit-1 failure must be diagnosed and kept separate. c1 work may not bypass or
weaken it.

## Implementation and live sequence

1. independent adversarial review of all design documents;
2. close/reject every CRITICAL/HIGH finding with evidence;
3. repository implementation only;
4. all offline validations, Gitleaks, diff review, and second implementation review;
5. atomic local commits; no push;
6. approved diagnostic-package install and c1 configuration backups;
7. exact disk health/identity/content recheck and storage approval;
8. provision/mount 1 TB partitions (libreFS and applications) on the approved single NVMe, verify UUID/XFS/RW/fstab assertions for both;
9. Docker/containerd roots remain on the OS disk; prove libreFS and affected bind-mounted applications fail closed if either partition is missing;
10. conclusive `.65/.66` collision checks;
11. apply shim/network and prove management/LACP/VLAN state;
12. separate OpenBao approval, policy/KV/token/audit/backup work;
13. bootstrap c1 Doco and pass boundary/provider/leakage canary checks;
14. explicit branch push approval, PR/CI/review, explicit merge approval, verify main;
15. observe Doco deploy only libreFS;
16. functional, security, performance, and backup-status verification;
17. service/Doco/Docker restarts;
18. explicit reboot approval and full persistence verification;
19. optional separately approved bond-member failover;
20. final report; old-root retirement remains a later cleanup approval.

## Checkpoints and stop conditions

### Storage approval

Immediately before destructive work, present the exact stable 1 TB by-id path, model/size, current
signatures, the two partition roles `/srv/librefs` and `/srv/applications`, the explicit OS-disk
exclusion, the explicit 512 GB exclusion (quarantined/unmounted, no argument to the script), and
rollback limits.

The generated plan and approval presentation also include `PLAN_SHA256`, the single-device identity,
the observed 1 TB signatures, the explicit GPT/wipe action, the exact 50:50 partition split, the
OS-disk and 512 GB exclusions, and formatting rollback limits. The operator approval must contain
the required identity lines plus the evidence binding:

```text
APPROVE C1 STORAGE
1TB=<exact stable by-id>
PLAN_SHA256=<exact reviewed plan digest>
1TB_SIGNATURES=<exact observed state>
PARTITION_LAYOUT=50% LIBREFS + 50% APPLICATIONS
ACKNOWLEDGE_WIPE=ERASE APPROVED 1TB TARGET ONLY
```

A vague confirmation is invalid. Stop on ambiguity, changed signatures, unexplained content, health
concern, or any OS/root relationship.

Separate explicit approvals are required for OpenBao writes, push, merge, reboot, and deliberate
bond-member failure. No force push, auto-approve, yolo mode, c0/SRX SSH, or Junos mutation.

Immediate stops also include management-route/interface/DNS change, unhealthy LACP aggregator, IP
collision/inconclusive final probe, OpenBao sealed/TLS failure, excess policy privilege, secret
leakage, unpinned/unverified image, any 512 GB device reference, mission-caused CI/Gitleaks failure,
unresolved CRITICAL/HIGH review finding, required SRX mutation, or claimed backup without restore.

## Risk register

| Severity | Risk | Required closure |
|---|---|---|
| CRITICAL | wrong disk/OS disk destruction | single 1 TB by-id binding, OS-device rejection, immediate recheck, exact approval |
| CRITICAL | 512 GB device reused or referenced | script takes no 512 GB argument; quarantine enforced by exclusion, not by approval |
| HIGH | missing NVMe health evidence | install diagnostics and accept healthy counters before format |
| HIGH | `.65/.66` collision unknown | conclusive duplicate-address procedure before assignment |
| HIGH | libreFS writes to OS disk | no underlying `data` directory, create_host_path false, mount assertion, negative test |
| HIGH | Doco/Compose secret persistence | canary leakage scan; block real credentials on unexpected persistence |
| HIGH | over-broad or expiring token | exact policy capability tests, periodic renewal/alert, controlled replacement/restart |
| HIGH | HTTP reachability broader than intended | live source-boundary test or reviewed TLS/firewall before real data |
| HIGH | no off-host restore | status cap `OPERATIONAL_WITHOUT_DURABILITY` |
| HIGH | libreFS maturity/provenance gaps | immutable digest, tested runtime, internal-only boundary, backup, monitored upgrades |
| MEDIUM | LACP overclaim or harmful tuning | evidence matrix, one-variable changes, revert non-beneficial changes |
| MEDIUM | historical link failures/min-links zero | preserve configuration, baseline counters, optional separately approved failover |
| MEDIUM | pre-existing c0 validation failure | diagnose separately; never mask in c1 validation |

## Acceptance

Repository, host, network, OpenBao, secret-leak, S3, performance, backup-status, restart, and reboot
evidence must meet the mission criteria. Without off-host restore proof, final status is
`OPERATIONAL_WITHOUT_DURABILITY`; without reboot approval/proof, it is `PARTIALLY_COMPLETE` with an
explicit blocker. No future service or SRX change is deployed.
