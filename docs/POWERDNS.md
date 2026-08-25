# PowerDNS Authoritative

PowerDNS Authoritative Server runs on c0 as the Doco-CD project `powerdns-c0`. It owns the private,
unsigned `monosense.io` zone at `10.25.13.33` over TCP and UDP port 53.

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

The bootstrap zone contains only:

- `monosense.io. SOA ns1.monosense.io.`
- `monosense.io. NS ns1.monosense.io.`
- `ns1.monosense.io. A 10.25.13.33`
- `vault.monosense.io. A 10.25.13.34`

The source is `docker/c0/powerdns/zones/monosense.io.zone`. The initializer imports it only when
`powerdns-data` has no database. Once initialized, changing the source zone does not mutate the live
database. Follow [Operations](powerdns/OPERATIONS.md) for reviewed record changes.

## Storage and initialization

`powerdns-data` contains `/var/lib/powerdns/pdns.sqlite3`. Every mount uses `nocopy: true`; this is
required because the image contains an empty layer database that must never be copied into the named
volume.

`data-init` establishes UID/GID `953:953` ownership without creating a database. `zone-init` either
atomically creates and validates the initial database or validates the existing database and static
record invariants. Any partial database, integrity failure, missing zone, or missing static record
prevents the server from starting.

The server runs as the image's `pdns` user with all capabilities dropped except `NET_BIND_SERVICE`.
It has no Docker socket, OpenBao mount, API credential, host network, or published port.

See [Operations](powerdns/OPERATIONS.md) and [Backup and restore](powerdns/BACKUP-RESTORE.md).
