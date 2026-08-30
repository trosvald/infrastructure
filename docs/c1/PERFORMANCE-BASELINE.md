# c1 Performance Baseline

Date: 2026-08-26
Status: mission live gates complete; final status `OPERATIONAL_WITHOUT_DURABILITY` solely because
no off-host libreFS backup target/restore exists on c1 (no durability claim). User approved
controlled c1 reboot; outage and SSH recovery observed. Post-reboot verification passed on both
XFS noatime mounts and assertion units, Docker, c1 SERVICES network/shim, exact management
default route, active-backup bond/VLAN with two 10 Gb members and zero link-failure counts,
Doco/OpenBao token/controller canaries, healthy pinned `librefs-c1` at `.65` with no host ports and
credential files UID/GID 1000 mode 0400. Exact-value leakage and writable-root containment
scans passed again after reboot. S3 and performance matrices complete: pre-reboot 512 MiB
same-host Docker-network S3 baseline on `c1_services` against libreFS — upload
567,957,345 B/s, download 1,863,741,635 B/s (local bridge + storage + application evidence,
not external 10 Gb/s proof); post-reboot confirmation 512 MiB — upload 542,280,200 B/s,
download 2,014,577,014 B/s (not a replacement of the baseline). Workstation-to-c1 SERVICES TCP
baseline over the actual routed path: sender 113,948,113 bit/s, receiver 112,622,607 bit/s for
256 MiB; the path and workstation are the limiting factor, not LACP capacity. No tuning change
is justified by this evidence. The off-host libreFS backup check confirmed that Doco manages
only `doco-cd-c1` and `librefs-c1`; no libreFS backup service, project, or target exists
(only the Debian `dpkg-db-backup` units). No restore was possible. User explicitly skipped
optional bond-member failover; record intentionally not exercised, not a blocker. PR8 merged at
`599fff0e01301d77f5a2e204bac5df9a519f1823` and the reviewed helper
`docker/c1/.host/openbao/rematerialize-librefs-credentials.sh` is installed `root:root` mode
0755 on c1. No remaining live gates.
Correction: c1 `bond0` is active-backup and has never been LACP. Any LACP, hashing, aggregator, or
aggregate-capacity statement below is invalid; only the recorded end-to-end throughput is evidence.

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
member; aggregate 20 Gb/s is claimed only when measured traffic is spread across both members
and peers can source/sink it.

1. Mission live gates are complete. Optional future work, on a separate operator grant only:
   run a bond-member failover drill and record counter evidence; do not change `bond-min-links`.
2. Configure, approve, and prove an off-host libreFS backup service, project, and target with a
   successful restore to remove the `OPERATIONAL_WITHOUT_DURABILITY` cap.
