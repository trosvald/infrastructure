# Omada Software Controller

Omada Software Controller is deployed on c0 and reconciled by Doco-CD from commit `8948d1e`.
Controller `6.2.14.11` was reset to clean named volumes on 2026-08-25. No old backup is restored;
the operator owns manual account, site, and device configuration.

## Evidence boundary

### OFFLINE VERIFIED

- Target release: TP-Link Omada Software Controller `6.2.14.11`, published as the stable release on
  2026-07-17.
- Image: `docker.io/mbentley/omada-controller:6.2.14.11@sha256:157f0e730e6ce4211ab5df533af656495c9803791356ced7fcec28b3caca03ad`.
- Platform: `linux/amd64`. The digest is the multi-platform index and its amd64 manifest was checked;
  c0's Intel i7-7700T exposes the AVX/AVX2 required by the image's MongoDB 8 runtime.
- Repository intent: project `omada-controller-c0`, two preserved named volumes, rootless controller,
  fixed MGMT IPvlan address, no host port publication, and no attachment to `c0_services`.
- The exact external-network ensure script is designed to validate or create one fixed network and
  fail closed on drift. Its presence does not prove that the network exists on c0.

### LIVE VERIFIED — 2026-08-25

- Doco-CD poll deployed commit `8948d1e` as project `omada-controller-c0`.
- External IPvlan L2 network `c0_omada_mgmt` passed exact creation and idempotence validation.
- The container is healthy at `10.25.10.26/24` with gateway `10.25.10.1`, no published ports, and
  only the approved network attachment.
- The controller reached `10.25.10.1:443` from its network namespace.
- The active named volumes are fresh and contain no imported old-controller configuration.
- The UI presents the first-run setup wizard and `Create a Local Account`.
- Historical recovery attempts were preserved in quarantine volumes and are not attached to the
  running project.
- Listener inspection confirmed the documented TCP/UDP ports and loopback-only MongoDB
  `127.0.0.1:27217`.

### REMAINING LIVE VERIFICATION

The following evidence is still required for complete operational closure:

- authoritative IPAM reservation/exclusion evidence for `10.25.10.26`;
- switch/SRX DAI, DHCP-snooping, IP-source-guard, port-security, and ARP-policy evidence;
- completion of the first-run local owner, controller, site, and device configuration;
- certificate identity/trust review;
- device adoption, Omada mobile-app discovery, and OLT discovery where applicable;
- post-setup backup export, encrypted off-host retention, an isolated restore drill, and rollback.

IP address preservation alone is insufficient. Device adoption, site/controller identity,
certificates, administrators, settings, and port state live in the controller database. Raw v5 data
must not be mounted into v6; use TP-Link's supported backup/import path and, where required, its
supported MongoDB 3.6-to-8 intermediate migration.

## Primary references

- [TP-Link Omada Software Controller downloads](https://support.omadanetworks.com/us/download/software/omada-controller/)
- [TP-Link: create and download a v6 backup](https://support.omadanetworks.com/en/document/120554/)
- [TP-Link: controller upgrade/downgrade guidance](https://support.omadanetworks.com/us/document/13146/)
- [Pinned image tag on Docker Hub](https://hub.docker.com/r/mbentley/omada-controller/tags?name=6.2.14.11)
- [TP-Link: Omada controller ports](https://www.tp-link.com/us/support/faq/3281/)
- [`mbentley/omada-controller` image documentation](https://github.com/mbentley/docker-omada-controller)
- [Docker IPvlan driver](https://docs.docker.com/engine/network/drivers/ipvlan/)
- [Compose external networks](https://docs.docker.com/reference/compose-file/networks/#external)

Before a live change, re-read the release notes and current documentation for the exact source and
target versions. Product documentation, not this runbook, decides backup compatibility.

## Intended topology

| Property | Required value |
| --- | --- |
| Project | `omada-controller-c0` |
| Host parent | `enp0s31f6` (`10.25.10.20/24`) |
| External network | `c0_omada_mgmt` |
| Driver/mode | Docker IPvlan L2 |
| Subnet/gateway | `10.25.10.0/24`, `10.25.10.1` |
| Container range/address | `10.25.10.26/32`, static `10.25.10.26` |
| Recorded host auxiliary address | `10.25.10.20` |
| Host shim | none |
| Other Docker networks | none; especially never `c0_services` |

IPvlan L2 makes the container a true MGMT-LAN endpoint. It uses the parent interface's MAC on the
wire, participates in normal gateway/ARP and same-broadcast-domain traffic, and preserves UDP
broadcast discovery. This differs from:

- bridge plus published ports, which gives no true `10.25.10.26` LAN endpoint and does not forward
  same-LAN UDP broadcasts through NAT;
- host networking, which can only share c0's `10.25.10.20` identity;
- Macvlan, which could provide L2 attachment but adds a distinct upstream MAC with no discovery
  advantage here;
- `c0_services`, which is VLAN 2513 on `10.25.13.0/24`, not MGMT.

Linux intentionally isolates an IPvlan parent's host namespace and its children **in both
directions**. Therefore c0 cannot use `10.25.10.26`, and Omada cannot use c0's parent address. No shim
is approved because no host-local monitor, backup exporter, DNS/NTP dependency, or acceptance probe
has been demonstrated. Confirm that absence before deployment. Operators, devices, UI clients, and
acceptance probes must use separate MGMT hosts. A future shim is a separately reviewed host-network
change and requires a newly reserved `/32`; do not improvise one.

The container is directly exposed to MGMT even though Compose has no `ports:` entries. No published
ports means only that Docker performs no host-port binding or DNAT; it is **not a firewall**. Enforce
reachability in the authoritative network policy and verify actual listeners after restore.

### Runtime and storage

The named volumes `omada-controller-data` and `omada-controller-logs` use `nocopy` and must survive
recreate, rollback, and troubleshooting. On fresh volumes only, `volume-init` runs network-isolated
as `0:0` with all capabilities dropped except `CHOWN`, establishing `508:508` ownership. It has no
restart policy or other mounts. The controller then runs as `508:508` with `ROOTLESS=true`, all
capabilities dropped, `no-new-privileges`, no Docker socket, no privileged mode, and no secrets.

The declared operational envelope is two CPUs, 4 GiB RAM with a 5 GiB memory-plus-swap ceiling,
swappiness zero, `nofile` soft/hard `4096:8192`, JSON logs limited to 10 MiB × 3, restart
`unless-stopped`, a 60-second stop grace period, and `/healthcheck.sh` HTTPS-login readiness with a
five-minute start period. These declarations are not proof of live enforcement or application
health.

### Required application ports

| Protocol | Ports | Purpose class |
| --- | --- | --- |
| TCP | `8088`, `8043`, `8843`, `29811-29817` | web/portal and controller/device services |
| UDP | `27001`, `29810` | discovery/controller services |
| UDP | `19810` | OLT discovery |
| TCP | `27217` | embedded MongoDB; must remain internal/loopback-only |
| TCP | `9098` | observed wildcard-bound internal Omada service; not listed in TP-Link's public port table |

TCP `9098` responded on MGMT during acceptance but is not documented in TP-Link's current public
port table. Treat it as direct MGMT exposure pending vendor clarification; do not expose MGMT
publicly.

The deployment explicitly stores the defaults and leaves `WEB_CONFIG_OVERRIDE=false`, so restored
database state is not forcibly rewritten. Before cutover, the source controller's stored ports must
exactly match the TCP and UDP list above. A mismatch is not corrected during deployment: stop and
perform a separate reviewed port-conversion migration. After restore, inspect real listeners and
functional traffic; environment values are not evidence.

## External network lifecycle

Compose declares `c0_omada_mgmt` as external. Doco-CD cannot create or remove it. The host-bootstrap
artifact is `docker/bootstrap/c0/omada-controller-network/ensure.sh`; it owns only the Docker network
object and never changes host interfaces, routes, addresses, SRX, switches, or IPAM.

> **OPERATOR-ONLY — LIVE/DANGEROUS. DO NOT RUN FROM CI OR AS PART OF REPOSITORY VALIDATION.** Run on
> c0 from the root of a reviewed checkout only after the IPAM and switch-policy prerequisites pass.

```sh
sudo ./docker/bootstrap/c0/omada-controller-network/ensure.sh
sudo docker network inspect c0_omada_mgmt
```

The ensure operation is deterministic:

1. If Docker is unavailable or inspection fails unexpectedly, it exits without mutation.
2. If the network exists, every critical field must match: name; local scope; non-internal,
   non-attachable, non-ingress, non-config-only state; IPv4 enabled and IPv6 disabled; `ipvlan`
   driver in L2 bridge mode; parent `enp0s31f6`; read-only parent preflight requiring the interface
   to be up at MTU `1500`; default IPAM with subnet `10.25.10.0/24`, gateway `10.25.10.1`, range
   `10.25.10.26/32`, and auxiliary address `c0=10.25.10.20`; plus the exact bootstrap
   ownership/purpose labels. Any mismatch fails closed; it never repairs or replaces the object.
3. If absent, it creates exactly that object once and immediately re-inspects it. A mismatched or
   failed post-create check is an error, not acceptance.
4. Docker persists the object across reboot. After a host rebuild, run the same ensure step before
   Doco-CD can discover the application.

Never hand-create a near-match. To remove the network, first stop Doco-CD polling, stop and detach
Omada without deleting its volumes, then require zero endpoints:

> **OPERATOR-ONLY — LIVE/DESTRUCTIVE NETWORK REMOVAL.**

```sh
sudo docker network inspect \
    --format '{{len .Containers}}' c0_omada_mgmt
# Continue only when the preceding command prints exactly 0.
sudo docker network rm c0_omada_mgmt
```

Do not remove a network with attached endpoints and do not remove it merely to fix drift. Diagnose
why live state differs from reviewed intent first.

## Serialized first cutover

Only one operator controls the sequence. Keep the old controller unchanged and available for
rollback, but offline after its final backup. Never let old and new controllers use `.26`
simultaneously.

### 1. Record the source

Record outside Git, in the change evidence:

- exact old-controller version and supported migration path to `6.2.14.11`;
- every stored TCP/UDP port and confirmation that it equals the defaults above;
- sites, devices, model/firmware, adoption/connected state, and pending operations;
- controller/site identity, certificate chain and fingerprint, administrator identities and tested
  recovery access, plus settings expected after restore;
- per-model evidence that current firmware supports Controller `6.2.14.11` and its adoption/security
  behavior.

Any unknown or incompatible item blocks publication.

### 2. Export and rehearse restore

Create the old controller's final in-app backup, download it directly into protected operator
custody, record the originating version, and checksum it without putting it in Git:

```sh
umask 077
sha256sum omada-final-backup-<UTC-date>.<vendor-extension> \
    > omada-final-backup-<UTC-date>.<vendor-extension>.sha256
sha256sum -c omada-final-backup-<UTC-date>.<vendor-extension>.sha256
```

The file and checksum are **LIVE_DEPLOYMENT_PREREQUISITE** evidence. Rehearse the documented restore
on a separate, network-isolated host using clean v6 volumes and the exact target image. The rehearsal
must not reach production devices or reuse production volumes. Confirm login, sites, devices,
settings, identity/certificate, and stored ports. For a pre-v5 or otherwise unsupported backup, use
only TP-Link's documented intermediate migration; do not experiment on the final backup or mount raw
old data into v6.

Destroy the isolated rehearsal only after recording results. Its success proves backup readability,
not production cutover.

### 3. Prove MGMT readiness

In authoritative IPAM, reserve/exclude `10.25.10.26`; absence from a local hosts file or DHCP lease
list is insufficient. Review the complete path to c0 for DAI, DHCP snooping, IP source guard,
port-security, and ARP policy. IPvlan presents `.26` with c0's parent MAC. Apply the
platform-appropriate static binding or trust remediation if required, then record the resulting
binding and bidirectional ARP evidence. Do not disable protections broadly.

Stop the old controller and disable its automatic start. From a **separate MGMT host**, clear stale
neighbor state according to that host's OS and prove `.26` is absent with both ARP/neighbor and
connection probes. Do not perform this probe from c0 because parent/child isolation makes it
non-authoritative. Any response blocks cutover.

### 4. Ensure network, then publish

Run the operator-only ensure procedure above. Only after it succeeds may the reviewed change be
committed and pushed to `origin/main`. Doco-CD discovers the direct child
`docker/c0/omada-controller` and reconciles project `omada-controller-c0` on its next poll. Do not
manually create a competing Compose project, attach `c0_services`, publish ports, or start a second
controller.

Observe Doco-CD's poll and require the volume initializer to exit successfully and the controller to
be healthy. Keep the old controller unchanged and offline until all acceptance and post-restore
backup steps pass.

## Restore and acceptance

On first start, use the target controller's first-run restore workflow to import the rehearsed
backup into the fresh named volumes. Do not configure a new site first, reset/re-adopt devices, or
copy database files into a running controller. Allow migration and startup to finish without
interrupting it.

Resolve the one controller container by Compose labels before container-local checks:

> **OPERATOR-ONLY — LIVE INSPECTION.**

```sh
mapfile -t omada_ids < <(sudo docker ps -q \
    --filter label=com.docker.compose.project=omada-controller-c0 \
    --filter label=com.docker.compose.service=omada-controller)
test "${#omada_ids[@]}" -eq 1
omada_id=${omada_ids[0]}
sudo docker inspect --format '{{.State.Status}} {{.State.Health.Status}}' "$omada_id"
sudo docker exec "$omada_id" /healthcheck.sh
sudo docker inspect --format \
    '{{with index .NetworkSettings.Networks "c0_omada_mgmt"}}{{.IPAddress}} {{.Gateway}}{{end}}' \
    "$omada_id"
```

Require `running healthy`, a successful health script, and `10.25.10.26 10.25.10.1`. Then collect
all of the following from a separate MGMT host or the container as specified:

1. **Listeners:** inventory actual TCP and UDP listeners in the container. Require only reviewed
   Omada sockets to be wildcard-bound; prove TCP `27217` is loopback-only. If the image has `ss`:

    ```sh
    sudo docker exec "$omada_id" ss -lntup
    ```

   If it does not, record `/proc/net/{tcp,tcp6,udp,udp6}` with an approved decoder or use an approved
   inspection image in the same network namespace. Do not infer listener state from Compose.
2. **UI and health:** from a separate MGMT host, open `https://10.25.10.26:8043`, authenticate with a
   named administrator, confirm the expected certificate identity/fingerprint, and confirm the
   controller reports healthy. Test the restored portal where used; do not bypass a certificate
   mismatch.
3. **TCP services:** exercise the UI, portal, and controller/device flows on TCP
   `8088/8043/8843/29811-29817`. A port scan alone is not a functional test.
4. **UDP and discovery:** exercise UDP `27001`, `29810`, and OLT discovery `19810` using relevant real
   hardware/app workflows. Mark each hardware-dependent check live-unverified until actually used;
   UDP scan ambiguity is not success.
5. **Devices and app:** compare pre/post site and device inventories; require devices to reconnect in
   their previous adopted state without reset/re-adoption. Verify Omada app discovery and management.
6. **Restored state:** verify controller/site identity, certificate fingerprint, administrators,
   settings, and actual stored ports against the source record.
7. **Persistence:** after a healthy baseline, perform one controlled Compose recreation of the
   Doco-CD-owned project without volume deletion, then a controlled container restart. This proves
   Compose-level persistence; the separately observed Doco-CD poll proves reconciliation. Require
   the same sites, devices, identity, certificate, administrators, settings, backup configuration,
   and named-volume identities after both actions.

    > **OPERATOR-ONLY — LIVE RECREATE/RESTART.** Run from the exact published checkout on c0 only
    > after taking the required backup. These commands preserve named volumes because they never use
    > `-v`.

    ```sh
    sudo docker volume inspect omada-controller-data omada-controller-logs
    sudo docker compose -p omada-controller-c0 \
        -f docker/c0/omada-controller/compose.yml up -d --force-recreate
    sudo docker volume inspect omada-controller-data omada-controller-logs
    omada_id=$(sudo docker compose -p omada-controller-c0 \
        -f docker/c0/omada-controller/compose.yml ps -q omada-controller)
    test -n "$omada_id"
    sudo docker restart "$omada_id"
    ```
8. **Backup:** immediately export a post-restore in-app backup, checksum it, transfer it to encrypted
   off-host custody, and verify the copy and permissions. Configure and observe the policy below.

Do not declare acceptance with missing devices, changed identity, a reset/re-adoption requirement,
wrong ports, a wildcard MongoDB listener, or untested rollback evidence.

## Backup policy and restore drills

- Configure one **daily in-app backup** and retain **30 days** in encrypted off-host custody.
- The destination is operator-supplied because this repository has no approved Omada backup
  repository. It must be outside Git and outside c0's Docker volumes.
- Observe successful export/transfer; a configured schedule without a retrievable off-host artifact
  is failure. Protect backup files and checksum sidecars with least-privilege permissions.
- Make and checksum a manual backup before every change/upgrade and immediately after a restore.
- Periodically rehearse restoration on a separate isolated host with clean volumes, the compatible
  image, and no path to production devices. Record checksum, source/target version, time, inventory,
  login, identity/certificate, ports, and result.

A raw volume backup is secondary evidence only. Stop the controller cleanly and allow the full
60-second grace period before copying both named volumes as one generation. Encrypt it off-host and
record image version plus checksums. Never copy a live MongoDB volume and never treat a one-volume
copy as recoverable.

Restore into clean volumes with the TP-Link in-app workflow whenever supported. A cold snapshot may
be restored only with its recorded compatible image and both volumes. Never attach an older image to
volumes touched by a newer version.

## Routine Doco-CD lifecycle

Git is the configuration control plane. Doco-CD polls published `origin/main`; a local edit is not a
deployment. For routine changes:

1. make a fresh manual in-app backup and verify its encrypted off-host copy;
2. review release/backup/firmware compatibility and the exact image digest;
3. validate and publish the reviewed repository change;
4. require a successful Doco-CD poll and healthy container;
5. repeat listener, UI, device/app, identity, persistence-impact, and backup checks appropriate to
   the change.

For incident containment, stop Doco-CD polling first so it cannot recreate a stopped project. Operate
from an exact reviewed checkout on c0 and preserve volumes:

> **OPERATOR-ONLY — LIVE SERVICE INTERRUPTION.**

```sh
sudo docker stop doco-cd
sudo docker compose -p omada-controller-c0 \
    -f docker/c0/omada-controller/compose.yml down
```

Never append `-v`. Restart Doco-CD from its reviewed host-bootstrap Compose project only after the
repository state and retained data are safe:

```sh
sudo env DOCO_CD_API_SECRET_FILE=/opt/doco-cd/secrets/api_secret \
    DOCO_CD_SOPS_AGE_KEY_FILE=/opt/doco-cd/secrets/sops_age_key \
    docker compose -f /opt/doco-cd/compose.yml up -d
```

## Upgrades and rollback

### Upgrade

Read TP-Link and image release notes, confirm firmware and backup-path compatibility, inventory the
live state, export/checksum an encrypted off-host manual backup, and complete an isolated clean-volume
restore rehearsal before changing the pinned digest. Publish only the reviewed target image and keep
pre-change evidence and volumes quarantinable. After reconciliation, repeat full acceptance and make
a post-upgrade backup. Never assume an image rollback can downgrade MongoDB data.

### Initial-cutover rollback

This returns service to the **unchanged old controller** and is the preferred rollback until initial
acceptance:

1. stop Doco-CD polling;
2. stop/detach the new project without `-v`;
3. require `c0_omada_mgmt` to have zero endpoints and prove from a separate MGMT host that `.26`
   disappears;
4. leave new volumes retained and untouched for diagnosis;
5. restart the unchanged old controller and verify its identity, certificate, sites, adopted devices,
   ports, UI, and app/device traffic;
6. do not restart Doco-CD until repository intent can no longer recreate the failed cutover.

### Configuration-only rollback

Only the **identical image version and digest** may reuse existing named volumes. Revert the reviewed
configuration, retain both volumes, reconcile, and repeat acceptance. If the image changes in either
direction, use the image rollback procedure instead.

### Image downgrade or incompatible rollback

Never start an older image against newer-touched data. Stop Doco-CD and the project, quarantine both
newer volumes as an inseparable, clearly versioned generation, create clean replacements with the
fixed production volume names, and restore either a compatible pre-change in-app backup or a verified
compatible cold snapshot. Re-run the initializer/ownership path and complete full acceptance before
re-enabling polling. Keep quarantined data until recovery evidence and retention policy permit manual
removal.

`docker compose down -v` is prohibited in every deployment, restore, rollback, and troubleshooting
path. Volume deletion is never a repair technique.
