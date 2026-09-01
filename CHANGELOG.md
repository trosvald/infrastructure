# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added

- Added authenticated SRX flow-log streaming to Vector over TLS with a dedicated
  SOPS-custodied internal CA, protected leaf rotation, exact SRX trust bootstrap,
  bounded operational verification, and 14-day local evidence retention.
- Added Blocky DNS proxy (`blocky-c0`) for c0 with reviewed upstream,
  conditional-forwarding, read-only, and no-persistent-state controls. Production
  rollout and client cutover remain outside this repository's automation scope.
- Added a pinned, polling-only Doco-CD bootstrap configuration for c0 with c0-scoped discovery and
  loopback-only management endpoints.
- Added the reviewed c1 repository foundation: pinned Doco-CD and libreFS configuration,
  fail-closed network and storage prerequisites, narrow OpenBao policy and token lifecycle,
  deterministic offline tests, CI validation, and gated operations. No c1 or OpenBao live state is
  changed by this repository addition.
- Added the isolated Junos SRX1500 intent refactor: deterministic seven-domain rendering, exact
  NETCONF identity/release gates, protected transient artifacts, and digest-bound
  commit-check/commit-confirmed lifecycle and a non-overrideable tracked adoption gate.
- Added confirmation-gated, CAS-zero OpenBao provisioning for the authenticated Cilium BGP
  password and protected five-node Talos topology/secrets. Real hardware inventory is validated
  without printing identifiers, and Talos secrets are generated once with the locked client.

### Changed

- Migrated repository ownership of c0/c1 Debian host state and resident lifecycle helpers into the
  isolated `ansible/container-nodes/` project, with fixed adoption-, secret-, network-, and
  storage-gated Just actions. Doco-CD remains the sole application Compose deployment owner. This
  repository migration does not claim live host adoption, convergence, secret rotation, network
  activation, or application deployment.

- Refactored c0 into a host-scoped Doco-CD layout under `docker/c0/`, separating controller source,
  host prerequisites, and direct-child managed applications.
- Completed the reviewed SRX1500 direct-configuration adoption into `ANSIBLE_SRX1500`: encrypted
  recovery was proven on c1, the atomic commit-confirmed migration retained device-local
  authentication, managed parity and fail-closed authenticated Cilium BGP preflight passed, and
  the separately reviewed adoption record is now true.
- Revised the c1 repository foundation: Docker engine state, containerd, and named volumes stay
  on the c1 OS disk; the healthy 1 TB NVMe is split approximately 50:50 as XFS partitions mounted
  at `/srv/librefs` (label `c1_librefs`) and `/srv/applications` (XFS label `c1_apps`, GPT
  PARTLABEL `c1_applications`) and verified `noatime`; the 512 GB NVMe is quarantined,
  unmounted, and excluded. Revised code and review plus an exact single-device 1 TB approval have
  landed; the corrected storage plan was approved and the 1 TB split retry succeeded with both
  partitions mounted and verified. Remaining gates are OpenBao, push/merge/deploy/reboot/backup.
- Recorded c1 initial apply attempts that failed safely with no live change: the 1 TB apply was
  rejected for exceeding XFS hard 12-char label length on partition 2 (filesystem label corrected
  to `c1_apps`; GPT PARTLABEL `c1_applications` unchanged) and rolled back to a blank GPT, the c1
  SERVICES shim creation was rejected for exceeding Linux `IFNAMSIZ` (interface corrected to
  `c1-svc-shim`; service and helper filenames unchanged), and Doco/Compose v5.5 rejected
  `secrets.environment` for the read-only service before container creation. The operator
  selected the documented writable-root exception because neither Doco nor Compose v5.5 can inject
  inline configs into `read_only` services; the exception preserves UID 1000, capability drops,
  `no-new-privileges`, the config-backed `0400` credential files mounted via `configs.content`,
  and the `_FILE` environment paths, while publishing no ports or socket. The substitution is
  justified by an actual runtime test that generated and read a unique canary through the same
  path the service uses. Docker Compose 5.5.0 is now mise-locked and activated in CI to match the
  embedded injection semantics of Doco 0.111, and the writable-root credential canary is part of
  that CI step and is non-skippable. PR7 fixed the checker for `.content.status`; two CAS
  libreFS credential rotations completed through Doco/OpenBao with the old exact values absent
  after the second scan and the admin token/material removed. A new fail-closed operator helper
  `rematerialize-librefs-credentials.sh` exists because Doco 0.111 does not rematerialize
  external-secret changes on unchanged Git; it removes and recreates only the stateless container
  and preserves `/data` and volumes. After correction, the fresh single-device plan plus the six-line
  `APPROVE C1 STORAGE` were approved, the 1 TB split retry succeeded with both partitions mounted
  and verified `noatime`, and the c1 SERVICES shim `c1-svc-shim` plus the persistent
  `c1_services` network were applied and verified. Scoped non-root S3 CRUD and checksum passed
  with unauthorized bucket creation denied; the 512 MiB same-host S3 baseline measured
  567,957,345 B/s upload and 1,863,741,635 B/s download. Routed workstation-to-SERVICES TCP
  baseline was about 113.95 Mbit/s sender and 112.62 Mbit/s receiver, which is path-limited and
  not indicative of 10 Gb / LACP capacity. Off-host backup status is verified unconfigured and
  unproven, so the current cap is `OPERATIONAL_WITHOUT_DURABILITY`. PR8 merged as
  `599fff0e01301d77f5a2e204bac5df9a519f1823` and the reviewed rematerialization helper was
  installed. Approved reboot outage and recovery plus full mount, network, LACP, Doco, OpenBao,
  libreFS, and credential-leakage persistence passed; post-reboot scoped S3 512 MiB measured
  542,280,200 B/s upload and 2,014,577,014 B/s download. Optional bond-member failover was
  explicitly skipped and is not a blocker. Mission is complete at
  `OPERATIONAL_WITHOUT_DURABILITY` solely because off-host backup and restore are absent.
