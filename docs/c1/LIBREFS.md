# c1 libreFS Design and Operations

Date: 2026-08-26
Status: design; service not deployed; storage boundary revised to single 1 TB device (50:50 split);
512 GB excluded/quarantined; Compose restart policy is `no`, owned by `librefs-c1.service`

## Service boundary

libreFS is an internal S3-compatible service on one server and one data disk. It has no storage
redundancy and no high-availability claim. LACP improves link capacity and single-member survival;
it does not protect object data.

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
- command: `server /data --console-address :9001`;
- S3 API 9000 and console 9001;
- persistent path `/data`;
- `MINIO_ROOT_USER_FILE` and `MINIO_ROOT_PASSWORD_FILE` work;
- readiness and liveness endpoints work on port 9000;
- image contains Bash but no curl or wget;
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
- `read_only: true`;
- `cap_drop: [ALL]`;
- `security_opt: [no-new-privileges:true]`;
- no privileged mode, devices, Docker socket, host PID, host IPC, or host network;
- writable bind only from `/srv/librefs/data` to `/data`, with long syntax and
  `bind.create_host_path: false`;
- `/tmp` tmpfs: `rw,nosuid,nodev,noexec,mode=1777`;
- `HOME=/tmp`;
- two Compose secrets sourced from Doco-resolved deployment variables;
- application environment contains only the two `_FILE` paths;
- restart policy `no` (Docker must never auto-restart libreFS);
- stop grace period 60 seconds;
- containment ceilings: 4 CPUs, 8 GiB memory, 8 GiB memory+swap, 512 PIDs, and nofile 65536;
- JSON logs limited to 10 MiB times three files.

Restart authority belongs to systemd, not Docker. `librefs-c1.service` is the only process that
starts (and restarts) the existing `librefs-c1` container; it runs `manage-c1-librefs` which
asserts `c1-librefs-storage.service`, `c1-services-network.service` (which transitively requires
the shim unit `c1-services-shim.service` — the systemd and helper filenames are unchanged; the
interface on `bond0.2513` is `c1-svc-shim` ≤16 chars), and `assert-c1-mount` are active before
`docker start` runs. On boot, systemd orders these dependencies so the container is never started
(or restarted) while a partition mount is missing or while the shim is down. An initial Doco
deploy is therefore safe because Doco itself requires the same storage units and the network unit
(which transitively depends on the shim) before its controller can start.

The storage prerequisite creates `/srv/librefs/data` as UID/GID 1000, mode `0750`, only while the
approved 1 TB partition 1 is mounted at `/srv/librefs`. The directory does not exist beneath an
unmounted `/srv/librefs`. Docker must fail rather than create it on the OS disk.

Compose-secret UID/GID/mode behavior must be proven on c1 with non-secret canaries before real
credentials. If UID 1000 cannot read a protected secret without widening host access, deployment
stops; it does not fall back to plaintext environment values or root execution without a new review.

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

Doco 0.111.0 includes ordinary resolved KV values in its rendered project hash, so a changed value
can trigger service recreation on the next poll. Credential rotation follows the stop-Doco,
CAS-write, controlled-start/recreate sequence in `SECRET-CONTRACT.md`. The Doco mapping, Compose
secret materialization, container environment, engine metadata, Doco persistence, and logs must
pass that document's canary leakage gate before real values are used.

## Network and TLS

This mission exposes no host port and creates no public DNS, certificate, DNAT, or SRX policy.
However, IPvlan on a routed SERVICES VLAN is not private by definition.

The initial cleartext boundary permits only clients sourced from management `10.25.10.0/24` and
SERVICES `10.25.13.0/24`. Every other routed source and the public internet are denied; port 9001 is
administrative and receives the same or a narrower boundary.

The required matrix tests both ports from: one approved management client; the c1 SERVICES shim;
one denied client in `10.25.11.0/24`; one denied client in `10.25.12.0/24`; and one external/public
vantage point. Record the actual source address and pass/fail only. This mission authorizes no SSH
or execution on those denied clients, so missing operator-provided vantage points are an explicit
blocker, not a skipped test. If every denied case cannot be proven, or any unapproved source
succeeds, use only non-secret canaries and disposable data. Real credentials/data then require
tested TLS or an enforceable reviewed control that does not depend on an unavailable SRX change.

Any future untrusted or public use requires reviewed TLS, certificate rotation, client trust, and
firewall/SRX policy. The console remains internal and must never be a public frontend.

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
