# c1 Performance Baseline

Date: 2026-08-26  
Status: `BLOCKED`

No storage, network, or S3 benchmark was run. The intended 512 GB libreFS NVMe reports 941
`Media and Data Integrity Errors`. This is an immediate storage-health stop condition; benchmarking
or formatting that device would create load without establishing that it is safe for object data.

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
| 1 TB container/application tier | SMART overall passed; critical warning 0; media errors 0; 13% used |
| 512 GB libreFS tier | SMART overall passed; critical warning 0; **media/data-integrity errors 941**; 3% used; available spare 91% |

An overall SMART `PASSED` result does not override the non-zero media/data-integrity error count.
The 512 GB device was not partitioned, formatted, mounted, or benchmarked.

## Tuning result

Retained tuning changes: none.  
Reverted tuning changes: none.  
Aggregate 20 Gb/s claim: not made.  
S3 latency/throughput claims: not made.

## Resume criteria

1. Replace the 512 GB NVMe or obtain independent vendor-backed evidence that explains the error
   count and proves the device safe.
2. Rerun sanitized health, identity, signatures, and storage-plan evidence; discard the current plan
   digest.
3. Obtain the exact storage approval for the remediated hardware.
4. Provision and verify storage, network, OpenBao, Doco, and libreFS through their gates.
5. Run the network and S3 matrices in `DESIGN-AND-PLAN.md`, one tuning change at a time.
