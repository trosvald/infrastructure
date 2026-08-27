# c1 Operations

Date: 2026-08-26
Status: storage applied successfully on the corrected retry. Live Doco reconciliation:
PR6 merged at `3ff1aaf1facc23f6f85e5c95bc80b9e599289207`; Doco post-merge reconciled
`librefs-c1` successfully — container healthy at `10.25.13.65` on the pinned
`ghcr.io/librefs/librefs:release.2026-05-04t00-42-47z@sha256:707de0b1fa0ff7c83dd72ad4bcd8225302f06a4ce5278b7356700401e95004ab`
(linux/amd64). No host ports, no Docker socket; container env exposes only `_FILE` paths;
the credential runtime files at `/run/secrets/librefs_root_user` and
`/run/secrets/librefs_root_password` are UID/GID `1000` mode `0400` and match the exact OpenBao
v1 values. Exact-value leakage scan passed across container inspect, environment, logs, Doco
and service journals, Doco data volume and working trees, Docker container metadata, and
containerd metadata; exported runtime contents were observed only in the two approved
`/run/secrets` files. Writable-layer diff showed writes only on `/run/secrets` paths and on
`/data`. Rotation scan remains pending. A checker false-negative was discovered: the Doco
single-run response wraps run status under a top-level `.content` field; the source and test
fix is in progress. Mission is not marked complete; remaining gates are token rotation scan,
push follow-up, deploy verification on the next change, reboot, and off-host libreFS backup/
restore.

This runbook is subordinate to `DESIGN-AND-PLAN.md`, `REVIEW.md`, `SECRET-CONTRACT.md`, and
`LIBREFS.md`. Repository validation is safe, offline, and pinned: `docker/c1` activates the
exact Docker Compose 5.5.0 plugin locked in `.mise/mise.lock`. Doco 0.111.0 embeds Compose
v5.5.0, so the runtime credential canary executes the same Compose injection semantics in
local and CI as in live Doco:
```sh
just docker validate-c1
```

Do not continue past any failed checkpoint. Storage, network, OpenBao, push, merge, and reboot each
supplies the single 1 TB identity only as a protected shell variable on c1.

## Read-only host checkpoints

Capture output into a root-only operator record. Verify management, routing, DNS, VLAN, and LACP
state before and after every network action:

```sh
sudo ip -brief address show eno1 bond0 bond0.2512 bond0.2513
sudo ip route show default
sudo ip route get 10.25.13.34
sudo resolvectl status eno1
sudo cat /proc/net/bonding/bond0
sudo ip -details link show bond0 bond0.2513
sudo docker network inspect c1_services
```

An absent `c1_services` network is expected before installation. Verify `.65` and `.66` with the
separately approved duplicate-address procedure after the required diagnostic package is installed.
An inconclusive result stops the operation.

Set the exact stable 1 TB by-id path without printing it, then run only read-only storage modes:

```sh
read -r -s -p '1 TB stable by-id path: ' C1_1TB_BY_ID; printf '\n'
export C1_1TB_BY_ID
sudo --preserve-env=C1_1TB_BY_ID \
  docker/c1/.host/storage/ensure.sh check "$C1_1TB_BY_ID"
sudo install -d -o root -g root -m 0700 /root/c1-storage-review
sudo --preserve-env=C1_1TB_BY_ID sh -c \
  'docker/c1/.host/storage/ensure.sh plan "$C1_1TB_BY_ID" > /root/c1-storage-review/plan'
sudo chmod 0600 /root/c1-storage-review/plan
```

Review every line of the protected plan out of band. It binds the 1 TB by-id and resolved device,
model, byte size, signatures, exact 50:50 partition split, destructive actions, mount roles,
OS-disk exclusion, and 512 GB exclusion. The 512 GB device is never an argument; an appearance of
`512GB=` or `512GB_SIGNATURES=` in the plan or approval is an immediate stop. Changed evidence
invalidates the plan.

## Storage apply checkpoint

Only after the exact storage approval is granted, extract the reviewed fields without displaying
them and feed the mandatory six-line approval through protected stdin:

```sh
C1_PLAN_SHA256="$(sudo sed -n 's/^PLAN_SHA256=//p' /root/c1-storage-review/plan)"
C1_1TB_SIGNATURES="$(sudo sed -n 's/^1TB_SIGNATURES=//p' /root/c1-storage-review/plan)"
C1_PARTITION_LAYOUT="$(sudo sed -n 's/^PARTITION_LAYOUT=//p' /root/c1-storage-review/plan)"
export C1_PLAN_SHA256 C1_1TB_SIGNATURES C1_PARTITION_LAYOUT
{
  printf '%s\n' 'APPROVE C1 STORAGE'
  printf '1TB=%s\n' "$C1_1TB_BY_ID"
  printf 'PLAN_SHA256=%s\n' "$C1_PLAN_SHA256"
  printf '1TB_SIGNATURES=%s\n' "$C1_1TB_SIGNATURES"
  printf 'PARTITION_LAYOUT=%s\n' "$C1_PARTITION_LAYOUT"
  printf '%s' 'ACKNOWLEDGE_WIPE=ERASE APPROVED 1TB TARGET ONLY'
} | sudo --preserve-env=C1_1TB_BY_ID \
  docker/c1/.host/storage/ensure.sh apply "$C1_1TB_BY_ID" "$C1_PLAN_SHA256"
unset C1_PLAN_SHA256 C1_1TB_SIGNATURES C1_PARTITION_LAYOUT C1_1TB_BY_ID
```

Apply immediately recomputes the plan digest before the first write and atomically persists the
approved plan on the single 1 TB device. It creates one GPT with two aligned partitions and
provisions each partition independently. Each filesystem records pending UUID state immediately
after formatting, mounts by partition, and passes UUID/XFS/RW assertions before a hard fstab entry
is committed. A byte-identical retry resumes pending state or verifies complete state without
reformatting it. Run the non-destructive installed-state check:

```sh
sudo docker/c1/.host/storage/ensure.sh verify
sudo docker/c1/.host/storage/install-storage-assets.sh apply
sudo docker/c1/.host/storage/install-storage-assets.sh check
```

`install-storage-assets.sh apply` installs the reviewed `c1-librefs-storage.service`,
`c1-applications-storage.service`, `librefs-c1.service`, and `manage-c1-librefs` (plus the
`assert-c1-mount` helper), and reloads systemd. It `enable`s—but never `start`s—the storage units,
the `librefs-c1.service`, and `manage-c1-librefs`. It installs no Docker daemon config, no
`/etc/docker/daemon.json`, and no containerd root override. It refuses to overwrite any differing
unit, drop-in, or helper. `install-storage-assets.sh check` re-inspects the installed
units/helper and verifies they match the reviewed assets without starting anything.

Formatting cannot recover unknown prior content; a single-device signature/GPT snapshot restores
metadata only.

No engine configuration is installed by this mission. Docker and containerd retain their existing
OS-disk roots (`/var/lib/docker`, `/var/lib/containerd`, `/run/containerd`) untouched. `doco-c1`
Compose restart policy is disabled; `doco-cd-c1.service` owns the controller's foreground Compose
process and `librefs-c1.service` (with `manage-c1-librefs`) owns libreFS. Both `doco-cd-c1.service`
and `librefs-c1.service` require `c1-librefs-storage.service`, `c1-applications-storage.service`,
`assert-c1-mount`, and the network unit `c1-services-network.service` (which transitively
Requires/After Docker and the shim unit `c1-services-shim.service` whose interface is
`c1-svc-shim`; the systemd and helper filenames remain unchanged) to be active before they
start; `doco-cd-c1` additionally runs the token TTL gate. Docker itself is independent
of those mounts and remains usable while either partition is absent. Affected bind-mounted
applications (libreFS, future HAProxy/Mattermost/Forgejo/PostgreSQL) fail closed if their
partition mount is wrong or absent; keep those applications stopped and repair the mount rather
than creating fallback directories.

Use a separately reviewed export/restore or delta migration only if durable state must move; never
prune or delete an existing engine root.

## Network and shim checkpoint

Default helper invocation is read-only:

```sh
sudo docker/c1/.host/networks/services/ensure.sh
sudo docker/c1/.host/networks/services/ensure-shim.sh
```

After conclusive collision checks and explicit network approval, install both helpers, the
additive persistent shim, and the network unit. The shim unit is enabled and started before the
network unit so the network unit's transitive dependency is satisfied:

```sh
sudo install -o root -g root -m 0755 docker/c1/.host/networks/services/ensure.sh /usr/local/sbin/ensure-c1-services-network
sudo install -o root -g root -m 0755 docker/c1/.host/networks/services/ensure-shim.sh /usr/local/sbin/ensure-c1-services-shim
sudo install -o root -g root -m 0644 docker/c1/.host/networks/services/c1-services-shim.service /etc/systemd/system/c1-services-shim.service
sudo install -o root -g root -m 0644 docker/c1/.host/networks/services/c1-services-network.service /etc/systemd/system/c1-services-network.service
sudo systemctl daemon-reload
sudo systemctl enable --now c1-services-shim.service
sudo systemctl enable --now c1-services-network.service
# Link name is `c1-svc-shim` (11 chars, fits Linux IFNAMSIZ = 16). The prior 16-char
# `c1-services-shim` interface name was rejected pre-create with no link ever created. The systemd
# unit and helper filenames remain `c1-services-shim.service` and `ensure-c1-services-shim`;
# the network helper is `/usr/local/sbin/ensure-c1-services-network` and its unit is
# `c1-services-network.service`. `c1-services-network.service` Requires/After Docker and the
# shim unit and runs the exact `ensure.sh apply` on boot. `librefs-c1.service` and
# `doco-cd-c1.service` require `c1-services-network.service` (which transitively requires the
# shim); neither requires the shim directly anymore.
sudo ip link show c1-svc-shim
sudo ip -details link show c1-svc-shim
sudo docker network inspect c1_services
```

Repeat the full read-only host checkpoint. `.34` must still route through the management default;
only `10.25.13.64/27` may use the shim. On drift, stop. Do not delete an attached network. An
approved empty-network rollback is dependency-safe: stop and disable the c1 consumers first, then
the network unit, then verify the endpoint guard while the shim still exists, and only after the
guard is zero remove the network, the shim unit, and the shim link in that strict order. The shim
is never deleted before the endpoint guard.

```sh
# 1. Stop and disable c1 consumers first
sudo systemctl disable --now doco-cd-c1.service
sudo systemctl disable --now librefs-c1.service
# 2. Stop and disable the network unit (Requires/After Docker + shim)
sudo systemctl disable --now c1-services-network.service
# 3. Endpoint guard — shim must still exist; abort if any endpoint remains
endpoint_count="$(sudo docker network inspect -f '{{len .Containers}}' c1_services)"
test "$endpoint_count" -eq 0
# 4. Only when zero: remove the Docker network
sudo docker network rm c1_services
# 5. Then stop/disable the shim unit and delete the shim link
sudo systemctl disable --now c1-services-shim.service
sudo ip link delete c1-svc-shim
```

The removal sequence is forbidden unless every step ran in order and the endpoint count is
exactly zero before the shim unit is stopped. The shim link is never deleted before the
endpoint guard passes, and the shim unit is never stopped before the network is removed. Each
step requires its own outage/removal approval; an aborted guard leaves the network, the shim
unit, and the shim link in place for re-inspection.

## OpenBao token lifecycle

OpenBao checkpoint completed: policy `doco-c1` installed; KV v2 `kv/docker/c1/librefs` v1
provisioned with the exact `root_user`/`root_password` keys; orphan periodic 24h token issued
with self-lookup and self-renew only; policy allows only `kv/data/docker/c1/librefs` (read),
`auth/token/lookup-self`, and `auth/token/renew-self`; all unrelated capabilities are denied;
audit file device enabled. Multi-recipient Raft snapshot captured to the workstation and
encrypted under the offline-recovery age boundary; structural verification passed
(`meta.json`, `state.bin`, `SHA256SUMS`, `SHA256SUMS.sealed`); internal SHA256SUMS verified
(no snapshot-inspect on the installed bao; structural and internal checksums are the reviewed
evidence). The first capabilities-self call returned 403 because the no-default Doco policy
cannot call `capabilities-self`; recovery used a short-lived admin token via
`sys/capabilities-accessor` and did not broaden the Doco policy. The short-lived admin token
was revoked and removed. No secrets, recipients, hashes, or token values are recorded here.
Off-host libreFS backup/restore remains separate and unproven.

OpenBao mutation is a separate administrator checkpoint. The only application record is logical KV
path `kv/docker/c1/librefs`, with keys `root_user` and `root_password`; values enter through the
approved hidden-input flow and are never printed. Install the exact `doco-c1.hcl` policy only after
TLS, KV v2, audit, token-limit, allowed/denied capability, encrypted Raft snapshot, and restore
inspection gates pass.

Install the root-only controller, renewal, and verification assets:

```sh
sudo install -d -o root -g root -m 0700 /opt/doco-cd/secrets
sudo install -d -o root -g root -m 0755 /opt/doco-cd
sudo install -o root -g root -m 0644 docker/c1/.doco-cd/docker-compose.app.yaml /opt/doco-cd/docker-compose.app.yaml
sudo install -o root -g root -m 0644 docker/c1/.doco-cd/poll-config.yml /opt/doco-cd/poll-config.yml
sudo install -o root -g root -m 0755 docker/c1/.host/openbao/renew-token.sh /usr/local/sbin/renew-c1-openbao-token
sudo install -o root -g root -m 0755 docker/c1/.host/openbao/check-token-ttl.sh /usr/local/sbin/check-c1-openbao-token
sudo install -o root -g root -m 0755 docker/c1/.host/openbao/check-doco-controller.sh /usr/local/sbin/check-c1-doco-controller
sudo install -o root -g root -m 0755 docker/c1/.host/openbao/install-token.sh /usr/local/sbin/install-c1-openbao-token
sudo install -o root -g root -m 0755 docker/c1/.host/openbao/install-api-secret.sh /usr/local/sbin/install-c1-doco-api-secret
sudo install -o root -g root -m 0644 docker/c1/.host/openbao/doco-c1-openbao-renew.service /etc/systemd/system/doco-c1-openbao-renew.service
sudo install -o root -g root -m 0644 docker/c1/.host/openbao/doco-c1-openbao-renew.timer /etc/systemd/system/doco-c1-openbao-renew.timer
sudo install -o root -g root -m 0644 docker/c1/.host/openbao/doco-cd-c1.service /etc/systemd/system/doco-cd-c1.service
```

Generate the initial API secret directly into the protected installer. The value is never printed or
placed in argv, history, or an environment:

```sh
python3 -c 'import secrets,sys; sys.stdout.write(secrets.token_urlsafe(48))' \
  | sudo /usr/local/sbin/install-c1-doco-api-secret
```

Feed the initial least-privilege OpenBao token directly on protected stdin. Do not type it as part of
the shell command:

```sh
sudo /usr/local/sbin/install-c1-openbao-token
```

The initial token path runs the host TTL gate while the controller remains stopped. For later
rotation, the same helper requires the controller service to be active, atomically installs the
replacement, restarts the systemd-owned controller, waits for health, first proves that public
`main` contains the exact provider-backed libreFS mapping, then triggers an authenticated tracked
Doco poll. A missing app, failed provider resolution, or failed run restores the prior token.
Revoke the prior token only by its retained accessor after this full provider canary passes.

Enable renewal, then start the systemd-owned controller:

The Compose service has no Docker restart policy. On boot, only `doco-cd-c1.service` starts it.
Its `Requires=` ordering covers Docker, `c1-librefs-storage.service`,
`c1-applications-storage.service`, `assert-c1-mount`, and the network unit
`c1-services-network.service` (which transitively Requires/After Docker and the shim unit
`c1-services-shim.service` whose interface is `c1-svc-shim`; the systemd and helper filenames
are unchanged — only the link name was shortened to satisfy Linux IFNAMSIZ); its real
`ExecStartPre` TTL gate runs after those storage prerequisites. A low/expired token therefore
blocks Doco rather than racing the five-minute persistent renewal timer. An initial Doco deploy
is safe: Doco's controller cannot start until the same storage units and the network unit are
active (the network unit itself depends on the shim).

## Controller and libreFS checkpoint

Live Doco 0.111.0 rejected the original Compose `secrets.environment` source for the libreFS
credentials (only `file` is supported). The first deploy failed before container creation; no
credential material was rendered. The corrected pattern uses top-level Compose `configs.content`
populated from the Doco-resolved `LIBREFS_ROOT_USER` and `LIBREFS_ROOT_PASSWORD` variables and
mounted at `/run/secrets/librefs_root_user` and `/run/secrets/librefs_root_password` with mode
`0400`, UID/GID `1000`. These are config-backed credential files, not Docker secrets. The
container environment still exposes only the `_FILE` paths. Resolved values exist only in
Doco's in-memory rendered project and may be materialized in protected engine or Doco artifacts
during the deploy window. A full exact-value leakage scan covering container environment,
rendered Compose output, project labels, runtime secret/config metadata, Doco logs/working
trees/data volume/persisted deployment artifacts, Docker and containerd metadata, journald,
application logs, temporary directories, and backup inputs is a blocking live canary. Mission
is blocked pending a new PR, merge, and successful Doco redeploy under the corrected pattern.

The runtime test always creates a uniquely named isolated bridge network, container, and
Docker named data volume (pre-owned `1000:1000`/`0750`, not a host temp bind) so
containerized Linux Docker clients and CI exercise Compose 5.5 injection without host-path
namespace mismatch; the production `/srv/librefs/data` bind with `create_host_path: false`
remains statically asserted and live-verified separately. The test generates per-run CSPRNG
canaries, executes the actual `compose up`, and proves container health, exact file ownership
and mode on the config-backed credential files at
`/run/secrets/librefs_root_{user,password}`, UID 1000 reads, and the absence of canary material
in inspect, environment, and logs. The runtime test then cleans up the isolated bridge
network, container, and named volume. The runtime test never skips when `c1_services` exists;
the isolated test network and named volume are always freshly created and torn down.

Do not deploy libreFS with real credentials until the exact-value leakage scan passes and the
complete allowed and denied cleartext source matrix is verified. Before `main` contains the app,
the explicitly weakened initial check proves API authentication and Git polling only; no prior
token may be revoked on that evidence. After merge, the default checker refuses to run unless
public `main` contains the exact provider-backed mapping, and its successful tracked poll proves
OpenBao resolution.

Controller rollback retains `doco-cd-c1-data`:

```sh
sudo systemctl stop doco-cd-c1.service
sudo install -o root -g root -m 0644 /root/c1-controller-backup/docker-compose.app.yaml /opt/doco-cd/docker-compose.app.yaml
sudo systemctl start doco-cd-c1.service
sudo /usr/local/sbin/check-c1-doco-controller
sudo docker volume inspect doco-cd-c1-data
```

For libreFS rollback, stop `doco-cd-c1.service` and `librefs-c1.service` first, restore the prior
reviewed image/config, retain `/srv/librefs/data`, and use `manage-c1-librefs` to recreate only
libreFS. Docker has `restart: no` on the `librefs-c1` container, so systemd—not Docker—owns every
start/stop. Never run `docker compose down -v`, create a fallback `/srv/librefs/data`, delete
`c1_services` while attached, reformat a disk, or remove the Doco volume to recover from an
application failure. Final status remains `OPERATIONAL_WITHOUT_DURABILITY` until an approved
off-host restore succeeds.
