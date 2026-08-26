# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added

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
  commit-check/commit-confirmed lifecycle. The tracked adoption record remains false, so live
  deployment and drift are intentionally fail-closed pending manual parity review.

### Changed

- Refactored c0 into a host-scoped Doco-CD layout under `docker/c0/`, separating controller source,
  host prerequisites, and direct-child managed applications.
- Revised the c1 repository foundation: Docker engine state, containerd, and named volumes stay
  on the c1 OS disk; the healthy 1 TB NVMe is split approximately 50:50 as XFS partitions mounted
  at `/srv/librefs` (label `c1_librefs`) and `/srv/applications` (XFS label `c1_apps`, GPT
  PARTLABEL `c1_applications`) and verified `noatime`; the 512 GB NVMe is quarantined,
  unmounted, and excluded. Revised code and review plus an exact single-device 1 TB approval have
  landed; the corrected storage plan was approved and the 1 TB split retry succeeded with both
  partitions mounted and verified. Remaining gates are OpenBao, push/merge/deploy/reboot/backup.
- Recorded c1 initial apply attempts that failed safely with no live change: the 1 TB apply was
  rejected for exceeding XFS hard 12-char label length on partition 2 (filesystem label corrected
  to `c1_apps`; GPT PARTLABEL `c1_applications` unchanged) and rolled back to a blank GPT, and the
  c1 SERVICES shim creation was rejected for exceeding Linux `IFNAMSIZ` (interface corrected to
  `c1-svc-shim`; service and helper filenames unchanged). After correction, the fresh single-device
  plan plus the six-line `APPROVE C1 STORAGE` were approved, the 1 TB split retry succeeded with
  both partitions mounted and verified `noatime`, and the c1 SERVICES shim `c1-svc-shim` plus the
  persistent `c1_services` network were applied and verified. Remaining gates are OpenBao,
  push/merge/deploy/reboot/backup.
