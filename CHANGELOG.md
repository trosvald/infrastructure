# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added

- Added Blocky DNS proxy (`blocky-c0`) for c0: Cloudflare and Quad9 DoH upstreams, HaGeZi Multi
  NORMAL blocklist, conditional forwarding of `monosense.io` and reverse zones to local PowerDNS,
  DNSSEC validation disabled, read-only root, no persistent state.
- Added a pinned, polling-only Doco-CD bootstrap configuration for c0 with c0-scoped discovery and
  loopback-only management endpoints.

### Changed

- Refactored c0 into a host-scoped Doco-CD layout under `docker/c0/`, separating controller source,
  host prerequisites, and direct-child managed applications.
