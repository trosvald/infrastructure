# c1 libreFS Design and Operations

Date: 2026-08-26
Status: design; service not deployed; storage boundary revised to single 1 TB device (50:50 split);
512 GB excluded/quarantined; Compose restart policy is `no`, owned by `librefs-c1.service`

## Service boundary

libreFS is an internal S3-compatible service on one server and one data disk. It has no storage
redundancy and no high-availability claim. The active-backup bond provides single-link failover;
it does not aggregate throughput or protect object data.

Until an off-host backup and isolated restore pass, the maximum final status is
`OPERATIONAL_WITHOUT_DURABILITY`.

## Immutable image

```text
ghcr.io/librefs/librefs:release.2026-05-04t00-42-47z@sha256:707de0b1fa0ff7c83dd72ad4bcd8225302f06a4ce5278b7356700401e95004ab
platform: linux/amd64
source revision: e194bd779f36fdc08f310d2819d9356f0c1f991b
```

The digest is the tested amd64 manifest, not the multi-platform index. The selected release is the
latest release shown by upstream on 2026-08-26. The image was pulled and exercised locally.

Verified image behavior:

- entrypoint: `/usr/bin/docker-entrypoint.sh`;
- server accepts explicit `--address`, `--console-address`, and native `--certs-dir`;
- default S3 API port is 9000 and console port is 9001; this deployment overrides the TLS API to
  443 and leaves the internal console on 9001;
- persistent path `/data`;
- `MINIO_ROOT_USER_FILE` and `MINIO_ROOT_PASSWORD_FILE` work;
- readiness and liveness endpoints work over TLS on the overridden API port;
- image contains Bash and OpenSSL but no curl or wget;
- image declares neither a healthcheck nor a non-root user;
- UID/GID 1000, read-only root, dropped capabilities, `no-new-privileges`, writable `/data`, and a
  hardened `/tmp` tmpfs passed an offline startup/readiness probe.

Supply-chain limits: the image has OCI source/revision labels and BuildKit SLSA provenance from the
official repository workflow, but no Buildx-exposed SBOM or verified keyless signature was found.
The embedded binary reports `DEVELOPMENT.GOGET` rather than the release tag. libreFS is a young
community fork with a short release history; the current security policy supports only the latest
release. For this mission, the unbacked maturity risk is accepted only for an internal, monitored,
explicitly non-durable service holding no irreplaceable data. The status remains
`OPERATIONAL_WITHOUT_DURABILITY` until an off-host restore passes.

## Compose contract

- project name: `librefs-c1`;
- no host-published port;
- external IPvlan L2 network: `c1_services`;
- static address: `10.25.13.65`;
- platform: `linux/amd64`;
- user: `1000:1000`;
- **Writable-root exception (operator selection).** Doco/Compose v5.5 rejects inline Compose
  `configs` for a read-only root filesystem because the config file cannot be materialized on
  a read-only layer. After review proved this incompatibility, the operator explicitly selected
  a writable-root exception for the libreFS container only. The `read_only: true` declaration is
  omitted; the container root is writable. Every other hardening control below is retained. The
  exception is scope-limited to libreFS only; future c1 applications must keep `read_only: true`
  unless they repeat this reviewed exception.
- Writable-layer custody risk: the libreFS process can write to its own root filesystem; any
  reachable path is a potential write target. Mitigations are the bind source-of-truth on the
  host, the tmpfs-only `/tmp`, the read-only credentials at `/run/secrets/*`, the dropped
  capabilities, and the `restart: no` ownership by systemd. Any persistent write outside
  `/data` is a containment breach and stops the deploy.
- `cap_drop: [ALL]`;
- `security_opt: [no-new-privileges:true]`;
- no privileged mode, devices, Docker socket, host PID, host IPC, or host network;
- writable bind only from `/srv/librefs/data` to `/data`, with long syntax and
  `bind.create_host_path: false`;
- `/tmp` tmpfs: `rw,nosuid,nodev,noexec,mode=1777`;
- `HOME=/tmp`;
- two top-level Compose `configs.content` entries populated from the Doco-resolved
  `LIBREFS_ROOT_USER` and `LIBREFS_ROOT_PASSWORD` deployment variables (config-backed credential
  files, not Docker secrets), mounted at `/run/secrets/librefs_root_user` and
  `/run/secrets/librefs_root_password` with mode `0400`, UID/GID `1000`;
- application environment contains only the two `_FILE` paths; resolved values never appear in
  the container environment;
- restart policy `no` (Docker must never auto-restart libreFS);
- stop grace period 60 seconds;
- containment ceilings: 4 CPUs, 8 GiB memory, 8 GiB memory+swap, 512 PIDs, and nofile 65536;
- JSON logs limited to 10 MiB times three files.
Compose-config UID/GID/mode behavior must be proven on c1 with non-secret canaries before real
credentials. If UID 1000 cannot read the protected config-backed credential files at
`/run/secrets/librefs_root_user` and `/run/secrets/librefs_root_password` without widening host
access, deployment stops; it does not fall back to plaintext environment values, plaintext
compose `secrets.environment` content, or root execution without a new review. The runtime test
always creates a uniquely named isolated bridge network, container, and Docker named data
volume (pre-owned `1000:1000`/`0750`, not a host temp bind) so containerized Linux Docker clients
and CI exercise Compose 5.5 injection without host-path namespace mismatch; the production
`/srv/librefs/data` bind with `create_host_path: false` remains statically asserted and
live-verified separately. It generates per-run CSPRNG canaries, executes the actual
`compose up`, and proves container health, exact file ownership and mode on the
config-backed credential files, UID 1000 reads, and the absence of canary material in inspect,
environment, and logs. The runtime test then cleans up the isolated bridge network, container,
and named volume. The runtime test never skips when `c1_services` exists; the isolated test
network and named volume are always freshly created and torn down.

Restart authority belongs to systemd, not Docker. `librefs-c1.service` is the only process that
starts (and restarts) the existing `librefs-c1` container; it runs `manage-c1-librefs` which
asserts `c1-librefs-storage.service`, `c1-services-network.service` (which transitively requires
the shim unit `c1-services-shim.service` — the systemd and helper filenames are unchanged; the
interface on `bond0.2513` is `c1-svc-shim` ≤16 chars), and `assert-c1-mount` are active before
`docker start` runs. On boot, systemd orders these dependencies so the container is never started
(or restarted) while a partition mount is missing or while the shim is down. An initial Doco
deploy is therefore safe because Doco itself requires the same storage units and the network unit
(which transitively depends on the shim) before its controller can start.

## Healthcheck

The exact image contains Bash but not curl or wget. Use exec-form Compose healthcheck arguments to
run Bash and request readiness through `/dev/tcp`:

```bash
exec 3<>/dev/tcp/127.0.0.1/9000
printf 'GET /minio/health/ready HTTP/1.0\r\nHost: localhost\r\n\r\n' >&3
IFS= read -r status <&3
[[ "$status" == *" 200 "* ]]
```

Initial timing: 30-second interval, 5-second timeout, three retries, and a 60-second start period.
The command and timing remain subject to an exact rendered-Compose and cold-start test. Do not add
curl or a second image merely for healthchecking.

Host-side operational probes check both:

- `/minio/health/live`;
- `/minio/health/ready`.

The selected image returned HTTP 403 for unauthenticated cluster metrics. No metrics exposure or
scrape claim exists until a least-privilege authenticated design is reviewed.

## Secrets and identities

Root credentials come from `kv/docker/c1/librefs` and are administrative only. Applications never
receive them. After bootstrap, routine S3 tests and future consumers use scoped non-root service
accounts with bucket-specific policies.

Doco 0.111.0 includes ordinary resolved KV values in its rendered project hash, but live proof
under PR6 (`3ff1aaf1facc23f6f85e5c95bc80b9e599289207`) showed that an ordinary KV value
change alone does NOT redeploy or rematerialize the container when the Git source is
unchanged: Doco and the existing `librefs-c1` container continue to hold the prior pair.
Credential rotation therefore follows the fail-closed rematerialize helper
(`docker/c1/.host/openbao/rematerialize-librefs-credentials.sh`) to stop the systemd service,
remove only the stateless container (never `/data` or named volumes), invoke an isolated
local-only Git custom target through Doco to recreate with current provider values, normalize
provenance to remote `main`, restart/check the systemd gate, and clean both the temporary
source tree and the cache; the procedure is detailed in `SECRET-CONTRACT.md`. The Doco
mapping, Compose config materialization, container environment, engine metadata, Doco
persistence, and logs must pass that document's canary leakage gate before real values are used.

## Network and TLS

libreFS publishes no host port. It remains on static SERVICES address `10.25.13.65`; the console
is internal and must never become an edge backend. The server uses its verified native
`--certs-dir /certs/current` option. `/srv/librefs/certs/current` is an atomic, root-owned
generation populated only by the c1 `wildcard-reader-c1` token. The generation exposes
`public.crt` mode `0644` and `private.key` mode `0600`, owned by UID/GID `1000`, while retaining
the prior validated generation for rollback.

The shared `*.monosense.io` certificate covers `s3.monosense.io`; it does not expand SRX access.
Only the already reviewed management and SERVICES sources may reach the S3 listener. Every other
routed source and the public internet remain denied; port 9001 is administrative and receives the
same or a narrower boundary.

Before activation, `update-c1-wildcard-certificate` proves the OpenBao record has exactly
`certificate`, `fullchain`, `private_key`, `serial`, and `not_after`; parses the chain/key; proves
the key match and wildcard SAN; requires at least 14 days remaining; then atomically switches the
generation. Failure rolls back the generation and does not delete `/srv/librefs/data`.

The required matrix tests TLS and both ports from one approved management client, the c1 SERVICES
shim, one denied client in `10.25.11.0/24`, one denied client in `10.25.12.0/24`, and one
external/public vantage point. Record source address, certificate identity/expiry, and pass/fail
only. Missing operator-provided vantage points block real backup credentials; they are not skipped.

## Functional acceptance

Use a temporary scoped non-root test identity; do not use root credentials after bootstrap.

1. create a scratch bucket;
2. upload and checksum a small object;
3. upload and checksum a large multipart object;
4. list and download both;
5. delete one object;
6. restart libreFS and prove the remaining object persists with the same checksum;
7. restart Docker and repeat;
8. after explicit approval, reboot c1 and repeat;
9. delete objects and bucket;
10. revoke the test identity.

Record object sizes, checksums, status, and timing only. Never record access or secret keys.

## Capacity and health

Monitor:

- expected filesystem source/type/RW state and `/data` mount identity;
- filesystem free bytes/inodes and growth rate;
- XFS errors;
- NVMe critical warnings, available spare, media errors, wear, unsafe-shutdown trend, temperature,
  and controller resets;
- container health/restarts/OOM/PID pressure;
- S3 error rate and readiness;
- network retransmits/errors/drops and per-bond-member bytes.

Set warning/critical capacity thresholds after the formatted capacity and workload growth baseline
are measured. Keep explicit free-space headroom; do not promise a number before evidence.

## Backup and restore

The 1 TB local application partition (`/srv/applications`) shares a device and host with
`/srv/librefs` and is therefore not a backup for `/srv/librefs`. A valid backup target is off-host
and in a separate failure domain.

Before status can become durable:

1. approve the off-host target, transport, retention, encryption, and failure-domain assumptions;
2. pin and verify the backup client image/binary;
3. create a separate scoped backup service account and store it in
   `kv/docker/c1/librefs-backup`;
4. mirror/version objects without root credentials;
5. restore representative small, multipart, and metadata-bearing objects into an isolated bucket or
   test instance;
6. compare checksums and application reads;
7. document measured RPO/RTO and schedule;
8. test credential rotation and failed/partial backup alerts.

Until every step passes, state `OPERATIONAL_WITHOUT_DURABILITY` and name the missing target.

## Upgrade and rollback

For an upgrade:

1. review the new release, amd64 digest, source revision, security notes, provenance/signature, and
   SBOM status;
2. test file secrets, UID 1000, read-only root, healthcheck, CRUD, multipart, and restored data
   offline;
3. complete and verify an off-host backup;
4. quiesce writes;
5. change only the immutable tag/digest;
6. deploy and run functional checks;
7. resume writes only after acceptance.

Roll back the image digest without changing `/data` only when data-format compatibility is proven.
Otherwise restore the backup to an isolated location. Never reformat or delete `/srv/librefs` to
solve an application failure.

## Incident rollback

- unhealthy new container: stop Doco reconciliation for the project, restore the prior reviewed
  digest, retain `/data`, and inspect sanitized logs;
- missing/wrong mount: keep libreFS stopped, restore the mount and assertions, never create a
  fallback directory;
- suspected credential leak: stop new access, rotate the affected OpenBao KV value and scoped
  identities, explicitly redeploy, verify old rejection, then inspect audit evidence;
- network drift: stop the project, preserve attached endpoint evidence, and follow the reviewed
  explicit network outage/recreate path; never auto-delete an attached network.
