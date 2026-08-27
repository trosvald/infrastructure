# c1 Performance Baseline

Date: 2026-08-26
Status: storage applied successfully on the corrected retry; S3 and performance matrices complete;
off-host libreFS backup verified as unconfigured and unproven (final durability cap remains
`OPERATIONAL_WITHOUT_DURABILITY`). 512 MiB same-host Docker-network S3 baseline measured on
`c1_services` against libreFS: upload 567,957,345 B/s, download 1,863,741,635 B/s; this is local
bridge + storage + application evidence, not external 10 Gb/s proof. Workstation-to-c1 SERVICES
TCP baseline over the actual routed path: sender 113,948,113 bit/s, receiver 112,622,607 bit/s
for 256 MiB; the path and workstation are the limiting factor, not LACP capacity. No tuning
change is justified by this evidence. The off-host libreFS backup check confirmed that Doco
manages only `doco-cd-c1` and `librefs-c1`; no libreFS backup service, project, or target
exists (only the Debian `dpkg-db-backup` units). No restore was possible. Remaining live
gates are approved reboot persistence and optional separately approved bond-member failover.

## Pre-change evidence retained

- c1 management remains on the independent 1 Gb/s `eno1` path.
- Both 10 Gb/s bond members were up, synchronized, collecting, distributing, and in the same LACP
  aggregator during read-only discovery.
- Bond policy remains 802.3ad, fast LACP, `layer3+4`; one flow is limited to one member.
- `bond0` remains MTU 1500 and VLAN 2513 remains MTU 1496.
- `fio`, `iperf3`, `sysstat`, `ethtool`, `nvme-cli`, and `smartmontools` were installed for the
  reviewed future matrix.
- Synthetic probe artifacts were cleaned; no benchmark artifacts remain on disk.

## Storage-health gate

| Intended role | Sanitized result |
|---|---|
| 1 TB libreFS + applications tier (applied) | SMART overall passed; critical warning 0; media errors 0; 13% used; 100% spare; two XFS partitions mounted `defaults,noatime` (`c1_librefs` at `/srv/librefs`, `c1_apps` at `/srv/applications`) |
| quarantined 512 GB | SMART overall passed; critical warning 0; **media/data-integrity errors 941**; 3% used; available spare 91%; firmware VC400618 has no verified official updater |

An overall SMART `PASSED` result does not override the non-zero media/data-integrity error count.
The 512 GB device stays quarantined/unmounted/excluded and is not used by this mission.

## Tuning result

Retained tuning changes: none.  
Reverted tuning changes: none.
Aggregate 20 Gb/s claim: not made.
S3 latency/throughput claims: as measured below (local bridge + storage + application, not external 10 Gb/s proof).

## S3 matrix results (libreFS via `c1_services`)

A scoped non-root S3 probe used the pinned
`quay.io/minio/mc@sha256:a7fe349ef4bd8521fb8497f55c6042871b2ae640607cf99d9bede5e9bdf11727`
on `c1_services`, created a temporary bucket, user, and policy limited to `GetBucketLocation`,
`ListBucket`, and `Get/Put/DeleteObject` for that bucket only. The probe passed ready, upload,
stat, download, checksum, and delete, and proved unauthorized bucket creation denied.
Synthetic artifacts cleaned. 512 MiB same-host Docker-network S3 baseline: upload
567,957,345 B/s, download 1,863,741,635 B/s. This is local bridge + storage + application
evidence, not external 10 Gb/s proof.

## Network transport matrix results

Workstation-to-c1 SERVICES TCP baseline over the actual routed path: sender 113,948,113 bit/s,
receiver 112,622,607 bit/s for 256 MiB. The path and workstation are the limiting factor, not
LACP capacity; no tuning change is justified by this evidence. One flow is expected on one
member; aggregate 20 Gb/s is claimed only when measured traffic is spread across both members and
peers can source/sink it.

## Off-host libreFS backup check

The off-host check confirmed that Doco manages only `doco-cd-c1` and `librefs-c1`; no libreFS
backup service, project, or target exists on c1 (only the Debian `dpkg-db-backup` units). No
restore was possible. Final durability cap remains `OPERATIONAL_WITHOUT_DURABILITY`.

## Resume criteria

1. Obtain explicit approved reboot persistence evidence (full reboot + every persistence path
   re-verified).
2. If a separate operator grant is given, run an optional bond-member failover drill and
   record counter evidence; do not change `bond-min-links`.
3. Storage, network, OpenBao, live Doco reconciliation, credential rotation leakage,
   S3/performance matrices, and the off-host backup check are closed for the current mission
   state. The mission is not marked complete until reboot persistence is approved and proved.
