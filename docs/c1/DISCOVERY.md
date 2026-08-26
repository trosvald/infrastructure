# c1 Discovery

Date: 2026-08-26  
Repository base: `50290c242a9ded1890124c633614c6780df8ca90`

This document contains sanitized findings only. It excludes MAC addresses, machine UUIDs, full disk
serials, WWNs, filesystem UUIDs, stable by-id paths, credentials, tokens, and raw command dumps.
Exact destructive device identities remain an operator checkpoint and are not repository data.

## Status

Discovery supports repository design, but live storage mutation is blocked:

- the intended 512 GB libreFS NVMe contains a valid GPT/PMBR despite having no partitions;
- neither NVMe has SMART/NVMe health evidence because `smartctl` and `nvme-cli` are absent;
- absence of recognized signatures on the 1 TB NVMe does not prove absence of raw data;
- `.65` and `.66` are unclaimed in repository IPAM, but live duplicate-address probing is
  inconclusive because `arping` is absent;
- OpenBao health and TLS are proven, but authenticated KV mount, policy, token-lifecycle, and audit
  metadata remain unverified;
- no safe benchmark tooling or proven multi-peer test topology is currently available.

No host, OpenBao, network, storage, package, or service mutation occurred during discovery.

## Repository baseline

The clean local `main` and `origin/main` both resolved to the base above. Work continues on
`feat/c1-doco-librefs`. The locked toolchain was already installed. The pre-change Gitleaks scan
passed.

`just docker validate-c0` was already failing with exit 1 after its OpenBao certificate tests
passed; the command emitted no failing assertion. This is a pre-existing baseline failure, not a c1
regression. The first invocation also exposed that non-interactive shells need the locked mise bin
paths on `PATH`; the rerun used those paths and reached the same silent exit 1.

## Existing repository conventions

c0 establishes one boundary:

- bootstrap controller: `docker/c0/.doco-cd/`;
- bootstrap host prerequisites: `docker/c0/.host/`;
- Doco-managed applications: direct children of `docker/c0/`;
- controller source filename: `docker-compose.app.yaml`, intentionally not a recognized Compose
  discovery filename;
- host auto-discovery: depth 1, delete false, force-recreate false, reconciliation disabled;
- poll source: public repository `refs/heads/main`, every 180 seconds;
- controller image:
  `ghcr.io/kimdre/doco-cd:0.111.0@sha256:8c31f63f6bde1b67f0802619bad0599bf5e41503f5532be9cc58d0f063b1eeea`;
- controller API and metrics: loopback-only ports 8080 and 9120;
- services: immutable tag-plus-digest images, no host ports, explicit external IPvlan addresses;
- prerequisites: preflight, create only when absent, inspect exact immutable state, fail on drift,
  and never delete attached networks automatically;
- validation: shell fakes for failure paths, rendered Compose JSON assertions, discovery-boundary
  checks, and path-scoped CI.

The current Docker workflow watches `docker/**` and selected root/config documentation paths. It
runs only the c0 validation today. `docker/c1` contains only `.gitkeep`.

OpenBao is declared at `10.25.13.34` with TLS, Raft storage, and audit output enabled. Repository
policy examples use KV v2 API paths in `kv/data/...` form. Junos automation remains gated by
`ansible/junos/adoption.yml` with `adopted: false`; no SRX change is available to this mission.

Repository SERVICES reservations are:

| Address or range | Owner |
|---|---|
| `10.25.13.1` | SERVICES gateway |
| `10.25.13.16` | c0 host shim |
| `10.25.13.17` | planned c1 host shim |
| `10.25.13.33` | PowerDNS |
| `10.25.13.34` | OpenBao |
| `10.25.13.35` | Blocky |
| `10.25.13.65-94` | planned c1 allocation |

No repository source claims `.65` or `.66` individually.

## Verified c1 platform

- Lenovo ThinkCentre M920x; BIOS dated 2024-01-26.
- Intel Core i7-8700T: 6 cores, 12 threads.
- 62 GiB usable RAM from two 32 GB DDR4-2667 SODIMMs.
- Debian 13 (trixie), kernel `6.12.101+deb13-amd64`, EFI boot.
- NTP synchronized; RTC uses UTC.
- Docker Engine 29.7.2 and Docker Compose 5.5.0.
- cgroup v2 with the systemd cgroup driver.

## Storage mapping

| Sanitized role | Model and usable size | Evidence | Status |
|---|---|---|---|
| OS, excluded | Samsung SSD 860 EVO 500GB, 465.8 GiB | EFI and `/boot` partitions plus LVM root and swap | Never touch |
| libreFS target | TEAM TM8FP6512G, 476.9 GiB; identity suffix `0351` | No partitions, but valid primary/backup GPT and PMBR | Blocked pending provenance and exact approval |
| container tier target | PNY CS1031 1TB SSD, 931.5 GiB; identity suffix `0E10` | No recognized signature or partition table | Blocked pending health and exact approval |

The host has no containers, Compose projects, or Docker volumes. It has three untagged images and
about 1.0 GB of reclaimable image data. No valuable running Docker state was identified, but image
inactivity alone is not proof of disposability.

Docker uses the containerd image store. `/var/lib/docker` is only about 260 KiB while
`/var/lib/containerd` holds about 986 MiB. Changing Docker `data-root` alone therefore does not
satisfy the requirement to place all engine image/layer state on the 1 TB tier; the design must
move and mount-order both Docker and containerd persistent roots.

A follow-up read-only engine query found `/etc/containerd/config.toml` only disables CRI; there are
no active containerd drop-ins, Docker/containerd systemd drop-ins, mount requirements, or
`/etc/docker/daemon.json`. Effective containerd root/state are `/var/lib/containerd` and
`/run/containerd`, the snapshotter is overlayfs, and Docker connects to
`/run/containerd/containerd.sock`. A minimal root override can therefore preserve every other
effective setting, but all facts require immediate recheck before cutover.

No disk benchmark ran. `fio`, `ioping`, `nvme-cli`, and `smartctl` are absent.

## Network state

Management is independent of the SERVICES bond:

- `eno1`: `10.25.10.101/24`, MTU 1500, 1 Gb/s full duplex;
- default route: `10.25.10.1` on `eno1`;
- DNS: `10.25.10.100` with search domain `monosense.io`;
- no policy route redirects management traffic.

SERVICES transport:

- `bond0`: 802.3ad, two in-kernel `mlx4` ConnectX-3-class 10 Gb/s full-duplex members;
- both members are synchronized, collecting, distributing, and in the same active aggregator;
- fast LACP, 100 ms MII monitoring, `layer3+4` transmit hash, parent MTU 1500;
- `bond0.2513`: VLAN 2513, link up, MTU 1496, no address or route;
- VLAN 2512 is also present and unchanged;
- observed link, qdisc, and interface counters had no current errors or drops;
- each bond member reports two historical link failures;
- `bond-min-links` is effectively zero and must not be changed without a reviewed availability
  decision.

A single 5-tuple hashes to one LACP member. The 20 Gb/s figure is aggregate link capacity, not a
valid single-flow claim.

Current routes to `10.25.13.1` and OpenBao `10.25.13.34` use the management default route through
`10.25.10.1`. Adding only `10.25.13.64/27` through the future host shim will not divert OpenBao
traffic and will not alter the default route.

The host uses ifupdown. `/etc/network/interfaces` declares the management interface, the manual
bond, and manual VLANs; the include directory had no regular configuration files. The host shim
must be additive and must preserve these stanzas.

`vault.monosense.io` resolves to `10.25.13.34`. A TLS-validating unauthenticated health request to
`https://vault.monosense.io:8200/v1/sys/health` returned HTTP 200. The sanitized response proved
initialized, unsealed, active, performance-primary, and DR-disabled state. Live collision checks for
`.65` and `.66` remain inconclusive.

## Upstream verification

### Doco-CD

The c0 compatibility baseline is 0.111.0. Upstream 0.112.0 exists, but this mission has no verified
compatibility reason to diverge, so design should retain 0.111.0 and leave c0 unchanged.

Official 0.111.0 sources verify:

- provider variables: `SECRET_PROVIDER=openbao`, `SECRET_PROVIDER_SITE_URL`, and
  `SECRET_PROVIDER_ACCESS_TOKEN_FILE`;
- KV reference syntax: `kv:<optional-namespace>:<engine>:<secret-name>:<key>`;
- app mapping: `.doco-cd.yaml` `external_secrets` maps deployment variable names to references;
- the token file is parsed when provider configuration is constructed and the client retains that
  token; token replacement requires controlled controller force-recreation so a replaced
  file-backed secret is remounted;
- ordinary KV values are resolved before the rendered project hash is compared; a value change can
  trigger recreation on the next poll, so operator-gated rotation stops Doco before the KV write;
- values may feed Compose `configs` or `secrets`, avoiding application environment values when the
  selected image supports file variables.

Sources:

- <https://raw.githubusercontent.com/kimdre/doco-cd/v0.111.0/wiki/docs/External-Secrets/Openbao.md>
- <https://raw.githubusercontent.com/kimdre/doco-cd/v0.111.0/internal/secretprovider/openbao/config.go>
- <https://raw.githubusercontent.com/kimdre/doco-cd/v0.111.0/internal/secretprovider/openbao/client.go>

### libreFS

Selected upstream candidate:

- release: `RELEASE.2026-05-04T00-42-47Z`;
- tag: `release.2026-05-04t00-42-47z`;
- multi-platform index digest:
  `sha256:2ff2fc333eabc64c12282ccce42638bcaba8dcaa89d6ad7bbe2e50c177e4c227`;
- tested `linux/amd64` manifest digest:
  `sha256:707de0b1fa0ff7c83dd72ad4bcd8225302f06a4ce5278b7356700401e95004ab`;
- source revision: `e194bd779f36fdc08f310d2819d9356f0c1f991b`.

The pulled amd64 image was exercised locally with safe dummy file credentials and an isolated data
directory. Verified behavior:

- entrypoint `/usr/bin/docker-entrypoint.sh`;
- required command `server /data --console-address :9001`;
- API and console ports 9000 and 9001;
- persistent path `/data`;
- `MINIO_ROOT_USER_FILE` and `MINIO_ROOT_PASSWORD_FILE` exist in the selected source and worked in
  the running image;
- `/minio/health/live` and `/minio/health/ready` returned HTTP 200;
- unauthenticated `/minio/v2/metrics/cluster` returned HTTP 403;
- the image contains `sh` and `bash`, but neither `curl` nor `wget`;
- the image declares no embedded healthcheck and no non-root `User`; root is the image default;
- a second probe succeeded as UID/GID 1000 with a read-only root filesystem, all capabilities
  dropped, `no-new-privileges`, writable `/data`, `HOME=/tmp`, and a hardened `/tmp` tmpfs;
- an HTTP readiness check implemented with the image's `/usr/bin/bash` and `/dev/tcp` received
  `HTTP/1.0 200 OK`; this is the viable in-container healthcheck because `curl` and `wget` are absent;
- `docker inspect` exposed only secret-file paths, not credential values.

The image carries OCI source/version/revision labels and a BuildKit SLSA provenance attestation
whose builder identifies the official repository workflow. No SBOM was exposed by Buildx, and no
keyless signature verification was completed. The embedded binary reports
`DEVELOPMENT.GOGET` rather than the release tag, weakening independent binary/version
identification. The project is a young community fork with three releases visible as of the
discovery date. Its security policy supports only the latest release and lists no published
repository advisories. These are explicit maturity and supply-chain risks, not proof of absence of
vulnerabilities.

Sources:

- <https://github.com/libreFS/libreFS/releases/tag/RELEASE.2026-05-04T00-42-47Z>
- <https://github.com/libreFS/libreFS/security>
- <https://raw.githubusercontent.com/libreFS/libreFS/RELEASE.2026-05-04T00-42-47Z/README.md>
- <https://raw.githubusercontent.com/libreFS/libreFS/RELEASE.2026-05-04T00-42-47Z/internal/config/constants.go>

## Future-product findings

- Linux bonding `layer3+4` preserves each flow on one member; multi-flow and multiple-peer evidence
  is required to demonstrate aggregate distribution.
- Debian's in-kernel `mlx4` driver is active and both links are healthy. No OFED requirement was
  found; firmware detail remains unavailable until `ethtool` is installed.
- Future HAProxy security should use CrowdSec's supported SPOA/AppSec integration, not the legacy
  Lua bouncer.
- Mattermost and Forgejo requirements must be bound to exact future image versions before secrets
  are generated. SMTP, OIDC, DNS-provider, certificate, and backup credentials remain
  `OPERATOR_SUPPLIED` or `BLOCKED_BY_DESIGN`, never placeholders.

## Performance constraints

No network benchmark ran because `iperf3` is absent and no approved peer/link-capacity matrix was
identified. Current evidence can establish link state and clean counters only. Aggregate LACP
capacity cannot be claimed. No tuning change is justified; MTU 1496, offloads, rings, channels,
coalescing, IRQ placement, qdiscs, and sysctls remain unchanged.

The later plan must separate raw transport tests from S3 workload tests, identify real peers, and
retain a tuning change only after reproducible before/after improvement without error or latency
regression.

## Discovery blockers and required next evidence

1. Install reviewed read-only diagnostic packages, then capture NVMe SMART/health and NIC firmware,
   offload, queue, ring, coalescing, pause, and detailed error counters.
2. Explain and approve removal of the 512 GB disk's existing GPT; inspect both targets immediately
   before any destructive operation.
3. Resolve exact stable by-id paths privately and bind them to the required operator approval without
   committing them.
4. Perform safe duplicate-address detection for `.65` and `.66` after `arping` is available.
5. Authenticate to OpenBao through the approved hidden-input procedure to verify KV v2, audit state,
   policy behavior, and token lifecycle without exposing values.
6. Identify benchmark peers and off-host backup target. Without an off-host target and tested
   restore, final status cannot exceed `OPERATIONAL_WITHOUT_DURABILITY`.
