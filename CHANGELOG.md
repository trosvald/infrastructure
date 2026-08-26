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
- Added the isolated Junos SRX1500 intent refactor: deterministic seven-domain rendering, exact
  NETCONF identity/release gates, protected transient artifacts, and digest-bound
  commit-check/commit-confirmed lifecycle. The tracked adoption record remains false, so live
  deployment and drift are intentionally fail-closed pending manual parity review.

### Changed

- Refactored c0 into a host-scoped Doco-CD layout under `docker/c0/`, separating controller source,
  host prerequisites, and direct-child managed applications.
