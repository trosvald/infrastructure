# c1 Operations

Date: 2026-08-26
Status: mission live gates complete; final status `OPERATIONAL_WITHOUT_DURABILITY` solely because
no off-host libreFS backup target/restore exists on c1 (no durability claim). User approved
controlled c1 reboot; outage and SSH recovery observed. Post-reboot verification passed: both
XFS noatime mounts and assertion units, Docker, c1 SERVICES network/shim, exact management
default route, active-backup bond/VLAN with two 10 Gb members and zero link-failure counts,
Doco/OpenBao token/controller canaries, healthy pinned `librefs-c1` at `.65` with no host ports and
credential files UID/GID 1000 mode 0400. Exact-value leakage and writable-root containment
scans passed again after reboot. Scoped S3 ready/upload/stat/download/checksum/delete/denial
passed again after reboot; 512 MiB observed 542,280,200 B/s upload and 2,014,577,014 B/s download
(post-reboot confirmation, not a replacement of the pre-reboot baseline of 567,957,345 B/s
upload and 1,863,741,635 B/s download). User explicitly skipped optional bond-member
failover; record intentionally not exercised, not a blocker. PR8 merged at
`599fff0e01301d77f5a2e204bac5df9a519f1823` and the reviewed helper
`docker/c1/.host/openbao/rematerialize-librefs-credentials.sh` is installed `root:root` mode
0755 on c1. No remaining live gates. The pre-reboot S3/perf/backup evidence is preserved:
512 MiB same-host Docker-network S3 baseline on `c1_services` against libreFS — upload
567,957,345 B/s, download 1,863,741,635 B/s (local bridge + storage + application evidence,
not external 10 Gb/s proof); workstation-to-c1 SERVICES TCP baseline over the actual routed
path — sender 113,948,113 bit/s, receiver 112,622,607 bit/s for 256 MiB (path and workstation
limited, not bond-capacity evidence); off-host libreFS backup verified as unconfigured and unproven
(Doco manages only `doco-cd-c1` and `librefs-c1`; only Debian `dpkg-db-backup` units exist
on c1; no restore was possible). User explicitly skipped optional bond-member failover.

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

Capture output into a root-only operator record. Verify management, routing, DNS, VLAN,
active-backup mode, and active member before and after every network action:

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

## EDGE, Forgejo, wildcard, and monitoring checkpoint

The c1 uplink bond is active-backup across TOR1/TOR2, not LACP. Do not change the bond. Before
installation, capture read-only switch evidence that VLAN 2515 `EDGE` is tagged on both SRX TOR
trunks and the c1 uplinks. Missing membership blocks all host and SRX mutation.

Install the additive `bond0.2515` stanza and EDGE network assets without starting them:

```sh
sudo docker/c1/.host/networks/edge/install.sh apply
sudo docker/c1/.host/storage/install-storage-assets.sh apply
sudo docker/c1/.host/openbao/install-wildcard-assets.sh
```

Provision the reviewed OpenBao records and named publisher/reader tokens through
`scripts/with-openbao-runtime.sh`; write token files directly as root, mode `0600`, without
printing them. Required paths are:

- `/opt/edge/secrets/wildcard-publisher.token` on c1;
- `/opt/edge/secrets/wildcard-reader-c1.token` on c1;
- `/opt/monitoring/secrets/wildcard-reader-c0.token` on c0.

Install c0 wildcard assets with
`sudo docker/c0/.host/openbao/install-wildcard-assets.sh`. Materialize the four monitoring values
and the c1 backup heartbeat token only through the 15-minute `monosense-infra` runtime:

```sh
sudo scripts/with-openbao-runtime.sh \
  docker/c0/.host/openbao/materialize-monitoring-secrets.sh
sudo scripts/with-openbao-runtime.sh \
  docker/c1/.host/openbao/materialize-forgejo-backup-heartbeat.sh
```

The monitoring materializer writes protected `gatus.yaml` and `vector.yaml` files below
`/var/lib/monosense-monitoring/secrets`; the c1 materializer writes
`/opt/forgejo/secrets/backup-heartbeat.token`. Values are never printed or placed in container
environment metadata. Wildcard reader timers are enabled but not started by their installers. Run
each reader service once only after Certbot has published a validated wildcard record; a failed
read or validation retains the previous generation.

Activate private infrastructure in this order:

1. publish the reviewed commit to `origin/main`;
2. enable/start `c1-edge-networks.service`, then prove `bond0` remains active-backup and
   `bond0.2515` is UP, MTU 1496, VLAN 2515, with no host address;
3. run `ensure-c1-edge-state check`, `ensure-forgejo-quotas check`, and
   `ensure-c1-forgejo-egress check`; verify `c1-forgejo-egress.service` is active;
4. let Doco deploy edge and Forgejo with WAN destination NAT absent;
5. after Certbot publishes the wildcard, run both wildcard reader services and recreate
   libreFS/c0 monitoring;
6. create and verify administrator `trosvald`, then remove both bootstrap config projections from
   `docker/c1/forgejo/compose.yml`, publish, and prove the old values absent;
7. run `configure-mirror.py` and prove `trosvald/infrastructure` refreshes from public GitHub while
   GitHub remains authoritative;
8. install/enable `forgejo-backup.timer`, run `forgejo-backup.service` once, and prove the
   `Backups/Forgejo backup` Gatus heartbeat is current; restore the Forgejo plus PostgreSQL dumps
   into an isolated target before claiming the 24-hour RPO/4-hour restore objective.

Candidate A is `edge.public_enabled: false`. Deploy it through the existing commit-confirmed
workflow and prove: `irb.2515` at `10.25.15.1/24`; no WAN-to-EDGE policy or destination NAT;
internal access only to HAProxy TCP 22/80/443; HOME access to Gatus HTTPS; and no EDGE-initiated
MGMT/PROD/HOME/DEV sessions. Prove HAProxy approved SNI, missing/unlisted SNI rejection, forged
forwarding-header replacement, 20-current/60-per-10-second connection limits,
300-requests-per-10-second limiting, generic AppSec denial, SPOA-only bypass, country denial,
PROXYv2 SSH, and the 10 GiB upload boundary.

Candidate B requires all prior evidence plus the stable MYREP IPv4 from OpenBao, external
reachability of TCP 22/80/443, an active CrowdSec/AppSec path, healthy Vector/Gatus evidence, and a
verified backup. Set `edge.public_enabled: true` and deploy commit-confirmed. After direct-origin
tests pass, create DNS-only `edge.monosense.io A <MYREP IPv4>`, then
`edge-test.monosense.io CNAME edge.monosense.io` and
`git.monosense.io CNAME edge.monosense.io`, with `proxied=false` and no AAAA records. Remove the
temporary `edge-test` record and echo backend after acceptance. If any public check fails, roll back
Candidate B first, remove public DNS, and retain the private deployment.

The Kopia repository at `https://s3.monosense.io` uses a scoped non-root identity, retains 30 daily
and 12 monthly snapshots, and deletes staging only after snapshot verification. It is on the same
c1 host and physical 1 TB device as the source. It does not survive host or disk loss and is not
off-host durability.

## Forgejo front-page customization recommendation

Keep `LANDING_PAGE = home` and the configured `APP_NAME` for initial acceptance. Do not customize
the login template or replace Forgejo's embedded assets before the private web, Git, mail, mirror,
backup, and restore checks pass.

For a later branded landing page, use one Git-owned, read-only custom directory mounted at
`/var/lib/gitea/custom`. Pin `templates/home.tmpl` to the exact Forgejo release and keep any CSS in
`public/assets/css/`; do not edit files inside the image, inject remote JavaScript, use a CDN, or
make the custom directory application-writable. The page should contain only:

- a short monosense identity and purpose statement;
- sign-in and public-repository links;
- the public status-page link;
- no private repository names, recent activity, service topology, software versions, internal
  hostnames, monitoring details, or operator email.

Template overrides are an unsupported, upgrade-coupled Forgejo surface. On every Forgejo patch,
compare the pinned upstream `home.tmpl`, render the anonymous and authenticated home pages at mobile
and desktop widths in both themes, verify login and public-repository navigation, and reject the
upgrade if the override produces template errors or omits security/navigation controls. Prefer
supported `app.ini` branding and a small CSS override when they meet the requirement; use a full
`home.tmpl` only when custom page structure is necessary.

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
sudo install -o root -g root -m 0755 docker/c1/.host/openbao/rematerialize-librefs-credentials.sh /usr/local/sbin/rematerialize-c1-librefs-credentials
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

Credential rematerialization after OpenBao rotation: Doco 0.111.0 does not redeploy or
rematerialize changed external-secret values when the Git source is unchanged, and the
`force_recreate` custom target did not replace an existing container. The tested fail-closed
procedure therefore stops `librefs-c1.service`, removes only the stateless container (never
`/data` or named volumes), invokes an isolated local-only Git custom target through Doco to
recreate the container with current provider values, then normalizes provenance to remote
`main`, restarts/checks the systemd gate, and cleans both the temporary source tree and the
cache. Revoke the prior token only by its retained accessor after this full provider canary passes.

Note: ordinary KV value changes alone do not redeploy or rematerialize the existing container
when the Git source is unchanged; live proof under PR6
(`3ff1aaf1facc23f6f85e5c95bc80b9e599289207`) confirmed this. Run
`/usr/local/sbin/rematerialize-c1-librefs-credentials`; it codifies this procedure. A failed
rematerialization that leaves an unverified or unnormalized replacement removes the in-flight
container and leaves `librefs-c1.service` stopped; the operator must rerun the helper from
the absent-container state after correcting Doco or provider health. `/data` and named
volumes are never touched.

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
application logs, temporary directories, and backup inputs was a blocking live canary at PR6
design time. PR6 (`3ff1aaf1facc23f6f85e5c95bc80b9e599289207`) is merged; the scan passed on
the merged artifact. The credential rotation leakage gate is closed: OpenBao KV v2
`kv/docker/c1/librefs` was rotated twice with CAS ending at version 3, and each rotation
proved the prior pair absent from every location while the current pair existed only in the two
approved `/run/secrets` files.

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
