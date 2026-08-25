# PowerDNS Backup and Restore

The authoritative state is SQLite at `/var/lib/powerdns/pdns.sqlite3` in named volume
`powerdns-data`. Never copy or rsync the live database. Use SQLite's online backup command while the
server is running.

## Online backup

1. Generate a UTC name: `powerdns-c0-YYYYMMDDTHHMMSSZ.sqlite3`.
2. Resolve the single running `powerdns-c0` PowerDNS container through Compose labels.
3. Run the backup as the image's `pdns` user:

```sh
sudo docker exec powerdns-c0-powerdns-1 \
    sqlite3 /var/lib/powerdns/pdns.sqlite3 \
    ".backup '/var/lib/powerdns/powerdns-c0-YYYYMMDDTHHMMSSZ.sqlite3'"
sudo docker exec powerdns-c0-powerdns-1 \
    sqlite3 /var/lib/powerdns/powerdns-c0-YYYYMMDDTHHMMSSZ.sqlite3 \
    'PRAGMA integrity_check;'
```

The integrity result must be exactly `ok`. Record the plaintext SHA-256 and PowerDNS version without
copying plaintext to the workstation.

Stream the backup over SSH directly into workstation `age`. Encrypt to the reviewed SOPS age
recipients from `.sops.yaml`; never derive or print private identities. Store ciphertext and a
mode-`0600` sidecar under mode-`0700`
`$HOME/.local/share/powerdns-backups/c0/`. The sidecar records:

- backup name and UTC timestamp;
- PowerDNS version;
- plaintext SHA-256;
- ciphertext SHA-256.

After ciphertext verification, remove the plaintext backup from c0. The live database remains.

## Isolated restore proof

Use c1 only after capturing its complete container, volume, network, listener, and published-port
baseline. The test must not attach to a SERVICES network.

1. Create a mode-`0700` temporary directory on c1.
2. Decrypt the ciphertext with the c1 recovery identity and require the plaintext checksum to match
   the sidecar.
3. Create a temporary named volume and install the stopped database as UID/GID `953:953`, mode
   `0600`; the volume directory is UID/GID `953:953`, mode `0750`.
4. Start the reviewed image in project `powerdns-restore-test` with the API disabled and only
   loopback mappings `127.0.0.1:15353 -> 53` for TCP and UDP.
5. Query SOA, NS, `ns1`, `vault`, and every additional static record over UDP and TCP. Require
   authoritative NXDOMAIN for an absent in-zone name and refusal for an unrelated recursive query.
6. Run `PRAGMA integrity_check` and `pdnsutil zone check monosense.io` inside the test container.
7. Stop the project and remove its containers, temporary network, temporary volume, plaintext,
   staged ciphertext, configuration, and tooling. The c1 inventories must exactly match baseline.

Retain only the workstation ciphertext and sidecar.

## Production restore

A production restore is a stopped operation:

1. Stop Doco-CD and the PowerDNS project without deleting `powerdns-data`.
2. Create a fresh online backup of the current database if it remains readable.
3. Decrypt the selected backup into a protected temporary file on c0 and verify its checksum before
   touching the volume.
4. Preserve the failed database under a distinct name in the volume; do not overwrite it in place.
5. Install the restored database atomically as UID/GID `953:953`, mode `0600`.
6. Run SQLite integrity and `pdnsutil zone check` in a stopped temporary container using the same
   pinned image.
7. Start the project, require healthy status, and repeat direct UDP/TCP authoritative queries.
8. Remove every plaintext staging file, then restart Doco-CD and require a successful poll.

Never run `docker compose down -v`, never seed a second bootstrap database over `powerdns-data`, and
never restore by raw-copying a database while PowerDNS is running.
