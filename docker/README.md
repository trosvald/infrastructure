# Monosense Container Services

Inventory last verified over SSH on 2026-08-24. The canonical hostnames are `c0` and `c1`.

## Nodes

| Node | Purpose | Processor | Memory | Operating system | Container runtime |
| --- | --- | --- | ---: | --- | --- |
| `c0` | Core services | Intel Core i7-7700T, 4 cores/8 threads | 32 GiB | Debian 13.6, kernel `6.12.101+deb13-amd64` | Docker Engine 29.7.2, Compose 5.5.0 |
| `c1` | General services | Intel Core i7-8700T, 6 cores/12 threads | 64 GiB | Debian 13.6, kernel `6.12.101+deb13-amd64` | Docker Engine 29.7.2, Compose 5.5.0 |

Both Docker services are enabled. Both hosts currently use the `overlayfs` storage driver and `json-file` logging driver. No containers were present at inventory time.

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

Doco-CD is deployed on c0 and reboot-verified as of 2026-08-24. Its container, startup
poll, named volume, and loopback-only bindings survived a controlled reboot. BIND and OpenBao
remain undeployed; this bootstrap does not add cAdvisor, native observability, or a c0 SERVICES
address.

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

## SERVICES Network

Management addresses remain unchanged during the initial deployment:

| Node | Management | VLAN parent | IPvlan network | Host shim | Owned service addresses | State |
| --- | --- | --- | --- | --- | --- | --- |
| `c0` | `10.25.10.20/24` | `enp0s31f6.2513` | `c0_services` | `10.25.13.16/32` | `10.25.13.33-62` | Network and shim deployed |
| `c1` | `10.25.10.101/24` | `bond0.2513` | `c1_services` | `10.25.13.17/32` | `10.25.13.65-94` | VLAN parent ready; network and shim pending |

SERVICES uses VLAN 2513, subnet `10.25.13.0/24`, gateway `10.25.13.1`, static addressing, Docker IPvlan L2, and MTU 1496. Planned c0 assignments are:

- BIND9: `10.25.13.33`
- OpenBao: `10.25.13.34`

On c0, `/etc/network/interfaces` persistently creates the VLAN parent and IPvlan shim. The host route `10.25.13.32/27 dev c0-svc-shim src 10.25.13.16` provides host-to-container access. `c0_services` uses IPvlan L2 with IPv6 disabled and no dynamic `--ip-range`; every service must declare its static address.

Validation from a temporary container at `10.25.13.62` proved container-to-gateway, host-to-container, and container-to-shim connectivity. The test container and address were removed. Recovery copies are `/etc/network/interfaces.pre-c0-services-20260824` and `/etc/network/interfaces.pre-c0-shim-20260824`.

A controlled reboot of both nodes verified persistence. On c0, the VLAN parent, shim address, route, and Docker network returned; a fresh `.62` container again reached the gateway and shim in both directions. On c1, both 10 Gbps members returned in one healthy LACP aggregator, both tagged VLAN interfaces returned, and a temporary `.94` address reached the SERVICES gateway. All temporary validation state was removed.

Do not use future management addresses `10.25.10.9` or `10.25.10.10` until the separate renumbering migration. The c1 bond and VLAN parents are ready; `c1_services`, its host shim, and service addresses remain undeployed.