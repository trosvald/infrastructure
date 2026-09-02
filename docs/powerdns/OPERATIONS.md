# PowerDNS Operations

Run host commands on c0 as `monosense@10.25.10.20` with `sudo docker`. Resolve containers through
Compose labels when scripting; generated container names are shown only for concise interactive
examples.

## Health and authoritative queries

```sh
sudo docker ps -a \
    --filter label=com.docker.compose.project=powerdns-c0
sudo docker exec powerdns-c0-powerdns-1 pdns_control rping

dig @10.25.13.33 monosense.io SOA
dig @10.25.13.33 10.25.10.in-addr.arpa SOA
dig @10.25.13.33 11.25.10.in-addr.arpa SOA
dig @10.25.13.33 12.25.10.in-addr.arpa SOA
dig @10.25.13.33 13.25.10.in-addr.arpa SOA
dig @10.25.13.33 c0.monosense.io A
dig @10.25.13.33 -x 10.25.11.11
dig @10.25.13.33 -x 10.25.12.123
dig +tcp @10.25.13.33 vault.monosense.io A
dig @10.25.13.33 example.com A
```

The private answers must carry the authoritative (`aa`) flag. `example.com` must be refused because
PowerDNS is not a recursive resolver.

Confirm that the project exposes no host ports and only owns `.33`:

```sh
sudo docker port powerdns-c0-powerdns-1
sudo docker network inspect c0_services
```

The PowerDNS API and web server are disabled. TCP `8081` must refuse connections.

## Record changes

Git owns every canonical zone name. ExternalDNS is the only dynamic writer and may own only
TXT-marked `A`, `AAAA`, and `CNAME` RRsets below `monosense.io`. Use this workflow for canonical
changes:

1. Edit the applicable canonical files under `docker/c0/powerdns/zones/`.
2. Update every changed SOA serial. If the execution UTC date is later than the serial's
   `YYYYMMDD`, use `YYYYMMDD01`; otherwise increment its two-digit `NN`. Never decrease or reuse a
   serial.
3. Run `just docker validate-c0`, `just scan-secrets`, and
   `actionlint .github/workflows/docker.yaml`.
4. Commit and push the reviewed change to `main`.
5. Wait for Doco-CD to report a successful PowerDNS deployment.
6. Verify direct UDP and TCP A/PTR answers at `10.25.13.33`.
7. Create and verify a post-change encrypted online backup.

Do not add public Cloudflare records, DNSKEY/DS records, ACME challenges, or ExternalDNS-owned
records to the canonical files. Provision the shared RFC2136 credential once with
`just provision-powerdns-dynamic-dns`; it writes only the exact c0 PowerDNS and Kubernetes
ExternalDNS OpenBao records. Reconciliation validates and preserves only RRsets carrying the exact
`external-dns-internal` TXT owner marker. It rejects any dynamic name that collides with a
canonical Git name, then atomically replaces both the SQLite database and Lua update policy.
Unowned manual `pdnsutil` or SQL changes are emergency-only and disappear at the next deployment.
The PowerDNS API and web server remain disabled and are not mutation paths.

## Doco-CD deployment and rollback

Doco-CD polls `origin/main` every three minutes. The read-only zone and script bind sources belong
to both `zone-reconcile` and `powerdns`, so a changed canonical input recreates both services. A
successful deployment leaves `data-init` and `zone-reconcile` exited with code zero and `powerdns`
healthy.

If reconciliation fails before the atomic rename:

1. Stop `doco-cd` to prevent polling recreation.
2. Run `docker compose down` for the `powerdns-c0` project without `-v`.
3. Preserve `powerdns-data`; never delete it to solve a reconciliation failure.
4. Confirm no `pdns.sqlite3.tmp` or `dnsupdate-policy.lua.tmp` candidate remains.
5. Correct, validate, commit, and push the repository change.
6. Restart the existing `doco-cd` container and verify its next poll succeeds.

If the atomic replacement completed but DNS behavior is wrong, keep Doco-CD and PowerDNS stopped,
restore the reviewed pre-change encrypted backup as UID/GID `953:953` mode `0600`, publish the Git
revert, validate the stopped database, then restart. Never restore a running SQLite database.

`delete: false` in Doco discovery does not stop a project. `docker compose down -v` is prohibited.

To stop serving while preserving state, stop the `powerdns` service directly. To remove the Git
project, first stop Doco-CD, publish the removal, and explicitly preserve `powerdns-data` for rollback.

## Resolver boundary

AdGuard Home is intentionally unchanged. Do not add wildcard forwarding as part of routine
PowerDNS operations. Resolver cutover requires a separate plan that inventories public-only names,
adds explicit exceptions, captures AdGuard's existing upstream configuration, and verifies rollback.
