# c1 Operations

Date: 2026-08-26
Status: repository procedure; no live mutation is authorized; storage commands revised for
single-device 1 TB approval; no engine configuration is installed

This runbook is subordinate to `DESIGN-AND-PLAN.md`, `REVIEW.md`, `SECRET-CONTRACT.md`, and
`LIBREFS.md`. Repository validation is safe and offline:

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
`assert-c1-mount`, and `c1-services-shim.service` to be active before they start; `doco-cd-c1`
additionally runs the token TTL gate. Docker itself is independent of those mounts and remains
usable while either partition is absent. Affected bind-mounted applications (libreFS, future
HAProxy/Mattermost/Forgejo/PostgreSQL) fail closed if their partition mount is wrong or absent;
keep those applications stopped and repair the mount rather than creating fallback directories.

Use a separately reviewed export/restore or delta migration only if durable state must move; never
prune or delete an existing engine root.

## Network and shim checkpoint

Default helper invocation is read-only:

```sh
sudo docker/c1/.host/networks/services/ensure.sh
sudo docker/c1/.host/networks/services/ensure-shim.sh
```

After conclusive collision checks and explicit network approval, create only the exact network and
install the additive persistent shim:

```sh
sudo docker/c1/.host/networks/services/ensure.sh apply
sudo install -o root -g root -m 0755 docker/c1/.host/networks/services/ensure-shim.sh /usr/local/sbin/ensure-c1-services-shim
sudo install -o root -g root -m 0644 docker/c1/.host/networks/services/c1-services-shim.service /etc/systemd/system/c1-services-shim.service
sudo systemctl daemon-reload
sudo systemctl enable --now c1-services-shim.service
```

Repeat the full read-only host checkpoint. `.34` must still route through the management default;
only `10.25.13.64/27` may use the shim. On drift, stop. Do not delete an attached network. An
approved empty-network rollback is:

```sh
sudo systemctl disable --now c1-services-shim.service
sudo ip link delete c1-services-shim
endpoint_count="$(sudo docker network inspect -f '{{len .Containers}}' c1_services)"
test "$endpoint_count" -eq 0
sudo docker network rm c1_services
```

The removal command is forbidden unless the endpoint count is exactly zero and the outage/removal
has its own approval.

## OpenBao token lifecycle

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

```sh
sudo systemctl daemon-reload
sudo systemctl enable --now doco-c1-openbao-renew.timer
sudo systemctl enable --now doco-cd-c1.service
sudo systemctl status --no-pager doco-cd-c1.service
sudo env REQUIRE_PROVIDER_CANARY=false /usr/local/sbin/check-c1-doco-controller
```

The Compose service has no Docker restart policy. On boot, only `doco-cd-c1.service` starts it.
Its `Requires=` ordering covers Docker, `c1-librefs-storage.service`,
`c1-applications-storage.service`, `assert-c1-mount`, and `c1-services-shim.service`; its real
`ExecStartPre` TTL gate runs after those storage prerequisites. A low/expired token therefore
blocks Doco rather than racing the five-minute persistent renewal timer. An initial Doco deploy
is safe: Doco's controller cannot start until the same storage units and the shim are active.

## Controller and libreFS checkpoint

Do not deploy libreFS with real credentials until the secret-persistence canary and the complete
allowed and denied cleartext source matrix pass. Before `main` contains the app, the explicitly
weakened initial check proves API authentication and Git polling only; no prior token may be revoked
on that evidence. After merge, the default checker refuses to run unless public `main` contains the
exact provider-backed mapping, and its successful tracked poll proves OpenBao resolution.

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
