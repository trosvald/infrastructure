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
dig @10.25.13.33 monosense.io NS
dig @10.25.13.33 ns1.monosense.io A
dig @10.25.13.33 vault.monosense.io A
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

The committed zone file is bootstrap input, not a recurring source of truth. After first
initialization, use `pdnsutil` against the persistent database and update the repository bootstrap
zone in the same reviewed change so disaster recovery retains required static records.

Example workflow:

```sh
sudo docker exec powerdns-c0-powerdns-1 \
    pdnsutil rrset replace monosense.io vault.monosense.io A 300 10.25.13.34
sudo docker exec powerdns-c0-powerdns-1 \
    pdnsutil zone check monosense.io
```

Increment the SOA serial for every live zone change. Use UTC `YYYYMMDDNN`; `NN` starts at `01` and
increases for additional changes that day. Do not add public Cloudflare records, DNSKEY/DS records,
ACME challenges, or Kubernetes-owned records to this standalone zone.

Create an online backup before every live mutation. See
[Backup and restore](BACKUP-RESTORE.md).

## Doco-CD deployment and rollback

Doco-CD polls `origin/main` every three minutes. Publish reviewed changes before expecting a c0
reconciliation. A successful deployment leaves `data-init` and `zone-init` exited with code zero and
`powerdns` healthy.

If deployment fails:

1. Stop `doco-cd` to prevent polling recreation.
2. Run `docker compose down` for the `powerdns-c0` project without `-v`.
3. Preserve `powerdns-data`; never delete it to solve an initializer failure.
4. Correct, validate, commit, and push the repository change.
5. Restart the existing `doco-cd` container and verify its next poll succeeds.

`delete: false` in Doco discovery does not stop a project. `docker compose down -v` is prohibited.

To stop serving while preserving state, stop the `powerdns` service directly. To remove the Git
project, first stop Doco-CD, publish the removal, and explicitly preserve `powerdns-data` for rollback.

## Resolver boundary

AdGuard Home is intentionally unchanged. Do not add wildcard forwarding as part of routine
PowerDNS operations. Resolver cutover requires a separate plan that inventories public-only names,
adds explicit exceptions, captures AdGuard's existing upstream configuration, and verifies rollback.
