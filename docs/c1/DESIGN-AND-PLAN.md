# c1 Design and Plan

Date: 2026-08-26  
Status: ready for independent review; live mutation blocked by the checkpoints below

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
persistent roots on 1 TB XFS        kv/docker/c1/*
       |
       +-- external IPvlan c1_services
             parent bond0.2513, MTU 1496
             allocation 10.25.13.64/27
             host shim 10.25.13.17/32
             |
             `-- libreFS 10.25.13.65
                   /data -> 512 GB XFS
```

Management remains `eno1`, `10.25.10.101/24`, default gateway `10.25.10.1`, DNS
`10.25.10.100`. Nothing in this design rewrites that interface, address, route, or resolver.

## Storage decision

### Layout

| Physical role | Partition/filesystem | Mount | Persistent content |
|---|---|---|---|
| 500 GB SATA OS disk | unchanged | existing mounts | operating system only |
| approved 1 TB NVMe | GPT, one aligned XFS partition, CRC/reflink, verified `ftype=1`, label `c1_containers` | `/srv/containers` | Docker root, containerd root, Doco named volume, future application state |
| approved 512 GB NVMe | GPT, one aligned XFS partition, CRC/reflink, verified `ftype=1`, label `c1_librefs` | `/srv/librefs` | libreFS `/srv/librefs/data` only |

Use filesystem UUIDs in `/etc/fstab`. Stable by-id paths identify destructive inputs and are kept in
a root-only host-local approval record, not Git. Labels are diagnostic, never the mount authority.
Mount options are `defaults,noatime`; no `nofail` and no continuous `discard`. Enable and verify
`fstrim.timer`.

XFS is selected because it supports Docker overlay/containerd storage and the selected libreFS build
passed ordinary filesystem-backed operation. Docker validation must prove `ftype=1`. LVM, RAID,
multiple partitions, exotic allocation tuning, and using the 1 TB disk as a backup are rejected.

### Engine roots and mount ordering

Docker 29 stores image/layer data under the system containerd root as well as Docker `data-root`.
Configure both:

```text
Docker data-root: /srv/containers/docker
containerd root: /srv/containers/containerd
containerd state: existing volatile /run location
```

Containerd and Docker systemd drop-ins use `RequiresMountsFor=/srv/containers` and order after the
mount. A root-owned pre-start assertion verifies expected source/UUID, XFS, RW state, and `ftype=1`;
a directory alone never passes. Containerd starts before Docker.

libreFS uses long-syntax bind mount `/srv/librefs/data:/data` with
`bind.create_host_path: false`. Provisioning creates `data` only while `/srv/librefs` is the verified
512 GB mount, then makes it UID/GID 1000 mode `0750`. The directory is absent beneath the unmounted
OS mountpoint. Missing/wrong storage therefore prevents Compose startup rather than writing to the
OS disk.

### Provisioning interface

`docker/c1/.host/storage/ensure.sh` exposes:

- `check`: read-only inventory/assertions, sanitized output;
- `plan`: read-only destructive plan with hashed/suffixed identity evidence and a SHA-256 digest over
  the exact stable paths, resolved devices, models, sizes, observed signatures/GPT state, roles,
  intended wipe/partition/format actions, mount paths, and OS-disk exclusion;
- `apply`: accepts exact stable by-id inputs, the reviewed plan digest, and the exact approval token
  through protected stdin; it recomputes the plan immediately before writes and requires a
  byte-identical digest.

Initial planning rejects the root/boot/swap backing disk, unstable names, symlink/target
disagreement, mounts, partitions, unapproved signatures, LVM, RAID, holders, open files, size/model
mismatch, and changed evidence. A persisted approved transaction permits only its own verified
pending or complete single-partition state. The known 512 GB GPT becomes expected only when the
approved plan explicitly identifies and authorizes its removal. Before the first write, apply
atomically persists the complete approved plan.
Each disk records an atomic pending UUID immediately after formatting; the filesystem is then
mounted by its partition and fully asserted before the hard UUID fstab entry is committed. Only
after fstab verification does pending state become complete. A retry with the same byte-identical
approval resumes a verified pending stage or skips a verified complete stage; it never reformats a
disk carrying complete state. Offline tests cover mount failure before fstab, resume, idempotent
complete re-entry, and rejection boundaries without creating a real block-device signature.

The existing GPT on the 512 GB target is an immediate stop condition until its provenance, observed
signature state, plan digest, and removal are explicitly approved.

### Engine migration

Read-only follow-up established the current engine contract: `/etc/containerd/config.toml` disables
CRI and has no active root override; effective root/state are `/var/lib/containerd` and
`/run/containerd`, snapshotter is overlayfs, Docker connects to `/run/containerd/containerd.sock`,
neither unit has a drop-in or mount requirement, and `/etc/docker/daemon.json` is absent.

After approval and configuration backup:

1. prove current containers/volumes/projects and valuable state again;
2. capture sanitized effective containerd config and exact Docker/containerd unit properties again;
3. stop Doco if present, Docker socket/Docker, and containerd;
4. prove no process uses either old root;
5. mount/assert `/srv/containers`;
6. copy `/var/lib/containerd/` to `/srv/containers/containerd/` and `/var/lib/docker/` to
   `/srv/containers/docker/` with numeric ownership, hardlinks, ACLs, xattrs, sparse files, and
   timestamps preserved;
7. add a minimal containerd systemd drop-in that preserves the existing config and changes only the
   `ExecStart` root argument to `/srv/containers/containerd`, plus `RequiresMountsFor`; add a minimal
   Docker `daemon.json` containing only `data-root` and a mount-order drop-in;
8. start containerd, then Docker;
9. verify effective config, roots, prior inventory, image usability, and one disposable
   pull/create/remove smoke;
10. stop both engines, remove only the new overrides/config, start the untouched old roots, and
    prove the original inventory and image usability;
11. stop engines again, discard the disposable new-root writes, recopy the still-authoritative old
    roots, reapply the reviewed minimal overrides, start, and repeat acceptance;
12. declare the second successful switch the no-production-write transaction boundary; only then
    may Doco or libreFS create durable state;
13. retain old roots read-only until reboot and mission acceptance; retire them only under a
    separate cleanup approval.

The copy primitive is reviewed before use and equivalent to:

```text
rsync -aHAXSx --numeric-ids SOURCE/ DESTINATION/
```

No cleanup/prune command is permitted. The rollback rehearsal intentionally discards only the
documented disposable smoke delta. After production writes begin, rollback requires quiescing
applications and a separately reviewed export/restore or delta migration; no automatic backward
metadata copy is safe. Formatting cannot recover unknown pre-existing disk content, and a GPT
backup restores metadata only.

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
- Docker restart policy disabled; `doco-cd-c1.service` owns the foreground Compose process;
- systemd requires Docker, the container/libreFS mount assertions, and the SERVICES shim, then runs
  the real token TTL gate before every controller start;

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
| controller | `docker/c1/.doco-cd.yaml`, `.doco-cd/docker-compose.app.yaml`, `.doco-cd/poll-config.yml` |
| network prerequisite | `docker/c1/.host/networks/services/ensure.sh`, tests, shim/systemd templates |
| storage prerequisite | `docker/c1/.host/storage/ensure.sh`, tests, assertion and systemd/config templates |
| token lifecycle | `docker/c1/.host/openbao/` renewal/install scripts and systemd templates |
| libreFS | `docker/c1/librefs/.doco-cd.yaml`, `compose.yml`, `tests/validate.sh` |
| OpenBao policy | `docker/c0/openbao/policies/doco-c1.hcl` plus offline capability assertions |
| validation | `docker/mod.just`, `.github/workflows/docker.yaml`, `docker/README.md` |
| design/operations | `docs/c1/*.md`, `CHANGELOG.md` |

Paths may be narrowed to stronger adjacent conventions during implementation; no second framework is
introduced.

## Repository test plan

`just docker validate-c1` must prove:

- exact Doco image, names, paths, polling, loopback listeners, provider file auth, no SOPS identity,
  volume/log/health behavior, and bootstrap discovery exclusions;
- network absent/create/exact/drift/ambiguous/parent/attached/post-create failures;
- storage check/plan/apply approval parser and every reject path with command mocks only;
- no committed stable IDs, UUIDs, serials, secrets, or approval tokens;
- OpenBao policy permits only intended read and self-renew paths and denies metadata/list/write,
  unrelated c1/global/c0/Junos, delete, and sudo;
- rendered libreFS image/platform/IP/network/mount/no-port/no-socket/non-root/read-only/security,
  limits/logs/health/secrets and absence of `latest` or plaintext credentials;
- Compose render uses safe non-secret CI canaries;
- no recognized Compose filename under `.doco-cd` or `.host`;
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
8. provision/mount 1 TB tier, migrate containerd and Docker, verify rollback;
9. provision/mount 512 GB tier and prove fail-closed bind source;
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

Immediately before destructive work, present both exact stable by-id paths, model/size, current
signatures, roles `/srv/containers` and `/srv/librefs`, explicit OS-disk exclusion, and rollback
limits.

The generated plan and approval presentation also include `PLAN_SHA256`, each observed signature,
the explicit GPT/wipe action, OS-disk exclusion, and formatting rollback limits. The operator
approval must contain the required identity lines plus the evidence binding:

```text
APPROVE C1 STORAGE
1TB=<exact stable by-id>
512GB=<exact stable by-id>
PLAN_SHA256=<exact reviewed plan digest>
1TB_SIGNATURES=<exact observed state>
512GB_SIGNATURES=<exact observed GPT/PMBR state>
ACKNOWLEDGE_WIPE=ERASE APPROVED TARGETS ONLY
```

A vague confirmation is invalid. Stop on ambiguity, changed signatures, unexplained content, health
concern, or any OS/root relationship.

Separate explicit approvals are required for OpenBao writes, push, merge, reboot, and deliberate
bond-member failure. No force push, auto-approve, yolo mode, c0/SRX SSH, or Junos mutation.

Immediate stops also include management-route/interface/DNS change, unhealthy LACP aggregator, IP
collision/inconclusive final probe, OpenBao sealed/TLS failure, excess policy privilege, secret
leakage, unpinned/unverified image, root-disk fallback, mission-caused CI/Gitleaks failure,
unresolved CRITICAL/HIGH review finding, required SRX mutation, or claimed backup without restore.

## Risk register

| Severity | Risk | Required closure |
|---|---|---|
| CRITICAL | unexplained GPT on 512 GB target | provenance/content review plus exact destructive approval |
| CRITICAL | wrong disk/OS disk destruction | stable by-id binding, root-device rejection, immediate recheck, exact approval |
| HIGH | missing NVMe health evidence | install diagnostics and accept healthy counters before format |
| HIGH | `.65/.66` collision unknown | conclusive duplicate-address procedure before assignment |
| HIGH | Docker starts without 1 TB mount | fstab hard requirement, systemd RequiresMountsFor, pre-start assertion, negative test |
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
