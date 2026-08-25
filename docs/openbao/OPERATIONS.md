# OpenBao operations

This runbook covers routine and incident operations of the c0 OpenBao
project. Architectural intent, topology, and TLS design live in
[OPENBAO](../OPENBAO.md); bootstrap and Shamir initialization live in
[BOOTSTRAP](BOOTSTRAP.md); encrypted off-host backup and the destructive
isolated restore proof live in [BACKUP-RESTORE](BACKUP-RESTORE.md); SOPS and
age identity conventions live in [SOPS](../SOPS.md).

## Shell contexts

Every procedure below names the shell in which the command must run. The
three contexts are not interchangeable:

| Context   | Path                      | Shell  | Purpose                                                                                                       |
| --------- | ------------------------- | ------ | ------------------------------------------------------------------------------------------------------------- |
| Mac       | `/bin/zsh`                | `zsh`  | Operator workstation; SSH into c0 or run cross-host probes.                                                   |
| c0        | `/bin/bash` (interactive) | `bash` | Host-level operations; `sudo docker`, `ss`, `systemctl`, `sudo install`.                                      |
| Container | `/bin/sh`                 | `sh`   | Inside any `openbao-c0` container; BusyBox-style `/bin/sh` with no `[[`, no arrays, no `<<<` here-strings.     |

Differences that matter operationally:

- Container `/bin/sh` does not support `<<<` here-strings. Pipe with
  `printf '%s\n' "$value" | …` instead.
- Container `/bin/sh` does not support arrays; use positional parameters
  or `eval`.
- Mac `zsh` globs by default; c0 `bash` does not unless `extglob` is on.
  Quote every pattern and remote expansion explicitly.
- c0 has `ss` and `openssl`. It does not need `lsof`; this document uses
  `ss -ltnH` (numeric, no service lookup, no header noise) for every
  listener check.
- The Mac workstation has no `ss` and no `lsof` for c0's listener
  inventory; all listener checks run inside c0.

When a command is shown without a context label, it runs on c0 inside a
single `ssh` invocation against `monosense@10.25.10.20`. Every multi-line
remote block uses `ssh … 'bash -s'` so the script body is a plain,
readable heredoc on the operator workstation — no nested
`sudo bash -c '\\''` quoting.

## Environment assumptions

The procedures below assume:

- c0 is reachable as `monosense@10.25.10.20`.
- The Doco-CD container is healthy and polling `main` on loopback. `8080`
  is the HTTP API (forwarded from the container's `80`); `9120` is the
  metrics endpoint. Both bind to `127.0.0.1` only; the loopback
  restriction is what keeps the API key off the network.
- `c0_services` is the external Docker network `10.25.13.0/24` with the
  static address `10.25.13.34` reserved for OpenBao.
- The OpenBao project name is `openbao-c0`; container resolution always
  uses Compose labels, never generated names.
- Public DNS intentionally omits `vault.monosense.io`. PowerDNS serves the private record directly
  at `10.25.13.33`, but AdGuard forwarding is disabled. Every external OpenBao probe therefore uses
  `curl --resolve` or `openssl -servername` against `10.25.13.34` so the public chain is verified
  without depending on client resolver configuration.
- The non-root OpenBao image runs as UID `100:1000` and the
  `openbao-data` volume is owned and readable only by that user.
- Manual Shamir 3-of-2 unseal is intentional: every restart requires two
  distinct offline shares.
- The pinned OpenBao image runtime contains only `bao` plus the
  POSIX/`getent` utilities from its base layers; it does **not** carry
  `openssl`, `curl`, or `jq`. Every probe that needs TLS, HTTP, or JSON
  tooling must run on the operator workstation, on c0, or on c1 — never
  inside the OpenBao container.

## Container resolution

Always resolve containers through Docker filters on Compose labels. The
project name is `openbao-c0` and each service has a stable label.
Generated names such as `openbao-c0-openbao-1` are not portable and must
not be hard-coded.

| Target              | Filter                                                                                         |
| ------------------- | ---------------------------------------------------------------------------------------------- |
| OpenBao server      | `label=com.docker.compose.project=openbao-c0 label=com.docker.compose.service=openbao`         |
| Certificate init    | `label=com.docker.compose.project=openbao-c0 label=com.docker.compose.service=certificate-init` |
| Certificate renewer | `label=com.docker.compose.project=openbao-c0 label=com.docker.compose.service=certificate-renewer` |
| Volume init         | `label=com.docker.compose.project=openbao-c0 label=com.docker.compose.service=volume-init`    |

Resolve on the operator workstation over SSH. Resolve exactly one
container ID; never use `head` or generated names:

```bash
ssh monosense@10.25.10.20 'bash -s' <<'EOF'
sudo docker ps \
  --filter label=com.docker.compose.project=openbao-c0 \
  --filter label=com.docker.compose.service=openbao \
  --filter status=running \
  --quiet \
  --no-trunc
EOF
```

The output is exactly one 64-character container ID. Pass it as a
single quoted argument to the next command; this avoids both `head
-n1` and any generated-name pattern. If the filter ever returns more
than one ID, stop: two running containers of the same Compose service
is a contract violation.

## Health and status codes

The public readiness interface is the sole authoritative readiness
signal:

| Interface        | Purpose                        | Reference                              |
| ---------------- | ------------------------------ | -------------------------------------- |
| `/v1/sys/health` | Public readiness probe         | HTTP status code (see table below)     |
| `bao status`     | Operator-facing state dump     | Exit code (see table below)            |

`/v1/sys/health` is the contract. The container healthcheck is an
internal liveness hint; it is not authoritative for readiness.

### `/v1/sys/health` HTTP codes

| HTTP | Meaning                                                                                   | Operator action |
| ---- | ----------------------------------------------------------------------------------------- | --------------- |
| `200` | Active, unsealed, standby `false`, leader elected.                                        | None.           |
| `429` | Standby (replication disabled for this single-node deployment; expected only on a misconfigured node). | Confirm the single-node Raft contract before responding. |
| `472` | Disaster-recovery replication primary (not expected here).                                | Confirm scope; should not occur on c0. |
| `473` | Replication secondary (not expected here).                                                | Confirm scope.  |
| `501` | Not initialized.                                                                          | Initialize once; see [BOOTSTRAP](BOOTSTRAP.md). |
| `503` | Sealed.                                                                                   | Unseal with two shares; see [BOOTSTRAP](BOOTSTRAP.md). |

### `bao status` exit codes

| Exit | Meaning                                                                                  | Operator action |
| ---- | ---------------------------------------------------------------------------------------- | --------------- |
| `0`  | Active and unsealed; leader elected.                                                     | None.           |
| `1`  | Transport error, address unreachable, or unrecoverable startup failure.                  | Investigate logs; do not assume a sealed state. |
| `2`  | Sealed but initialized, **or** uninitialized on first run.                               | Branch on whether the project has been initialized once before. |

`docker inspect <container>` reports a `State.Health.Status` of
`starting`, `healthy`, or `unhealthy`. Treat `unhealthy` as a signal
to investigate; it does not by itself authorize any unseal or restart
action.

## Doco-CD polling

Doco-CD polls `origin/main` every 180 seconds and reconciles any
project whose declared files have changed. Inspect the polling state
and recent runs. The API key never appears in any shell argument or
process list; build a root-only mode-`0600` curl config with the
single-line `header` syntax and pass it via `--config <file>`:

```bash
ssh monosense@10.25.10.20 'sudo bash -s' <<'EOF'
umask 077
config=$(mktemp /tmp/doco-curl.XXXXXX)
trap "rm -f \"\$config\"" EXIT HUP INT TERM
api_secret=$(cat /opt/doco-cd/secrets/api_secret)
printf "header = \"x-api-key: %s\"\n" "$api_secret" > "$config"
chmod 0600 "$config"
curl --silent --show-error --config "$config" \
  http://127.0.0.1:8080/v1/api/runs
EOF
```

The config file is mode `0600`, owned by the root session, and
removed on exit. If the run is consumed as JSON rather than viewed
live, pipe through `jq` and select `openbao-c0`:

```bash
… | jq '.[] | select(.project == "openbao-c0")'
```

`127.0.0.1:8080` is the HTTP API; `127.0.0.1:9120` is the metrics
endpoint. Both bind to loopback only.

A successful `openbao-c0` run reports:

- `decrypt: acme.env` and `decrypt: cloudflare.ini` both succeeded.
- `deploy: openbao-c0` reconciled all four services without
  re-creating persistent volumes.
- ACME staging then production issuance completed and the certificate
  generation was switched.

If decryption fails:

1. Confirm `/opt/doco-cd/secrets/sops_age_key` exists, is owned
   `root:root`, and is mode `0600`.
2. Confirm the root `.sops.yaml` lists exactly the three approved
   public recipients (`age1DEVELOPER…`, `age1C0_DOCO…`,
   `age1OFFLINE_RECOVERY…`).
3. Restart the Doco-CD container; the age identity is loaded once at
   start and cached in process memory:

    ```bash
    ssh monosense@10.25.10.20 'sudo docker restart doco-cd'
    ```

If ACME fails, see
[ACME staging and production](#acme-staging-and-production). If the
project itself fails to deploy, see
[Post-initialization failure response](#post-initialization-failure-response).

## Container identity and shell

Resolve exactly one running container ID, then open an interactive
shell. All short-lived secrets and tokens stay inside this shell;
nothing is passed through `docker exec -e`, no workstation DNS
override is added, and TLS validation is never disabled:

```bash
id=$(ssh monosense@10.25.10.20 'bash -s' <<'EOF'
sudo docker ps \
  --filter label=com.docker.compose.project=openbao-c0 \
  --filter label=com.docker.compose.service=openbao \
  --filter status=running \
  --quiet \
  --no-trunc
EOF
)
ssh monosense@10.25.10.20 "sudo docker exec -it $id /bin/sh"
```

Inside the container, `vault.monosense.io` resolves through the
Compose `extra_hosts` mapping to `10.25.13.34`. Confirm:

```sh
getent hosts vault.monosense.io
```

The expected answer is `10.25.13.34`. The container shell is
BusyBox `/bin/sh`: there is no `[[`, no here-string, no arrays.
The pinned OpenBao image runtime contains only `bao` and the
POSIX/`getent` utilities from its base layers; it does **not**
carry `openssl`, `curl`, or `jq`. Every probe that needs TLS,
HTTP, or JSON tooling must run on the operator workstation, on
c0, or on c1, not inside the OpenBao container. The examples
below follow that boundary.

## Manual unseal after a restart

After any c0 restart, OpenBao comes up sealed. Verify the state, then
submit two distinct shares. **OpenBao supplies its own hidden
prompt; the share is never an argv argument, an environment variable,
or a file path.** Two interactive `bao operator unseal` commands are
sufficient; each one reads the share into its own prompt buffer:

```sh
bao operator init -status
bao status
bao operator unseal
bao operator unseal
bao status
```

The terminal hides the input at each prompt. The third share stays
offline in its own custody. The OpenBao process never logs a share
and the shell transcript never records one.

`bao status` must report `Sealed: false` and `Standby: false`. The
public readiness probe must return HTTP `200`:

```bash
curl --resolve vault.monosense.io:8200:10.25.13.34 \
  --silent --show-error \
  --output /dev/null --write-out '%{http_code}\n' \
  https://vault.monosense.io:8200/v1/sys/health
```

`200` is the only acceptable code for a steady-state unsealed
OpenBao. See [Health and status codes](#health-and-status-codes) for
every other code.

> **Never** pass a share as a positional argument, an environment
> variable, or a file path. The terminal hides the input; no share
> is ever written to disk, history, logs, or argv.

## Named authorization

Two named userpass identities exist after [BOOTSTRAP](BOOTSTRAP.md):

| Username           | Policy            | Use |
| ------------------ | ----------------- | --- |
| `monosense-admin`  | `admin`           | Mount enable/disable, policy write, audit, KV administration. |
| `monosense-junos`  | `junos-operator`  | Read the two Junos data paths only. |

The `admin` policy grants `["create", "read", "update", "patch",
"delete", "list", "sudo"]` on `path "*"`. The `junos-operator`
policy grants `read` on exactly:

- `kv/data/network/junos/srx1500/netconf`
- `kv/data/network/junos/srx1500/topology`

No metadata, list, or write capability is granted to
`junos-operator`. Junos production records intentionally do not
exist; the two Junos paths are reserved for future writes and the
tests below assert the policy without writing or reading payloads.

The container shell has no `<<<`. Login pipes a hidden read through
`printf` and exports a short-lived `BAO_TOKEN` for the rest of the
session. The password variable is unset as soon as the token is
captured.

### Login as `monosense-admin`

```sh
stty -echo
IFS= read -r BAO_ADMIN_PASSWORD || { stty echo; exit 1; }
stty echo
BAO_TOKEN=$(printf '%s' "$BAO_ADMIN_PASSWORD" | bao write -field=token \
  auth/userpass/login/monosense-admin password=-)
unset BAO_ADMIN_PASSWORD
export BAO_TOKEN
```

Confirm the admin policy grants the operational surface that
follows. Each of the next three commands must exit `0` and return a
non-empty list:

```sh
bao secrets list
bao auth list
bao policy list
```

Expected rows: `kv/` from `secrets list`, `userpass/` from `auth
list`, and both `admin` and `junos-operator` from `policy list`. A
missing row means the named identity is not bound to the policy
declared in `policies/admin.hcl`; rotate the password and re-declare
the policy.

### Login as `monosense-junos`

```sh
stty -echo
IFS= read -r BAO_JUNOS_PASSWORD || { stty echo; exit 1; }
stty echo
BAO_TOKEN=$(printf '%s' "$BAO_JUNOS_PASSWORD" | bao write -field=token \
  auth/userpass/login/monosense-junos password=-)
unset BAO_JUNOS_PASSWORD
export BAO_TOKEN
```

The four `bao token capabilities` calls below are the source of
truth for the Junos policy. The two Junos data paths must each print
exactly `read`. The forbidden path under `network/junos/srx1500/wan`
and the metadata path must each print exactly `deny`:

```sh
bao token capabilities kv/data/network/junos/srx1500/netconf
bao token capabilities kv/data/network/junos/srx1500/topology
bao token capabilities kv/data/network/junos/srx1500/wan
bao token capabilities kv/metadata
```

The first two must return `read`. The third and fourth must return
`deny` (single word, not `denied`). Anything else means the policy
does not match `policies/junos-operator.hcl`; re-declare the policy
and rotate the password.

A real denial round-trip complements the capability probe. The
`platform/forbidden` path is not in any policy; running `bao read`
against it from inside the OpenBao container returns
`permission denied`:

```sh
bao read kv/data/platform/forbidden
```

OpenBao returns this as HTTP `403 permission denied` with an empty
response. Any other body — a payload, a partial field, an HTML error
— means the policy is too permissive or the path is mounted under a
different engine; investigate before allowing the identity to remain
in service.

The Junos consumer at `ansible/junos/scripts/with-openbao-runtime.sh`
performs the same two `bao kv get -mount=kv` calls against `netconf`
and `topology`; no other path is exercised by Junos automation. The
consumer's wrapper script is the source of truth for which paths
the automation touches; this runbook is the source of truth for what
the policy allows.

When the named session is finished, unset the token and the
variable:

```sh
unset BAO_TOKEN
```

> **Important:** Use `bao write … password=-` (pipe from stdin) so
> the password never appears in shell history, process listings, or
> audit arguments. `bao login` is not used because userpass is the
> only enabled auth method.

## ACME staging and production

The `certificate-init` service runs Certbot under the pinned
`certbot/dns-cloudflare:v5.7.0` image. The exact issuance command
is in [OPENBAO](../OPENBAO.md) and is run only on first deployment.
Re-issuance is the renewer's responsibility.

### Staging-only verification

The renewer's `dry-run` flow exercises the same DNS-01 plumbing as
a real renewal, but against Certbot's staging directory and the
Let's Encrypt **staging** environment. Cloudflare receives the
staging TXT record, the CA validates it, and Certbot removes the TXT
record immediately afterward. The renewer **does not** invoke the
deploy hook, so the installer is **not** called, the TLS volume is
**not** switched, and the served certificate is unchanged.

Run it inside the renewer container (the renewer is the service
that owns `renew_certificate.sh`):

```bash
id=$(ssh monosense@10.25.10.20 'bash -s' <<'EOF'
sudo docker ps \
  --filter label=com.docker.compose.project=openbao-c0 \
  --filter label=com.docker.compose.service=certificate-renewer \
  --filter status=running \
  --quiet \
  --no-trunc
EOF
)
ssh monosense@10.25.10.20 "sudo docker exec -it $id /usr/local/bin/renew_certificate.sh dry-run"
```

Successful output ends with `Congratulations, all simulated
renewals succeeded` and contains no `deploy-hook` line. The renewal
lock file at `/run/certbot/renew.lock` blocks any other invocation
while this runs, so the renewal loop does not double-fire.

Verify the staging TXT record is gone and the production generation
is unchanged. The `dig` and the renewal-health check both run on
c0; they use `bash` heredocs against `ssh` like every other
multi-line remote block in this runbook:

```bash
ssh monosense@10.25.10.20 'bash -s' <<'EOF'
printf '_acme-challenge.vault.monosense.io TXT: '
dig +short TXT _acme-challenge.vault.monosense.io @1.1.1.1 || true
printf '\n'
EOF

id=$(ssh monosense@10.25.10.20 'bash -s' <<'EOF'
sudo docker ps \
  --filter label=com.docker.compose.project=openbao-c0 \
  --filter label=com.docker.compose.service=openbao \
  --filter status=running \
  --quiet \
  --no-trunc
EOF
)
ssh monosense@10.25.10.20 "sudo docker exec $id python3 /usr/local/bin/install_certificate.py check \
  --target /openbao/tls/current \
  --hostname vault.monosense.io \
  --min-valid-days 21"
```

Both checks together prove the staging cycle cleaned up after
itself: empty TXT output and a healthy `check` against the existing
production generation.

### Production renewal signal

The renewer invokes `renew_certificate.sh renew` once every 12
hours, which runs:

```text
certbot renew \
  --non-interactive \
  --no-random-sleep-on-renew \
  --deploy-hook 'python3 /usr/local/bin/install_certificate.py install \
    --lineage /etc/letsencrypt/live/vault.monosense.io \
    --target /openbao/tls \
    --hostname vault.monosense.io \
    --reload-pid 1'
```

The deploy hook calls the installer against the existing
production lineage; it never passes staging material to the
installer. The reload signal is `SIGHUP` to PID `1` of the
renewer's shared PID namespace.

### PID namespace verification

The renewer joins `pid: service:openbao`, so PID `1` in the
renewer's namespace is the OpenBao image's PID 1 — `dumb-init`
(the entrypoint wrapper that reaps zombies and forwards signals).
The `bao server` process is one of dumb-init's descendants, not PID
1 itself. A PID-1-only check is not the right test; the namespace is
shared iff a descendant process has the OpenBao server command line.
The renewer image (`certbot/dns-cloudflare:v5.7.0`) ships `cat`,
`grep`, and `tr`, so the renewer can scan its own
`/proc/[0-9]*/cmdline` files directly:

```bash
id=$(ssh monosense@10.25.10.20 'bash -s' <<'EOF'
sudo docker ps \
  --filter label=com.docker.compose.project=openbao-c0 \
  --filter label=com.docker.compose.service=certificate-renewer \
  --filter status=running \
  --quiet \
  --no-trunc
EOF
)
ssh monosense@10.25.10.20 "sudo docker exec $id /bin/sh -c '
  for pid in /proc/[0-9]*; do
    [ -r \"\$pid/cmdline\" ] || continue
    cmd=\$(tr \"\\0\" \" \" < \"\$pid/cmdline\" 2>/dev/null)
    case \"\$cmd\" in
      *bao*server*) printf \"pid=\$(basename \$pid) cmd=%s\\n\" \"\$cmd\" ;;
    esac
  done
'"
```

At least one match must include `bao` and `server` (typically
`pid=3 cmd=/usr/local/bin/bao server -config=/openbao/config ...`).
The exact pid number is not significant; the only requirement is
that `bao server` is reachable inside the renewer's namespace. If
the scan returns no `bao server` match, the namespace is not shared
and the renewer must be redeployed with `pid: service:openbao`
intact. The OpenBao image itself does not carry `cat`, so this
probe runs entirely in the renewer container; only its output
is read on c0.

The renewer healthcheck must also report healthy:

```bash
id=$(ssh monosense@10.25.10.20 'bash -s' <<'EOF'
sudo docker ps \
  --filter label=com.docker.compose.project=openbao-c0 \
  --filter label=com.docker.compose.service=certificate-renewer \
  --filter status=running \
  --quiet \
  --no-trunc
EOF
)
ssh monosense@10.25.10.20 "sudo docker inspect --format '{{json .State.Health}}' $id"
```

`Status: healthy` after the first `start_period: 30s` is the steady
state.

### Atomic reload and serial check

Confirm the installer switched generations and OpenBao picked up
the new material. Run this from the workstation; the renewer
container holds the install script and shares the TLS volume. The
install script's `readlink`/`ls -l` operations run inside the
renewer (which has `python3`):

```bash
id=$(ssh monosense@10.25.10.20 'bash -s' <<'EOF'
sudo docker ps \
  --filter label=com.docker.compose.project=openbao-c0 \
  --filter label=com.docker.compose.service=certificate-renewer \
  --filter status=running \
  --quiet \
  --no-trunc
EOF
)
ssh monosense@10.25.10.20 \
  "sudo docker exec $id /bin/sh -c '\
ls -l /openbao/tls; \
echo ---; \
ls -l /openbao/tls/releases; \
echo ---; \
readlink /openbao/tls/current; \
readlink /openbao/tls/previous 2>/dev/null || true'"
```

Expect:

- The `current` symlink target is `releases/<serial>` where
  `<serial>` is lowercase hexadecimal.
- `previous` is absent after the first install and points to the prior
  generation after a later switch.
- Every generation directory is mode `0755` and owned `root:root`.
- Every `fullchain.pem` is mode `0644` and every `privkey.pem`
  is mode `0600`, both owned `100:1000`.

Compare the released serial on the TLS volume with the serial
OpenBao is actually presenting to TLS clients. The release-side
`readlink` runs in the renewer (the volume is shared). The
handshake-side `openssl s_client` runs on **c0** (or c1), never
inside the OpenBao image, because the image does not carry
`openssl`:

```bash
released_serial=$(ssh monosense@10.25.10.20 'bash -s' <<'EOF'
sudo bash <<'INNER'
renewer=$(sudo docker ps \
  --filter label=com.docker.compose.project=openbao-c0 \
  --filter label=com.docker.compose.service=certificate-renewer \
  --filter status=running \
  --quiet \
  --no-trunc)
sudo docker exec "$renewer" readlink /openbao/tls/current
INNER
EOF
)

served_serial=$(ssh monosense@10.25.10.20 'sudo bash -s' <<'EOF'
openssl s_client \
  -connect 10.25.13.34:8200 \
  -servername vault.monosense.io \
  </dev/null 2>/dev/null \
  | openssl x509 -noout -serial \
  | cut -d= -f2
EOF
)

case "$released_serial" in
  "releases/$served_serial") echo "serial matches" ;;
  *) echo "serial mismatch: released=$released_serial served=$served_serial" ;;
esac
```

The production serial **must be unchanged** across a renewal that
did not actually rotate material (e.g. `--keep-until-expiring`); a
matching serial across a `certbot renew` that reported
`Certificate not yet due for renewal` is the expected steady state.
A mismatch is a containment violation: OpenBao is serving a
serial that is not on the TLS volume. Stop, preserve the volume,
and re-declare the installer.

The OpenBao container logs the `reload triggered` line on a
successful TLS reload. That is the only reload event the runbook
asserts on; do not invent a `serving` log line. Inspect with
`docker logs`:

```bash
id=$(ssh monosense@10.25.10.20 'bash -s' <<'EOF'
sudo docker ps \
  --filter label=com.docker.compose.project=openbao-c0 \
  --filter label=com.docker.compose.service=openbao \
  --filter status=running \
  --quiet \
  --no-trunc
EOF
)
ssh monosense@10.25.10.20 "sudo docker logs --since 10m $id"
```

A missing `reload triggered` line in the last ten minutes of
logs means the SIGHUP did not reach PID `1`; see
[Troubleshooting](#troubleshooting).

### Rollback

If a renewal served a bad generation, switch `current` back to
`previous`. The installer script is mounted read-only in the
renewer container, so run the rollback there (not in the OpenBao
container):

```bash
id=$(ssh monosense@10.25.10.20 'bash -s' <<'EOF'
sudo docker ps \
  --filter label=com.docker.compose.project=openbao-c0 \
  --filter label=com.docker.compose.service=certificate-renewer \
  --filter status=running \
  --quiet \
  --no-trunc
EOF
)
ssh monosense@10.25.10.20 "sudo docker exec $id python3 /usr/local/bin/install_certificate.py rollback \
  --target /openbao/tls \
  --reload-pid 1"
```

The CLI reads the `previous` symlink, validates it stays under
`releases/`, swaps `current` atomically, and only then signals
PID `1`. The served serial must revert to the prior generation on
the next `openssl s_client` probe, run from c0 (the OpenBao image
has no `openssl`).

## Containment and no-host-port checks

OpenBao must not publish a host port. The full inventory of host
listeners and Docker published mappings uses `ss -ltnH` (numeric,
no service lookup, no header):

```bash
ssh monosense@10.25.10.20 'sudo bash -s' <<'EOF'
sudo ss -ltnH
EOF

ssh monosense@10.25.10.20 'sudo bash -s' <<'EOF'
sudo docker ps \
  --filter label=com.docker.compose.project=openbao-c0 \
  --format '{{.Names}}\t{{.Ports}}\t{{.Status}}\t{{.Label "com.docker.compose.service"}}'
EOF
```

The `Ports` column for the `openbao` service must be empty; the
only network attachment is `c0_services` at `10.25.13.34`. Inspect
the resolved container directly:

```bash
id=$(ssh monosense@10.25.10.20 'bash -s' <<'EOF'
sudo docker ps \
  --filter label=com.docker.compose.project=openbao-c0 \
  --filter label=com.docker.compose.service=openbao \
  --filter status=running \
  --quiet \
  --no-trunc
EOF
)
ssh monosense@10.25.10.20 "sudo docker port $id"
```

A non-empty result is a containment violation; stop the affected
container and investigate before continuing. Confirm no host
listener accepts connections on `8200` or `8201`:

```bash
ssh monosense@10.25.10.20 'sudo bash -s' <<'EOF'
if sudo ss -ltnH | awk '{print $4}' | grep -Eq ":(8200|8201)$"; then
  echo "host listener on 8200/8201 found"
  sudo ss -ltnH | awk '{print $4}' | grep -E ":(8200|8201)$"
  exit 1
fi
echo "no host listeners on 8200/8201"
EOF
```

A non-zero exit or any line beginning with `:` followed by `8200`
or `8201` is a containment violation.

## Reachability before resolver cutover

Public DNS for `vault.monosense.io` is intentionally absent. PowerDNS serves the private record
directly, but AdGuard does not forward to it. Every external probe uses `curl --resolve` against
`10.25.13.34` so the public chain is verified independently of client resolver configuration. From
both c0 and c1:

```bash
ssh monosense@10.25.10.20 'sudo bash -s' <<'EOF'
curl --resolve vault.monosense.io:8200:10.25.13.34 \
  --silent --show-error \
  --output /dev/null --write-out '%{http_code}\n' \
  https://vault.monosense.io:8200/v1/sys/health
EOF

ssh monosense@10.25.10.101 'curl --resolve vault.monosense.io:8200:10.25.13.34 \
  --silent --show-error \
  --output /dev/null --write-out "%{http_code}\n" \
  https://vault.monosense.io:8200/v1/sys/health'
```

Pre-initialization the response is HTTP `501` with `initialized:
false`. Post-initialization and unseal the response is HTTP `200`.
Any other code is a deviation from the contract; see
[Health and status codes](#health-and-status-codes).

Confirm the chain is publicly trusted for the SAN
`vault.monosense.io`. The host trust store has the Mozilla CA
bundle installed; one `openssl s_client -verify_return_error`
against the public IP is enough. **This probe runs on c0 (or
c1), not inside the OpenBao container, because the OpenBao image
does not carry `openssl`:**

```bash
ssh monosense@10.25.10.20 'sudo bash -s' <<'EOF'
openssl s_client \
  -connect 10.25.13.34:8200 \
  -servername vault.monosense.io \
  -verify_return_error \
  </dev/null 2>/dev/null \
  | openssl x509 -noout -subject -ext subjectAltName
EOF
```

`Verification: ok` (or a non-zero exit from `openssl s_client`)
and a subject CN or SAN that matches `vault.monosense.io` confirm
the chain. `-verify_return_error` fails fast when the chain does
not validate against the host trust store; do not bypass it.

Confirm the DNS-01 challenge record is cleaned up after issuance.
The TXT record `_acme-challenge.vault.monosense.io` must return
no records:

```bash
ssh monosense@10.25.10.20 'bash -s' <<'EOF'
printf '_acme-challenge TXT: '
dig +short TXT _acme-challenge.vault.monosense.io @1.1.1.1 || true
printf '(empty above means clean)\n'
EOF
```

A non-empty result means Certbot did not remove the challenge and
the renewal will eventually fail; investigate before the next
renewal window. The renewer's `dry-run` flow must not leave this
TXT record either.

## Audit inspection

Audit is configured declaratively in [OPENBAO](../OPENBAO.md) and
emits to stdout in JSON. The OpenBao audit log format has exactly
two event types, **not** a `type:"audit"` envelope:

| Event type | Meaning |
| ---------- | ------- |
| `request`  | One entry per incoming HTTP request. Emitted before the handler runs. |
| `response` | One entry per outgoing HTTP response. Emitted after the handler returns. |

The `request` and `response` for a single HTTP call are paired by
`request.id` and `request.client_token` (or accessor). Retrieve
recent audit events from the OpenBao container's log driver and
select only the audit envelope types:

```bash
id=$(ssh monosense@10.25.10.20 'bash -s' <<'EOF'
sudo docker ps \
  --filter label=com.docker.compose.project=openbao-c0 \
  --filter label=com.docker.compose.service=openbao \
  --filter status=running \
  --quiet \
  --no-trunc
EOF
)
ssh monosense@10.25.10.20 "sudo docker logs --since 1h $id"
```

Inspect with `jq` on the workstation rather than `grep`-into-tail
on c0. Pipe the captured logs to `jq` and select request/response
pairs. A correct, minimal sanity scan:

```bash
id=$(ssh monosense@10.25.10.20 'bash -s' <<'EOF'
sudo docker ps \
  --filter label=com.docker.compose.project=openbao-c0 \
  --filter label=com.docker.compose.service=openbao \
  --filter status=running \
  --quiet \
  --no-trunc
EOF
)
ssh monosense@10.25.10.20 "sudo docker logs --since 1h $id 2>&1" \
  | jq -c 'select(.type == "request" or .type == "response")' \
  | tail -n 40
```

Sanity checks:

- Every `request` entry has a matching `response` entry with the
  same `request.id`.
- Login events for `auth/userpass/login/monosense-admin` and
  `auth/userpass/login/monosense-junos` appear after each
  authorization exercise.
- A root-token self-revocation emits an `auth/token/revoke-self` event.
- No entry contains a plaintext `secret` accessor with a
  non-empty value. The `wrap_info` block is empty for every event.

Any audit event with a non-empty `secret` accessor, a non-empty
`display_name: acme.email` payload, or a plaintext `password`
field is a configuration error; stop, rotate the credential proven
exposed, and re-declare.

## Controlled c0 reboot

A reboot is the authoritative persistence test for Docker's
restart policy, the renewer's PID sharing, and the
unseal-after-restart contract.

1. Capture baselines before reboot:

    ```bash
    ssh monosense@10.25.10.20 'sudo bash -s' <<'EOF'
    sudo docker ps \
      --filter label=com.docker.compose.project=openbao-c0 \
      --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}\t{{.Label "com.docker.compose.service"}}'
    sudo docker volume ls
    EOF

    ssh monosense@10.25.10.20 'sudo ss -ltnH' > /tmp/c0-listeners-before.txt

    ssh monosense@10.25.10.20 'sudo bash -s' <<'EOF'
    curl --resolve vault.monosense.io:8200:10.25.13.34 \
      --silent --show-error \
      https://vault.monosense.io:8200/v1/sys/health
    EOF > /tmp/c0-openbao-before.json
    ```

2. Reboot c0:

    ```bash
    ssh -t monosense@10.25.10.20 'sudo systemctl reboot'
    ```

3. After c0 returns, wait for Docker to restore Doco-CD and the
   OpenBao services:

    ```bash
    ssh monosense@10.25.10.20 'until sudo docker ps --quiet | grep -q .; do sleep 2; done'

    ssh monosense@10.25.10.20 'sudo bash -s' <<'EOF'
    sudo docker ps \
      --filter label=com.docker.compose.project=openbao-c0 \
      --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}\t{{.Label "com.docker.compose.service"}}'
    EOF
    ```

4. Verify health is sealed HTTP `503`:

    ```bash
    ssh monosense@10.25.10.20 'sudo bash -s' <<'EOF'
    curl --resolve vault.monosense.io:8200:10.25.13.34 \
      --silent --show-error \
      --output /dev/null --write-out '%{http_code}\n' \
      https://vault.monosense.io:8200/v1/sys/health
    EOF
    ```

5. Unseal interactively with two distinct shares (see
   [Manual unseal after a restart](#manual-unseal-after-a-restart)).
6. Confirm HTTP `200`, Raft leader, named logins, and renewer
   health:

    ```bash
    ssh monosense@10.25.10.20 'sudo bash -s' <<'EOF'
    curl --resolve vault.monosense.io:8200:10.25.13.34 \
      --silent --show-error \
      https://vault.monosense.io:8200/v1/sys/health
    EOF

    id=$(ssh monosense@10.25.10.20 'bash -s' <<'EOF'
    sudo docker ps \
      --filter label=com.docker.compose.project=openbao-c0 \
      --filter label=com.docker.compose.service=certificate-renewer \
      --filter status=running \
      --quiet \
      --no-trunc
    EOF
    )
    ssh monosense@10.25.10.20 "sudo docker inspect --format '{{json .State.Health}}' $id"
    ```

7. Compare against baselines; restore any missing volumes or
   listeners before resuming service.

If `/v1/sys/health` returns HTTP `200` after the reboot without
an explicit unseal, OpenBao auto-unsealed — that is a contract
violation. Stop the project, preserve the three named volumes and
the encrypted snapshot, investigate the configuration, and
continue without reinitializing. `bao operator init` is never
repeated: the existing Raft data, the existing Shamir shares, and
the existing issued certificate remain valid.

## Post-initialization failure response

If decryption, ACME issuance, certificate handoff, containment,
or startup fails after [BOOTSTRAP](BOOTSTRAP.md), follow the
recovery procedure below. Volumes and snapshots are preserved;
the project is removed without them; OpenBao is **never**
reinitialized.

1. Build a root-only mode-`0600` curl config with the Doco API
   key and remove it on exit. The key never appears in a shell
   argument or process list. The single-line
   `header = "x-api-key: VALUE"` form is the curl `--config`
   syntax used here:

    ```bash
    ssh monosense@10.25.10.20 'sudo bash -s' <<'EOF'
    umask 077
    config=$(mktemp /tmp/doco-curl.XXXXXX)
    trap "rm -f \"\$config\"" EXIT HUP INT TERM
    api_secret=$(cat /opt/doco-cd/secrets/api_secret)
    printf "header = \"x-api-key: %s\"\n" "$api_secret" > "$config"
    chmod 0600 "$config"
    curl --silent --show-error --config "$config" \
      --request DELETE \
      "http://127.0.0.1:8080/v1/api/project/openbao-c0?volumes=false&images=false"
    EOF
    ```

2. Confirm the three named volumes survived. Inspect the exact
   names because existing volumes may retain the initial project
   label and not match a Compose-label filter:

    ```bash
    ssh monosense@10.25.10.20 'sudo bash -s' <<'EOF'
    sudo docker volume ls \
      --format '{{.Name}}\t{{.Driver}}\t{{.Mountpoint}}'
    sudo docker volume inspect \
      openbao-data openbao-acme openbao-tls \
      --format '{{.Name}}\t{{.CreatedAt}}\t{{.Driver}}\t{{.Mountpoint}}'
    EOF
    ```

    `openbao-data`, `openbao-acme`, and `openbao-tls` are the
    three named volumes declared in
    `docker/c0/openbao/compose.yml`. All three must still exist;
    if any is missing, stop and escalate before continuing.

3. Stop only the host-bootstrap Doco container to prevent the
   next 180 second poll from re-creating the failed project:

    ```bash
    ssh monosense@10.25.10.20 'sudo docker stop doco-cd'
    ```

4. Correct the declarative input in Git (SOPS keys, encrypted
   files, or project YAML); push only after re-running `just
   docker validate-c0` locally.

5. Restart Doco-CD using the exact reviewed Compose file in
   `/opt/doco-cd`. Never `docker run` a freshly typed command,
   never copy or adapt the image reference, never substitute
   paths. The single source of truth for the image, the
   loopback ports, the socket and data mounts, and the secrets
   is `docker/bootstrap/c0/doco-cd/compose.yml`. After any SOPS
   key correction, restart only Doco-CD with both explicit
   secret env vars: the renewer and OpenBao do **not** cache
   the age identity, and `certificate-init` is a one-shot
   service that is not restarted. From c0:

    ```bash
    ssh monosense@10.25.10.20 'sudo bash -s' <<'EOF'
    cd /opt/doco-cd
    sudo env \
      DOCO_CD_API_SECRET_FILE=/opt/doco-cd/secrets/api_secret \
      DOCO_CD_SOPS_AGE_KEY_FILE=/opt/doco-cd/secrets/sops_age_key \
      docker compose up -d
    EOF
    ```

    `DOCO_CD_API_SECRET_FILE` and `DOCO_CD_SOPS_AGE_KEY_FILE`
    resolve the `${DOCO_CD_API_SECRET_FILE:-…}` and
    `${DOCO_CD_SOPS_AGE_KEY_FILE:-…}` defaults declared in the
    reviewed Compose file. They never carry a key inline. The
    `docker compose up -d` form reuses the pinned image and
    the loopback-only `127.0.0.1:8080` / `127.0.0.1:9120`
    port mappings exactly as they are declared.

6. If only the TLS volume needs repair, run `certificate-init`
   through `docker compose` against the Doco-managed
   `doco-cd-data` clone. The Doco container's
   `config_files` label points at the host `/opt/doco-cd`
   Compose file (the Doco bootstrap), **not** the OpenBao
   project; the correct mountpoint is the bound
   `doco-cd-data` volume, which Doco-CD materialises as the
   upstream `/github.com/trosvald/infrastructure` checkout
   inside its container. Resolve the project path, verify the
   Compose file exists, then run the init. The exact project
   name is `openbao-c0`. From c0:

    ```bash
    ssh monosense@10.25.10.20 'sudo bash -s' <<'EOF'
    doco_data=$(sudo docker volume inspect \
      --format '{{.Mountpoint}}' \
      doco-cd-data)
    [ -n "$doco_data" ] || { echo "doco-cd-data volume missing"; exit 1; }
    project="$doco_data/github.com/trosvald/infrastructure/docker/c0/openbao"
    [ -f "$project/compose.yml" ] || { echo "compose.yml not at $project"; exit 1; }
    sudo docker compose \
      -p openbao-c0 \
      --project-directory "$project" \
      -f "$project/compose.yml" \
      run --rm certificate-init
    EOF
    ```

    The `run --rm` form re-uses the existing `openbao-data`
    and `openbao-tls` volumes; it does not recreate them, and
    `certificate-init` is not restarted at any other point.

7. Wait for the next poll and confirm the same completion
   checks as [BOOTSTRAP](BOOTSTRAP.md) without rerunning
   `operator init`.

Rotate only the credential proven exposed. The Shamir shares
remain valid across all of the above; the encrypted Raft
snapshot remains valid; the issued certificate remains valid.
**Never** rerun `bao operator init`.

## Troubleshooting

### Compose command argv

Docker Compose treats every list element under `command:` as a
single argv entry that joins with no shell quoting. A single
command line with spaces must be one list element. The
`certificate-init` and `certificate-renewer` services use a
single block-scalar string so every shell command stays in one
argv entry:

```yaml
command:
  - |
    source_credentials=/run/secrets/cloudflare.ini
    install -m 0600 "$source_credentials" /run/certbot/cloudflare.ini
```

If a command is split into multiple list entries, Compose joins
them with spaces but loses the newlines and indentation; the
shell sees one line and fails at the first unquoted space.
Symptom: `install: missing file operand` or
`syntax error: unexpected end of file`. Fix by collapsing every
command back into one block-scalar entry.

### Repeatable `CHOWN`-only data init ordering

`volume-init` is the only service allowed to touch
`/openbao/data`. It runs as `0:0`, drops all capabilities, and
adds only `CHOWN`. The exact argv is:

```text
mkdir -p /openbao/data &&
chown 0:0 /openbao/data &&
chmod 0700 /openbao/data &&
chown 100:1000 /openbao/data
```

The last `chown` is required because `mkdir -p` creates the
directory as `root:root` and the subsequent `chmod` does not
change ownership. The ordering is intentional:

1. `mkdir -p` ensures the path exists.
2. `chown 0:0` makes the metadata unambiguous before `chmod`.
3. `chmod 0700` restricts directory traversal to root.
4. `chown 100:1000` transfers ownership to the OpenBao UID so
   the server process can read and write Raft state.

If step 4 is removed or reordered, the OpenBao container fails
to start with `permission denied` on `/openbao/data`. If the
directory becomes group- or world-readable, the OpenBao server
refuses to start because `mlock` semantics require a private
data directory. Re-run `volume-init` (it is one-shot and
idempotent on the ownership invariant) before debugging
further.

### Doco 0644 behavior and 0600 tmpfs handoff

Doco-CD v0.111 decrypts the referenced `.env` and `.ini` files
into its working clone with mode `0644` rooted at the
`/var/lib/docker`-protected clone. The OpenBao
`certificate-init` and `certificate-renewer` services do not
consume that file directly; they copy it to a tmpfs path before
Certbot reads it:

```text
install -m 0600 /run/secrets/cloudflare.ini /run/certbot/cloudflare.ini
```

The tmpfs mount is explicit:

```yaml
tmpfs:
  - /run/certbot:mode=0700
```

The handoff exists because the Doco material lives in a
directory reachable through the root `docker` socket while the
runtime copy lives on a tmpfs visible only to that container,
so it disappears at container exit. Certbot does not accept a
runtime file whose mode is not exactly `0600`, so the explicit
`install -m 0600` is required.

The compose startup check accepts a credential source mode
that falls inside an exact allow list and rejects any mode
outside it. The exact allow list is `400`, `440`, `444`,
`600`, `640`, `644`, and `0640`. A source at `0644` (the Doco
default for a decrypted file) and a source at `0640` are both
accepted and copied to mode `0600` on the tmpfs. Any mode
outside the allow list — for example `0664`, `0666`, `0700`,
`0755`, or anything else — is rejected with
`credential source is writable by group or other` and exits
non-zero before calling `certbot`. The current error text is a
fixed string and does not change to describe the actual mode
that was rejected; a `0700` or `0755` source produces the same
`writable by group or other` message even though it is not
group- or world-writable in the literal sense.

Two distinct symptoms:

- **Source mode outside the allow list** (any mode not in
  `400`, `440`, `444`, `600`, `640`, `644`, `0640`): the
  renewer exits non-zero with `credential source is writable
  by group or other`, even when the literal mode is `0700`,
  `0755`, or any other value that is technically not group- or
  world-writable.
- **Wrong mode in the tmpfs copy** (Certbot's own rule): Certbot
  logs `Could not find credentials file` or
  `The dns_cloudflare_credentials file must be mode 0600`.

### Capability sets on certificate services

The exact capability set for each service is declared in the
Compose file. There is no `no-new-privileges` directive on the
certificate services; the server alone has
`security_opt: [no-new-privileges:true]`. Document each
service separately rather than implying they share a single
contract:

| Service            | `cap_drop` | `cap_add`                          | `security_opt`            |
| ------------------ | ---------- | ---------------------------------- | ------------------------- |
| `volume-init`      | `[ALL]`    | `[CHOWN]`                          | _none_                    |
| `certificate-init` | `[ALL]`    | `[CHOWN, DAC_OVERRIDE]`            | _none_                    |
| `certificate-renewer` | `[ALL]` | `[CHOWN, DAC_OVERRIDE, KILL]`      | _none_                    |
| `openbao`          | `[ALL]`    | _none_                             | `[no-new-privileges:true]`|

#### Why `DAC_OVERRIDE` is required

The OpenBao server runs as `100:1000`. The installer publishes
the new generation owned by `100:1000`, with `privkey.pem` at
mode `0600`. The pinned Certbot image runs as `0:0`; without
`DAC_OVERRIDE`, the root user inside the container cannot read
or write `/openbao/tls/current/privkey.pem` to validate and
atomically replace it. `DAC_OVERRIDE` lets the root process
override those discretionary access checks for the duration of
the certificate handoff. `CHOWN` is still required on the same
services because the installer publishes the new generation as
`100:1000` and the parent directories' ownership transitions
go through `chown(2)`.

#### Why the renewer also needs `KILL`

The renewer and the OpenBao server share a PID namespace via
`pid: service:openbao`. The renewer runs as `0:0`; the OpenBao
server runs as `100:1000`. The deploy hook reloads the server by
sending `SIGHUP` to the OpenBao server process, which is a
descendant of dumb-init's PID 1 in the shared PID namespace
(not PID 1 itself; see [PID namespace verification](#pid-namespace-verification)).

The capability is required even though the renewer is `0:0`
because `cap_drop: [ALL]` rewrites the container's capability
bounding set to empty before `cap_add` re-enables specific
caps. With `KILL` absent from the bounding set, root inside the
container still cannot bypass the kernel's signal-check rules
for cross-UID delivery to the OpenBao process. Killing the
renewer's own `sleep` child does **not** require `KILL`;
signalling a same-UID descendant is permitted by default.
`KILL` does not grant ambient privilege escalation; it only
grants signal delivery to processes the caller would otherwise
be denied by the kernel's signal-check rules. Whether a
capability reaches a child process depends on the namespace and
signal-check boundary rules, not on a blanket exclusion.

The capability list does not imply that the certificate
services may write outside their container. Volume mounts and

### Renewer startup health timing

The renewer's healthcheck is:

```yaml
test:
  - CMD
  - python3
  - /usr/local/bin/install_certificate.py
  - check
  - --target
  - /openbao/tls/current
  - --hostname
  - vault.monosense.io
  - --min-valid-days
  - "21"
start_period: 30s
start_interval: 5s
interval: 5m
timeout: 10s
retries: 3
```

The first healthcheck runs after `start_period: 30s`, then
every `5s` during `start_interval` until first success, then
every `5m`. A failure during the `start_period` window is
normal for the first `30s` after container start while the
renewer copies credentials and starts its `sleep 43200` loop.
After the first successful check, any failure triggers
`retries: 3` at the `5m` interval; three consecutive failures
mark the container unhealthy.

Symptom of misconfiguration: the renewer container enters the
`unhealthy` state within minutes of starting. The likely
cause is that `/openbao/tls/current` does not exist or its
`privkey.pem` is not owned `100:1000`. Re-run
`certificate-init` to repair the TLS volume and confirm
`/v1/sys/health` returns HTTP `200` before debugging further.
A second likely cause is that the renewer entered its
`sleep 43200` window before the installer published the
first generation; `--start-period 30s` plus
`--start-interval 5s` is short enough that the first failure
never persists into the steady-state `5m` interval.

## Daily checklist

- [ ] `bao status` from inside the OpenBao container returns
      exit `0`.
- [ ] `curl --resolve vault.monosense.io:8200:10.25.13.34 https://vault.monosense.io:8200/v1/sys/health`
      from c1 returns HTTP `200`.
- [ ] The renewer container reports `Status: healthy` with
      ≥ 21 valid days remaining.
- [ ] `docker port <openbao>` is empty.
- [ ] `ss -ltnH` on c0 shows no host listener on `8200` or
      `8201`.
- [ ] `dig TXT _acme-challenge.vault.monosense.io` returns no
      records.

## Weekly checklist

- [ ] Inspect Doco-CD run history for `openbao-c0`; confirm
      both decrypt steps succeeded and no `failed` rows
      appear.
- [ ] Run `renew_certificate.sh dry-run` once and confirm
      staging output ends with `Congratulations, all simulated
      renewals succeeded` and no `deploy-hook` line.
- [ ] Inspect audit stdout for `request`/`response` pair
      integrity and the absence of non-empty `secret`
      accessors.
- [ ] Verify all three named volumes still exist and report
      the same `CreatedAt` as the previous week; use
      `docker volume inspect openbao-data openbao-acme openbao-tls`.
- [ ] Verify the encrypted Raft snapshot in
      `$HOME/.local/share/openbao-backups/c0/` matches its
      recorded ciphertext SHA-256; see
      [BACKUP-RESTORE](BACKUP-RESTORE.md).

## Incident response checklist

- [ ] Capture the failing container ID, the failing service
      label, the full `/v1/sys/health` response, and the last
      200 lines of the container's logs.
- [ ] Decide between
      [Post-initialization failure response](#post-initialization-failure-response)
      (preserve volumes) and a controlled c0 reboot (verify
      persistence).
- [ ] If the renewal handoff failed, run
      `renew_certificate.sh dry-run` first to isolate DNS-01
      staging from the installer.
- [ ] If the certificate is invalid or revoked, run
      `install_certificate.py rollback --target /openbao/tls
      --reload-pid 1` in the renewer container before any
      other action.
- [ ] If unseal fails because a share is unavailable,
      escalate before the second share is required; never
      request a third share on a third terminal.
- [ ] After resolution, rotate only the credential proven
      exposed and document the change in `CHANGELOG.md`.

## References

- [OPENBAO](../OPENBAO.md) — architecture, TLS design,
  declarative HCL.
- [BOOTSTRAP](BOOTSTRAP.md) — Shamir initialization, unseal,
  named userpass identities, root-token self-revocation.
- [BACKUP-RESTORE](BACKUP-RESTORE.md) — encrypted Raft
  snapshot workflow and the destructive isolated c1 restore
  proof.
- [SOPS](../SOPS.md) — workstation identity, offline
  recovery, and SOPS recipient maintenance.
