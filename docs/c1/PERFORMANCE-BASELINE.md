# c1 Performance Baseline

Date: 2026-08-26
Status: `BLOCKED` (storage boundary revised; single-device 1 TB plan pending exact approval)

No storage, network, or S3 benchmark was run. The 512 GB NVMe reports 941
`Media and Data Integrity Errors` and is quarantined; the revised storage boundary uses only the
1 TB NVMe split 50:50 for `/srv/librefs` and `/srv/applications`. Benchmarking waits for the
single-device approval and then exercises the 1 TB tier or approved off-host peers only.

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

| Intended role | Sanitized result |
|---|---|
| 1 TB libreFS + applications tier (revised) | SMART overall passed; critical warning 0; media errors 0; 13% used; 100% spare; pending single-device approval |
| quarantined 512 GB | SMART overall passed; critical warning 0; **media/data-integrity errors 941**; 3% used; available spare 91%; firmware VC400618 has no verified official updater |

An overall SMART `PASSED` result does not override the non-zero media/data-integrity error count.
The 512 GB device stays quarantined/unmounted/excluded. No device was partitioned, formatted,
mounted, or benchmarked.

## Tuning result

Retained tuning changes: none.  
Reverted tuning changes: none.  
Aggregate 20 Gb/s claim: not made.

## Resume criteria

1. Obtain the exact single-device 1 TB by-id identity, signatures, plan digest, and
   `PARTITION_LAYOUT=50% LIBREFS + 50% APPLICATIONS` approval per `DESIGN-AND-PLAN.md`.
2. Provision and verify both 1 TB partitions through the storage gate; Docker and containerd remain
   on the OS disk.
3. Run the network and S3 matrices in `DESIGN-AND-PLAN.md`, one tuning change at a time.
4. Without an off-host backup and tested restore, final status cannot exceed
