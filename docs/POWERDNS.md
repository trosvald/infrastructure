# PowerDNS Authoritative

PowerDNS Authoritative Server runs on c0 as the Doco-CD project `powerdns-c0`. It owns the private,
unsigned `monosense.io` forward zone and reverse zones for `10.25.10.0/24` through
`10.25.13.0/24` at `10.25.13.33` over TCP and UDP port 53.

## Current scope

The deployment is authoritative-only:

- PowerDNS Recursor is not deployed.
- The HTTP API and web server are disabled.
- No host port is published; DNS is reachable only through the static `c0_services` IPvlan address.
- AdGuard Home remains unchanged and does not forward `monosense.io` to PowerDNS.
- Kubernetes and ExternalDNS integration are not deployed.
- Public Cloudflare authority is unchanged.

Until a separately reviewed resolver cutover, query PowerDNS explicitly with `dig @10.25.13.33`.
Normal clients continue using AdGuard Home at `10.25.10.100` and do not consume this private zone.

## Zone contents

Five canonical files under `docker/c0/powerdns/zones/` contain the complete private authoritative
dataset:

- `monosense.io`: `c0`, `c1`, `adguard`, `k1` through `k5`, `ns1`, and `vault`
- `10.25.10.in-addr.arpa`: PTRs for `c0`, `adguard`, and `c1`
- `11.25.10.in-addr.arpa`: PTRs for `k1` through `k5`
- `12.25.10.in-addr.arpa`: SOA and NS only; unknown HOME addresses return authoritative NXDOMAIN
- `13.25.10.in-addr.arpa`: PTRs for `ns1` and `vault`

Only repository-known stable infrastructure receives records. Gateways, IPvlan shims, DHCP clients,
and HOME devices remain unnamed until a stable mapping is reviewed. AdGuard does not forward these
zones, so clients do not consume them without a separate resolver cutover.

## Storage and reconciliation

`powerdns-data` contains `/var/lib/powerdns/pdns.sqlite3`. Every mount uses `nocopy: true`; this is
required because the image contains an empty layer database that must never be copied into the named
volume.

Git is the only writable source of truth. On every changed PowerDNS project deployment,
`zone-reconcile` validates the current database, builds a new SQLite candidate from the five
canonical files and the packaged schema, checks zone, metadata, record, and SQLite invariants, then
atomically renames the candidate over the live path. This full replacement removes out-of-band
`pdnsutil`, SQL, API, or UI changes. A failed candidate remains as `pdns.sqlite3.tmp` and leaves the
current database unchanged for diagnosis.

`data-init` establishes UID/GID `953:953` ownership without creating a database. A corrupt current
database or partial candidate blocks reconciliation and prevents PowerDNS from starting.

The server runs as the image's `pdns` user with all capabilities dropped except `NET_BIND_SERVICE`.
It has no Docker socket, OpenBao mount, API credential, host network, or published port.

See [Operations](powerdns/OPERATIONS.md) and [Backup and restore](powerdns/BACKUP-RESTORE.md).
