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
  on the c1 OS disk; the healthy 1 TB NVMe is planned as two approximately equal XFS partitions
  (`/srv/librefs` and `/srv/applications`); the 512 GB NVMe is quarantined/unmounted/excluded
  after 941 historical media/data-integrity errors despite successful short/extended self-tests.
  Revised code/review and exact single-device 1 TB approval remain gates; live c1 deployment is
  intentionally blocked.
- Recorded the c1 1 TB apply attempt that failed safely (XFS hard 12-char label limit rejected the
  16-char `c1_applications` filesystem label on partition 2; filesystem label corrected to
  `c1_apps`, GPT PARTLABEL `c1_applications` unchanged). Partial state was rolled back to a blank
  GPT; the prior plan digest and `APPROVE C1 STORAGE` are invalidated, and a fresh single-device
  plan plus the six-line approval are required before retry.
