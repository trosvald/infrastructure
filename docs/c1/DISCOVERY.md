# c1 Discovery

Date: 2026-08-26  
Repository base: `50290c242a9ded1890124c633614c6780df8ca90`

This document contains sanitized findings only. It excludes MAC addresses, machine UUIDs, full disk
serials, WWNs, filesystem UUIDs, stable by-id paths, credentials, tokens, and raw command dumps.
Exact destructive device identities remain an operator checkpoint and are not repository data.
Correction: c1 `bond0` is active-backup and has never been LACP. Every later 802.3ad, aggregator,
hash-policy, or aggregate-capacity statement in this historical capture is invalid and must not be
used for operations or design.

This is a historical discovery/evidence capture. Its predecessor mission results do not claim
container-node Ansible adoption or convergence.

## Status

Discovery supports repository design, and the corrected storage retry has succeeded:

## Live Doco reconciliation (post-merge PR6, commit 3ff1aaf1facc23f6f85e5c95bc80b9e599289207)

PR6 is merged at `3ff1aaf1facc23f6f85e5c95bc80b9e599289207`. Doco post-merge reconciled libreFS
successfully: the `librefs-c1` container is healthy at `10.25.13.65` on the pinned
`ghcr.io/librefs/librefs:release.2026-05-04t00-42-47z@sha256:707de0b1fa0ff7c83dd72ad4bcd8225302f06a4ce5278b7356700401e95004ab`
image (linux/amd64). No host ports are published, no Docker socket is mounted, the container
environment exposes only the `_FILE` paths, and the credential runtime files at
`/run/secrets/librefs_root_user` and `/run/secrets/librefs_root_password` are owned by
UID/GID `1000` with mode `0400`. The runtime file contents match the exact OpenBao v1 values
at `kv/docker/c1/librefs` without modification. The exact-value leakage scan passed across
container inspect, container environment, container logs, Doco and service journals, the Doco
data volume and working trees, Docker container metadata, and containerd metadata. The exported
runtime contents were observed only inside the two approved `/run/secrets` files; no other
location contained the credential values. The writable-layer diff against the static
`/srv/librefs/data` bind and the read-only mounts showed writes only on the `/run/secrets`
paths (config file materialization by Compose) and on the `/data` bind (libreFS data
operations); no writes were observed elsewhere. The rotation leakage gate is closed: OpenBao
KV v2 `kv/docker/c1/librefs` was rotated twice with CAS ending at version 3; each new pair
was rematerialized through Doco's OpenBao provider; the second rotation proved the prior pair
absent from runtime files, inspect/env/logs, Doco and libreFS journals, Doco volume/worktrees,
Docker container metadata, containerd, and the export; the current pair existed only in the two
approved `/run/secrets` files. Short-lived admin token revoked; local rotation/comparison
material removed. The checker false-negative discovered during verification: the Doco single-run
response wraps the run status under a top-level `.content` field; the source and test fix is
in progress. Mission live gates complete: user approved controlled c1 reboot; outage and
SSH recovery observed. Post-reboot verification passed (both XFS noatime mounts and assertion
units, Docker, c1 SERVICES network/shim, exact management default route, bond/VLAN/LACP two 10
Gb members with zero link-failure counts, Doco/OpenBao token/controller canaries, healthy
pinned `librefs-c1` at `.65` with no host ports and credential files UID/GID 1000 mode 0400;
exact-value leakage and writable-root containment scans passed again after reboot). Scoped S3
ready/upload/stat/download/checksum/delete/denial passed again after reboot with 512 MiB
observed at 542,280,200 B/s upload and 2,014,577,014 B/s download (post-reboot confirmation,
not a replacement of the pre-reboot baseline of 567,957,345 B/s upload and 1,863,741,635 B/s
download). User explicitly skipped optional bond-member failover; record intentionally not
exercised, not a blocker. PR8 merged at `599fff0e01301d77f5a2e204bac5df9a519f1823`,
and the then-installed rematerialization helper is preserved as historical live evidence. Its
repository source now lives at
`ansible/container-nodes/roles/runtime_assets/files/rematerialize-c1-librefs-credentials`.
Final status was `OPERATIONAL_WITHOUT_DURABILITY` solely because no off-host libreFS backup
target/restore existed on c1; this record does not claim later Ansible adoption or convergence.
- the 512 GB NVMe is quarantined/unmounted/excluded (firmware VC400618 has no verified official
  updater);
- the 1 TB NVMe is split 50:50 between `/srv/librefs` (GPT PARTLABEL `c1_librefs`, XFS label
  `c1_librefs`) and `/srv/applications` (GPT PARTLABEL `c1_applications`, XFS label `c1_apps`),
  both mounted `defaults,noatime` and verified by UUID, XFS, RW, and directory probes;
- the host shim `c1-svc-shim` (interface on `bond0.2513`; systemd unit `c1-services-shim.service`)
  and the network unit `c1-services-network.service` are both active; the route
  `10.25.13.64/27` is verified with `dev c1-svc-shim` and scope `link`;
- Docker and containerd `SOURCE` equals `/` source;
- OpenBao checkpoint completed: policy `doco-c1` installed; KV v2 `kv/docker/c1/librefs` v1
  provisioned with the exact `root_user`/`root_password` keys; orphan periodic 24h token issued;
  policy allows only `kv/data/docker/c1/librefs` (read), `auth/token/lookup-self`, and
  `auth/token/renew-self`; all unrelated capabilities (`kv/metadata/...`, list, write, patch,
  delete, undelete, destroy, metadata, c0/Junos/global/identity/policy/auth-method/
  token-creation/system/PKI paths, sudo, future c1 services) are denied; audit file device
  enabled; multi-recipient Raft snapshot captured to the workstation and encrypted under the
  offline-recovery multi-recipient age boundary; structural verification passed
  (`meta.json`, `state.bin`, `SHA256SUMS`, `SHA256SUMS.sealed`); internal SHA256SUMS verified
  (no snapshot-inspect available on the installed bao, so structural and internal checksums are
  the reviewed evidence). The first capabilities-self call returned 403 because the no-default
  Doco policy cannot call `capabilities-self`; recovery used a short-lived admin token via
  `sys/capabilities-accessor` and did not broaden the Doco policy. The short-lived admin token
  was revoked and removed. No secrets, recipients, hashes, or token values are recorded here.
- the credential rotation leakage gate is closed: OpenBao KV v2 `kv/docker/c1/librefs` was
  rotated twice with CAS ending at version 3; each new pair was rematerialized through Doco's
  OpenBao provider. The exact-value scan passed for the first rotated pair; after the second
  rotation it proved the prior pair absent from the current runtime files, container inspect/
  environment/logs, Doco and libreFS journals, the Doco data volume and working trees, Docker
  container metadata, containerd, and the export. The current pair existed only in the two
  approved `/run/secrets` files. The short-lived admin token was revoked; local rotation/
  comparison material was removed. The migrated resident helper at
  `ansible/container-nodes/roles/runtime_assets/files/rematerialize-c1-librefs-credentials`
  preserves the fail-closed rematerialization behavior (stop the project through the lifecycle
  gate, remove only the stateless container, let Doco recreate with current provider values,
  normalize provenance to remote `main`, verify, and clean temporary state). A failed transaction
  can cause service unavailability but never data loss and is compensated or left stopped.
  Operators reach this behavior only through `just ansible container-nodes rotate-secrets`, not by
  invoking the installed helper.

- the S3 and performance matrices are complete: a scoped non-root S3 probe used the pinned
  `quay.io/minio/mc@sha256:a7fe349ef4bd8521fb8497f55c6042871b2ae640607cf99d9bede5e9bdf11727`
  on `c1_services`, created a temporary bucket/user/policy limited to `GetBucketLocation`/
  `ListBucket`/`Get/Put/DeleteObject` for that bucket, passed ready/upload/stat/download/
  checksum/delete, and proved unauthorized bucket creation denied; synthetic artifacts cleaned.
  512 MiB same-host Docker-network S3 baseline: upload 567,957,345 B/s, download
  1,863,741,635 B/s (local bridge + storage + application evidence, not external 10 Gb/s
  proof). Workstation-to-c1 SERVICES TCP baseline over the actual routed path: sender
  113,948,113 bit/s, receiver 112,622,607 bit/s for 256 MiB (path and workstation limited,
  not LACP capacity);
- the off-host libreFS backup check confirmed that Doco manages only `doco-cd-c1` and
  `librefs-c1`; no libreFS backup service, project, or target exists on c1 (only the Debian
  `dpkg-db-backup` units). No restore was possible. The historical final status was
  `OPERATIONAL_WITHOUT_DURABILITY` solely because no off-host libreFS backup target/restore
  existed on c1; no durability claim. The predecessor mission's live gates completed, while the
  later container-node adoption gate remains independent.

## Doco credential-materialization correction

Live Doco 0.111.0 rejected the top-level Compose `secrets.environment` source for the libreFS
application because `file` is the only supported source for `secrets.environment`. The first
Doco deploy therefore failed before container creation; no secret values were ever rendered,
no container was created, and no engine artifact contains credential material. The corrected
pattern follows the official Doco external-secrets example using top-level Compose
`configs.content` populated from the Doco-resolved `LIBREFS_ROOT_USER` and `LIBREFS_ROOT_PASSWORD`
variables. The resulting config files are mounted at `/run/secrets/librefs_root_user` and
`/run/secrets/librefs_root_password` with mode `0400`, UID/GID `1000`; the container environment
still exposes only the `MINIO_ROOT_USER_FILE` / `MINIO_ROOT_PASSWORD_FILE` paths and never the
raw values. These are config-backed credential files, not Docker secrets.

## Writable-root exception for libreFS (operator selection)

Doco/Compose v5.5 rejects inline Compose `configs` for a read-only root filesystem: config mounts
require a writable layer to materialize the file. After review proved this incompatibility, the
operator explicitly selected a writable-root exception for the libreFS container only. The
exception is documented and the writable-layer custody risk is owned:

- The `read_only: true` declaration is omitted for `librefs-c1`; the container root is writable.
- Every other hardening control is retained: UID/GID `1000`, `cap_drop: [ALL]`,
  `security_opt: [no-new-privileges:true]`, no privileged mode, no devices, no Docker socket, no
  host PID/IPC/network, the explicit `/srv/librefs/data:/data` bind with
  `bind.create_host_path: false`, `/tmp` tmpfs `rw,nosuid,nodev,noexec,mode=1777`, the
  `/run/secrets/librefs_root_{user,password}` config mounts at mode `0400` UID/GID `1000`,
  resource/PID/nofile ceilings, JSON log limits, `restart: no`, and no host ports.
- Writable-layer custody risk: the libreFS container can write to its own root filesystem;
  any path the process can reach is a potential write target. Mitigations are the bind
  source-of-truth on the host, the tmpfs-only `/tmp`, the read-only credentials at
  `/run/secrets/*`, the dropped capabilities, and the `restart: no` ownership by systemd.
  Any persistent write outside `/data` is a containment breach and stops the deploy.
- The exception is scope-limited to libreFS only; future c1 applications must keep `read_only:
  true` unless they repeat this reviewed exception.

Resolved values exist only in Doco's in-memory rendered project and may be materialized in
protected engine or Doco artifacts during the deploy window. A full exact-value leakage scan
covering container environment, rendered Compose output, project labels, runtime secret/
config metadata, Doco logs/working trees/data volume/persisted deployment artifacts, Docker and
containerd metadata, journald, application logs, temporary directories, and backup inputs was a
blocking live canary at PR6 design time. PR6 (`3ff1aaf1facc23f6f85e5c95bc80b9e599289207`) is
merged; the scan passed on the merged artifact. The credential rotation leakage gate is closed:
OpenBao KV v2 `kv/docker/c1/librefs` was rotated twice with CAS ending at version 3, and each
rotation proved the prior pair absent from every location while the current pair existed only
in the two approved `/run/secrets` files.
No host, network, storage, package, or service mutation occurred outside the reviewed corrected
retry on the 1 TB NVMe and the reviewed OpenBao checkpoint.

## Repository baseline

The clean local `main` and `origin/main` both resolved to the base above. Work continues on
`feat/c1-doco-librefs`. The locked toolchain was already installed. The pre-change Gitleaks scan
passed.

`just docker validate-c0` was already failing with exit 1 after its OpenBao certificate tests
passed; the command emitted no failing assertion. This is a pre-existing baseline failure, not a c1
regression. The first invocation also exposed that non-interactive shells need the locked mise bin
paths on `PATH`; the rerun used those paths and reached the same silent exit 1.

## Existing repository conventions

c0 established the application/controller boundary later adopted by the container-node project:

- controller application source: `docker/c0/.doco-cd/`;
- host state and controller installation: `ansible/container-nodes/roles/`;
- Doco-managed applications: direct children of `docker/c0/`;
- controller source filename: `docker-compose.app.yaml`, intentionally not a recognized Compose
  discovery filename;
- application auto-discovery: depth 1, delete false, force-recreate false, reconciliation disabled;
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
| libreFS and applications target (1 TB, 50:50 split) | PNY CS1031 1TB SSD, 931.5 GiB; identity suffix `0E10` | No recognized signature; SMART passed, zero media errors, 94 unsafe shutdowns, 13% used, 100% spare | Approved device; pending exact single-device approval and raw-data disposition |
| quarantined 512 GB | TEAM TM8FP6512G, 476.9 GiB; identity suffix `0351` | No partitions; valid primary/backup GPT and PMBR; 941 media/data-integrity errors, 13 unsafe shutdowns, 3% used, 91% spare; firmware VC400618 has no verified official updater | **Quarantined/unmounted/excluded: never an argument, never a fallback, never a backup** |

The host has no containers, Compose projects, or Docker volumes. It has three untagged images and
about 1.0 GB of reclaimable image data. No valuable running Docker state was identified, but image
inactivity alone is not proof of disposability.

Docker uses the containerd image store. `/var/lib/docker` is about 260 KiB and `/var/lib/containerd`
is about 986 MiB. Under the revised storage boundary these engine roots stay on the OS disk; no
Docker `data-root` change, no containerd root override, and no engine persistent-root migration is
planned. The 1 TB NVMe hosts only the `/srv/librefs` and `/srv/applications` partitions for
container bind sources, not engine roots.

A follow-up read-only engine query found `/etc/containerd/config.toml` only disables CRI; there are
no active containerd drop-ins, Docker/containerd systemd drop-ins, mount requirements, or
`/etc/docker/daemon.json`. Effective containerd root/state are `/var/lib/containerd` and
`/run/containerd`, the snapshotter is overlayfs, and Docker connects to
`/run/containerd/containerd.sock`. This effective state is retained as-is; no engine configuration is
installed by this mission. Docker and containerd remain usable from the OS disk while `/srv/librefs`
or `/srv/applications` is absent; affected bind-mounted applications fail closed.

No disk benchmark ran. Diagnostics and benchmark tools were installed after repository review. The
512 GB media-error finding and the storage-boundary revision ended the need to benchmark that
device; benchmarks target the 1 TB tier or approved off-host peers only.

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
- ordinary KV values are resolved before the rendered project hash is compared, but live proof
  under PR6 (`3ff1aaf1facc23f6f85e5c95bc80b9e599289207`) showed that an ordinary KV value
  change alone does not redeploy or rematerialize the container when the Git source is unchanged.
  The `rotate-secrets` Ansible action therefore uses the resident fail-closed rematerializer to
  stop the exact project, remove only the stateless container (never `/data` or named volumes),
  let Doco recreate it with current provider values, normalize provenance to remote `main`,
  verify the consumer, clean temporary state, and revoke the old accessor only after success;
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

1. Resolve exact stable by-id paths privately and bind the single 1 TB identity to the exact six-line
   `APPROVE C1 STORAGE` approval without committing it. The 512 GB device is quarantined and never an
   argument; an independent vendor-backed diagnosis explaining the 941 media/data-integrity errors
   remains a separate optional evidence path, not a blocker for the 1 TB mission.
2. Rerun NVMe health, stable identity, signatures, and the complete byte-bound single-device plan
   against the 1 TB target. Do not reuse any prior plan digest.
3. Perform safe duplicate-address detection for `.65` and `.66` after `arping` is available.
7. Identify benchmark peers and off-host backup target. Without an off-host target and tested
   restore, final status cannot exceed `OPERATIONAL_WITHOUT_DURABILITY`.
