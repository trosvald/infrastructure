# Monosense Container Services

Inventory last verified over SSH on 2026-08-25. The canonical hostnames are `c0` and `c1`.

## Nodes

| Node | Purpose | Processor | Memory | Operating system | Container runtime |
| --- | --- | --- | ---: | --- | --- |
| `c0` | Core services | Intel Core i7-7700T, 4 cores/8 threads | 32 GiB | Debian 13.6, kernel `6.12.101+deb13-amd64` | Docker Engine 29.7.2, Compose 5.5.0 |
| `c1` | General services | Intel Core i7-8700T, 6 cores/12 threads | 64 GiB | Debian 13.6, kernel `6.12.101+deb13-amd64` | Docker Engine 29.7.2, Compose 5.5.0 |

c0 runs Doco-CD, OpenBao, its certificate renewer, PowerDNS, and Omada Controller. c1 has no
persistent containers.

## Doco-CD on c0

Doco-CD is host-bootstrap-owned and is not one of the applications it manages. Its reviewed
bootstrap source is `docker/bootstrap/c0/doco-cd/`; operators install `compose.yml` and
`poll-config.yml` once as `/opt/doco-cd/compose.yml` and `/opt/doco-cd/poll-config.yml`.
Application Compose projects belong under direct children of `docker/c0/` and are discovered
through `.doco-cd.c0.yml`. Never place the Doco-CD bootstrap beneath `docker/c0/`, because doing
so would allow the controller to discover and manage itself.

The poller reads the public repository `https://github.com/trosvald/infrastructure.git` at
`refs/heads/main` every 180 seconds with target `c0`. Files must therefore be committed and
published to `origin/main` before Doco-CD can use them. Local filesystem watching, reconciliation,
and webhooks are disabled.

The management API and metrics endpoint are published only on c0 loopback:

- API: `http://127.0.0.1:8080`
- Metrics: `http://127.0.0.1:9120/metrics`

Use an SSH tunnel from an operator workstation; do not expose either port on a management or
SERVICES address:

```sh
ssh -L 8080:127.0.0.1:8080 monosense@10.25.10.20
```

On c0, inspect health and controller state without disclosing the API secret:

```sh
curl -fsS http://127.0.0.1:8080/v1/health
sudo DOCO_CD_API_SECRET_FILE=/opt/doco-cd/secrets/api_secret \
    docker compose -f /opt/doco-cd/compose.yml ps
sudo DOCO_CD_API_SECRET_FILE=/opt/doco-cd/secrets/api_secret \
    docker compose -f /opt/doco-cd/compose.yml logs
```

The API secret is `/opt/doco-cd/secrets/api_secret`, owned by root with mode `0600`. Never print,
copy from c0, or commit it. Doco-CD owns the persistent named volume `doco-cd-data`; rollback must
not remove that volume.

Doco-CD and OpenBao are deployed and reboot-verified as of 2026-08-24. PowerDNS Authoritative was
deployed on 2026-08-25 and its container restart, named-volume persistence, encrypted backup, and
isolated c1 restore were verified. Omada Controller was reset to a fresh, unconfigured deployment
on 2026-08-25 for manual operator setup. cAdvisor and native observability remain undeployed on c0.

## Application inventory

| Node | Doco-CD project | Address/network | Exposure | State |
| --- | --- | --- | --- | --- |
| `c0` | `openbao-c0` | `10.25.13.34`, `c0_services` | Direct SERVICES IPvlan | Deployed |
| `c0` | `powerdns-c0` | `10.25.13.33`, `c0_services` | Direct SERVICES IPvlan | Deployed |
| `c0` | `omada-controller-c0` | `10.25.10.26`, `c0_omada_mgmt` | Direct MGMT IPvlan; no host ports | Deployed |

Omada runs Controller `6.2.14.11` with a manually configured local owner and site. The operator
confirmed successful device adoption after correcting the previous Device Account credentials; see
[`docs/OMADA.md`](../docs/OMADA.md).

## Storage

| Node | Device | Model | Capacity | Current use |
| --- | --- | --- | ---: | --- |
| `c0` | `sda` | SDLF1DAM800G-1HHS SSD | 800 GB | Debian system disk; LVM-backed ext4 root |
| `c1` | `sda` | Samsung SSD 860 EVO | 500 GB | Debian system disk; LVM-backed ext4 root |
| `c1` | `nvme1n1` | PNY CS1031 | 1 TB | No mounted filesystem |
| `c1` | `nvme0n1` | TEAM TM8FP6512G | 512 GB | No mounted filesystem |

Do not assign persistent service paths to the unmounted c1 NVMe devices until their partitioning, filesystem, redundancy, and backup roles are designed.

## Networking

Both hosts use Debian `ifupdown`; persistent configuration is in `/etc/network/interfaces`.

| Node | Interface | Adapter and state | Current address | Gateway | Configured DNS |
| --- | --- | --- | --- | --- | --- |
| `c0` | `enp0s31f6` | Intel I219-LM, 1 Gbps, up | `10.25.10.20/24` | `10.25.10.1` | `10.25.10.100`, search `monosense.io` |
| `c1` | `eno1` | Intel I219-LM, 1 Gbps, up | `10.25.10.101/24` | `10.25.10.1` | `10.25.10.100`, search `monosense.io` |
| `c1` | `bond0` | Mellanox ConnectX-3, 2×10 Gbps LACP, up | None | None | None |

`bond0` connects to tor2 ports 5 and 6 with LACP active and a `layer3+4` transmit hash policy. VLAN 2511 is native/untagged. `bond0.2512` carries tagged HOME VLAN 2512 and `bond0.2513` carries tagged SERVICES VLAN 2513; both VLAN interfaces use MTU 1496 and have no host L3 address.

### Current SRX state

The SRX1500 is configured manually; the live configuration is not currently owned or deployed by `ansible/junos`. Its c0-facing `ge-0/0/2` port is already `TO-C0-TRUNK`, with VLAN 2510 native/untagged and the current `VLAN-DEV` object for tagged VLAN 2513.

Do not run a Junos Ansible deployment until the complete manually maintained configuration has been reconciled with the repository intent and its diff reviewed. The existing direct configuration must not be combined blindly with the renderer's `ANSIBLE_SRX1500` configuration group.

## Omada MGMT network

Omada uses a dedicated external Docker IPvlan L2 network rather than `c0_services`:

| Property | Deployed value |
| --- | --- |
| Network | `c0_omada_mgmt` |
| Parent | `enp0s31f6` |
| Subnet/gateway | `10.25.10.0/24`, `10.25.10.1` |
| Dynamic range | `10.25.10.26/32` |
| Recorded host auxiliary address | `10.25.10.20` |
| Omada address | `10.25.10.26` |
| Host shim | none |
| State | Deployed and idempotence-verified on 2026-08-25 |

This gives the container a true endpoint on the untagged MGMT broadcast domain and preserves Omada
UDP broadcast discovery. IPvlan uses the parent MAC on the wire, avoiding the additional upstream
MAC required by Macvlan. Bridge plus published ports would not preserve same-LAN broadcast
discovery, while host networking could not provide the distinct `.26` identity.

Linux IPvlan isolates parent-host and child traffic in both directions. No shim is approved because
no c0-local dependency has been demonstrated; monitoring, backup export, DNS/NTP dependencies, and
acceptance probes must be confirmed absent before deployment. Operators and probes use a separate
MGMT host. Any future shim requires a separately reviewed route/interface change and a newly
reserved `/32`.

`c0_omada_mgmt` is host-bootstrap-owned and external to Compose. The deterministic
`docker/bootstrap/c0/omada-controller-network/ensure.sh` created the live network on 2026-08-25,
then passed an idempotent exact-state recheck. It is not run by Doco-CD. Authoritative IPAM and
switch/SRX DAI, DHCP-snooping, IP-source-guard, port-security, and ARP-policy evidence remain
operator follow-up because the deployment did not modify or inspect those systems.

Omada attaches only to `c0_omada_mgmt`, never `c0_services`, and publishes no host ports. Because
IPvlan is direct L2 exposure, absence of `ports:` means no Docker host-port binding or DNAT; it is
not a firewall. Required Omada listeners and network policy must be verified live. The complete
migration, network lifecycle, port list, acceptance, backup, upgrade, and rollback procedure is in
[`docs/OMADA.md`](../docs/OMADA.md).

## SERVICES Network

Management addresses remain unchanged during the initial deployment:

| Node | Management | VLAN parent | IPvlan network | Host shim | Owned service addresses | State |
| --- | --- | --- | --- | --- | --- | --- |
| `c0` | `10.25.10.20/24` | `enp0s31f6.2513` | `c0_services` | `10.25.13.16/32` | `10.25.13.33-62` | Network and shim deployed |
| `c1` | `10.25.10.101/24` | `bond0.2513` | `c1_services` | `10.25.13.17/32` | `10.25.13.65-94` | VLAN parent ready; network and shim pending |

SERVICES uses VLAN 2513, subnet `10.25.13.0/24`, gateway `10.25.13.1`, static addressing, Docker IPvlan L2, and MTU 1496. Deployed c0 assignments are:

- PowerDNS Authoritative: `10.25.13.33`
- OpenBao: `10.25.13.34`

PowerDNS is authoritative-only for one private forward zone and four `/24` reverse zones. Git owns
the canonical content; the API, web server, and host port mappings are disabled. AdGuard Home at
`10.25.10.100`, Cloudflare authority, and Kubernetes are unchanged. See
[`docs/POWERDNS.md`](../docs/POWERDNS.md).

On c0, `/etc/network/interfaces` persistently creates the VLAN parent and IPvlan shim. The host route `10.25.13.32/27 dev c0-svc-shim src 10.25.13.16` provides host-to-container access. `c0_services` uses IPvlan L2 with IPv6 disabled and no dynamic `--ip-range`; every service must declare its static address.

Validation from a temporary container at `10.25.13.62` proved container-to-gateway, host-to-container, and container-to-shim connectivity. The test container and address were removed. Recovery copies are `/etc/network/interfaces.pre-c0-services-20260824` and `/etc/network/interfaces.pre-c0-shim-20260824`.

A controlled reboot of both nodes verified persistence. On c0, the VLAN parent, shim address, route, and Docker network returned; a fresh `.62` container again reached the gateway and shim in both directions. On c1, both 10 Gbps members returned in one healthy LACP aggregator, both tagged VLAN interfaces returned, and a temporary `.94` address reached the SERVICES gateway. All temporary validation state was removed.

Do not use future management addresses `10.25.10.9` or `10.25.10.10` until the separate renumbering migration. The c1 bond and VLAN parents are ready; `c1_services`, its host shim, and service addresses remain undeployed.