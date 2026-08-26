# c1 Performance Baseline

Date: 2026-08-26
Status: `APPLIED — awaiting benchmarks`. Storage applied successfully on the corrected retry:
two XFS partitions mounted and verified on the approved 1 TB NVMe (`c1_librefs` at `/srv/librefs`,
`c1_apps` at `/srv/applications`, `defaults,noatime`). Docker and containerd `SOURCE` equals `/`
source. The 512 GB device is quarantined/unmounted/excluded. Persistent shim `c1-svc-shim` and
network unit `c1-services-network.service` are active; route `10.25.13.64/27 dev c1-svc-shim`
verified with scope `link`. Benchmarking remains pending until network/S3 matrices are run.
Mission no longer blocked on storage or network.

## Pre-change evidence retained

- c1 management remains on the independent 1 Gb/s `eno1` path.
- Both 10 Gb/s bond members were up, synchronized, collecting, distributing, and in the same LACP
  aggregator during read-only discovery.
- Bond policy remains 802.3ad, fast LACP, `layer3+4`; one flow is limited to one member.
- `bond0` remains MTU 1500 and VLAN 2513 remains MTU 1496.
- Observed interface and qdisc counters had no current errors or drops.
- No MTU, offload, ring, channel, coalescing, IRQ, qdisc, sysctl, or driver tuning was applied.
- `fio`, `iperf3`, `sysstat`, `ethtool`, `nvme-cli`, and `smartmontools` were installed for the
  reviewed future matrix.

## Storage-health gate

| 1 TB libreFS + applications tier (applied) | SMART overall passed; critical warning 0; media errors 0; 13% used; 100% spare; two XFS partitions mounted `defaults,noatime` (`c1_librefs` at `/srv/librefs`, `c1_apps` at `/srv/applications`) |
| quarantined 512 GB | SMART overall passed; critical warning 0; **media/data-integrity errors 941**; 3% used; available spare 91%; firmware VC400618 has no verified official updater |

An overall SMART `PASSED` result does not override the non-zero media/data-integrity error count.
The 512 GB device stays quarantined/unmounted/excluded and is not used by this mission.

## Tuning result

Retained tuning changes: none.  
Reverted tuning changes: none.  
Aggregate 20 Gb/s claim: not made.

## Resume criteria

1. Run the network and S3 matrices in `DESIGN-AND-PLAN.md`, one tuning change at a time, on
   the applied 1 TB tier and approved off-host peers. The 1 TB NVMe is provisioned and mounted;
   no further storage mutation is required.
2. Without an off-host backup and tested restore, final status cannot exceed
   `OPERATIONAL_WITHOUT_DURABILITY`.
3. Storage and network gates are closed for the current mission state; remaining gates are
   OpenBao writes, push, merge, deploy, reboot, and off-host backup/restore.
