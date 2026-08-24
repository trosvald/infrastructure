# Backup and restore

Disaster recovery for the `openbao-c0` project depends on the documented
Shamir 3-of-2 unseal, the named human identities, and an encrypted Raft
snapshot copied off c0 to operator storage. The backup is produced inside
the running c0 OpenBao service, encrypted locally with `age`, and restored
only on the isolated c1 host so production state is never at risk.

This runbook is destructive by design: the c1 restore uses disposable Shamir
shares and disposable credentials, force-installs the production snapshot,
and tears the entire scratch project down before comparing to a captured
baseline. The backup artifact itself never leaves the operator workstation
plus the offline recovery system.

## Storage boundary

Backup material is operator-local only. Live artifacts are:

| Artifact                                  | Location                                                  | Mode   |
|-------------------------------------------|-----------------------------------------------------------|--------|
| Encrypted snapshot (age-encrypted Raft)   | `$HOME/.local/share/openbao-backups/c0/`                  | `0700` |
| Plaintext SHA-256 sidecar                 | same directory, sibling file                              | `0600` |
| Ciphertext SHA-256 sidecar                | same directory, sibling file                              | `0600` |
| OpenBao version sidecar                   | same directory, sibling file                              | `0600` |
| Scratch Compose project (destructive)     | `/tmp/openbao-restore-test/` on c1                        | `0700` |


Dynamic artifact paths, names, checksums, container IDs, certificate
serials, Shamir shares, tokens, age recipients, and audit log lines
never appear in this document, in commit messages, in chat, or in Git.
Re-run this runbook to obtain current values; do not record them.

## Shell context labels

Each block in this runbook is labeled with the context it runs in. Do
not mix contexts without re-reading the label.

- **Mac** — operator workstation zsh/Bash with `~/.config/sops/age/keys.txt`.
- **c0** — operator workstation session into the production host `c0`
  (`monosense@10.25.10.20`) running Bash.
- **c0 OpenBao container** — `docker exec` shell on the c0 production
  OpenBao service running `/bin/sh`.
- **c1** — operator workstation session into the destructive test host
  `c1` (`monosense@10.25.10.101`) running Bash. The c1 user keeps a
  standard SOPS age identity at `$HOME/.config/sops/age/keys.txt`
  (mode `0600`, owned by the operator); the `age` binary is supplied
  by the workstation's mise toolchain.
- **c1 scratch container** — `docker exec` shell on the isolated c1
  scratch OpenBao service running `/bin/sh`.

## Inputs the procedure assumes

This runbook assumes:

- The OpenBao service described in [OPENBAO.md](../OPENBAO.md) is
  initialized, unsealed, and reachable at `https://vault.monosense.io:8200`.
  Initialization is described in [BOOTSTRAP.md](BOOTSTRAP.md).
- The named identities `monosense-admin` (administrator) and
  `monosense-junos` (least-privilege Junos operator) exist, with passwords
  held in the operator password manager and offline custody as covered in
  [OPERATIONS.md](OPERATIONS.md).
- The SOPS age identities and the offline recovery recipient are
  configured per [SOPS.md](../SOPS.md). The operator workstation identity
  lives at `~/.config/sops/age/keys.txt`. The offline recovery private
  identity lives on the offline recovery system and is never copied to
  the workstation, c0, or c1. The c1 user `monosense` keeps its own
  identity at the same path on c1, scoped to the destructive restore
  proof only.
- c0 hosts the production OpenBao service, listens at `10.25.13.34:8200`,
  and exposes the static `c0_services` network as in [OPENBAO.md](../OPENBAO.md).
- c1 is a clean, destructive test host with no persistent OpenBao service
  and no `127.0.0.1:18200` mapping.
- Docker Engine + Docker Compose are available on c1.

If any assumption fails, stop and resolve before producing a backup.

## Resolve exactly one container

The OpenBao service runs as `com.docker.compose.service=openbao` inside
the `openbao-c0` Compose project. Resolve its container ID with label
filters and stop if more than one ID matches. Do not assume a generated
container name and do not select via `head`.

```sh
# c0
openbao_cid="$(docker ps --no-trunc --quiet \
  --filter label=com.docker.compose.project=openbao-c0 \
  --filter label=com.docker.compose.service=openbao)"
case "$(printf '%s' "$openbao_cid" | wc -l | tr -d ' ')" in
  1) ;;
  *) printf 'expected exactly one OpenBao container, found %s\n' \
       "$(printf '%s' "$openbao_cid" | wc -l | tr -d ' ')" >&2
     unset openbao_cid
     exit 1 ;;
esac
test -n "$openbao_cid"
```

The selected container ID is the only handle the runbook uses to address
the production service.

## Capture the c1 baseline

The destructive restore uses c1 as a clean test target. Capture its full
state before doing anything so the teardown can be verified.

```sh
# c1
# Run as the monosense user; Docker access already works, so $HOME
# resolves to the operator's real identity path.

scratch_root=/tmp/openbao-restore-test
install -d -m 0700 "$scratch_root"
cd "$scratch_root"

docker ps --all --no-trunc                       > baseline-containers.txt
docker volume ls                                 > baseline-volumes.txt
docker network ls                                > baseline-networks.txt
ss -tlnp                                         > baseline-listeners.txt
docker ps --format '{{.Names}} {{.Ports}}' \
  | tee baseline-port-mappings.txt >/dev/null
ls -ld "$scratch_root"
```

The chosen scratch root must be `0700`, owned by the operator, and absent
from any backup or support collection. The post-teardown diff is run from
inside `$scratch_root` before the directory is removed.

## Produce the encrypted snapshot on c0

The backup is generated once on c0 inside the OpenBao container, then
streamed off the host over SSH and encrypted on the Mac workstation.
The snapshot timestamp is generated exactly once on c0 and reused by
Mac; recipients are the developer workstation identity and the
single recovery identity supplied as `$RECOVERY_AGE_RECIPIENT` from
reviewed custody in the repository `.sops.yaml`. Both the plaintext
and ciphertext SHA-256 values are recorded as `0600` sidecar files in
the operator backup directory (dynamic local metadata, never Git).

### Write a non-secret recovery sentinel

Open an interactive shell on the resolved OpenBao container as the
OpenBao runtime user. The shell is the only place where short-lived
credentials exist. `/bin/sh` is the only guaranteed shell in the
pinned OpenBao image; use `stty -echo` with `read` so the password
never echoes to the terminal and the variable never lands in shell
history.

```sh
# c0 OpenBao container
BAO_ADDR=https://vault.monosense.io:8200
export BAO_ADDR

stty -echo
printf 'monosense-admin password: '
read -r admin_password
printf '\n'
stty echo
unset REPLY

export BAO_TOKEN="$(printf '%s' "$admin_password" \
  | bao write -field=token auth/userpass/login/monosense-admin password=-)"
unset admin_password

sentinel="recovery-$(date -u +%Y%m%dT%H%M%SZ)-$$"
bao kv put -mount=kv platform/recovery-proof value="$sentinel"
unset sentinel
```

Leave this shell open; the next step runs in the same shell so the
short-lived `BAO_TOKEN` survives.

### Generate the snapshot name once and save the Raft snapshot

OpenBao writes a Raft snapshot to the configured storage path. The
production storage path is `/openbao/data`, so the snapshot lives
directly beneath that path; it does not require a `raft/snapshots/`
subdirectory. The timestamp used here is the single source of truth
for the backup; the Mac side reuses the exact same value rather than
regenerating it.

```sh
# c0 OpenBao container (continued)
snapshot_name="$(date -u +%Y%m%dT%H%M%SZ).snap"
snapshot_path="/openbao/data/${snapshot_name}"
bao operator raft snapshot save "$snapshot_path"
test -s "$snapshot_path"
```

Print the snapshot name once so the operator can hand it off to the
Mac shell. The Mac cannot reuse the c0 shell variable because each
`docker exec` is a fresh process; the operator types the literal name
into a `snapshot_name='...'` assignment on the Mac.

```sh
# c0 OpenBao container (continued)
printf '%s\n' "$snapshot_name"
```

The c0 container shell now exits. The next steps run on the Mac and
address c0 only through `ssh c0 docker exec`.

### Stream-encrypt on Mac over SSH into c0

On the Mac workstation, the operator pastes the snapshot name printed
by the c0 container shell into a literal shell assignment. The Mac
then resolves the exact production container ID via the same label
filter through SSH, and uses that ID for every subsequent `docker
exec`. The Mac never assumes the c0 shell still has the variable set
and never types the snapshot name into argv by command substitution
through `ssh`.

The recipient list is the developer workstation identity plus the
single recovery identity supplied as `$RECOVERY_AGE_RECIPIENT`
from reviewed custody in the repository `.sops.yaml`. No third
recipient is invented and no recipient is derived over SSH at
runtime.

```sh
# The exact value is nonsecret (a UTC timestamp with .snap suffix).
# Format: YYYYMMDDTHHMMSSZ.snap.
snapshot_name='<copied snapshot name>'
test -n "$snapshot_name"

# ciphertext_name is derived from snapshot_name once and reused by
# every later step that references the encrypted artifact.
ciphertext_name="openbao-c0-${snapshot_name}.age"

workstation_backup_dir="$HOME/.local/share/openbao-backups/c0"
install -d -m 0700 "$workstation_backup_dir"

# Resolve the exact production container ID through SSH into c0
# with the same wc -l guard used elsewhere in the runbook.
openbao_cid="$(ssh monosense@10.25.10.20 \
  docker ps --no-trunc --quiet \
    --filter label=com.docker.compose.project=openbao-c0 \
    --filter label=com.docker.compose.service=openbao)"
case "$(printf '%s' "$openbao_cid" | wc -l | tr -d ' ')" in
  1) ;;
  *) printf 'expected exactly one OpenBao container, found %s\n' \
       "$(printf '%s' "$openbao_cid" | wc -l | tr -d ' ')" >&2
     unset openbao_cid
     exit 1 ;;
esac
test -n "$openbao_cid"

# Obtain the plaintext SHA-256 and the OpenBao version through a
# single `ssh c0 docker exec "$id" ...` invocation each. The values
# live only on the Mac as captured command output; no plaintext
# checksum file or copy is created inside the container.
plaintext_sha="$(ssh monosense@10.25.10.20 \
  docker exec "$openbao_cid" \
    sha256sum "/openbao/data/${snapshot_name}" | awk '{print $1}')"
test -n "$plaintext_sha"

openbao_version="$(ssh monosense@10.25.10.20 \
  docker exec "$openbao_cid" bao version)"
test -n "$openbao_version"

# Stream the snapshot out of c0, through `age` on the Mac, into the
# operator backup directory. Plaintext bytes never touch the Mac
# filesystem: `ssh c0 docker exec cat` pipes raw bytes straight into
# `age`, which writes ciphertext.
ssh monosense@10.25.10.20 \
  docker exec "$openbao_cid" \
    cat "/openbao/data/${snapshot_name}" \
  | age \
      --recipient "$(age-keygen -y "$HOME/.config/sops/age/keys.txt")" \
      --recipient "$RECOVERY_AGE_RECIPIENT" \
      --output "${workstation_backup_dir}/${ciphertext_name}"

# Hash the ciphertext file locally.
ciphertext_sha="$(shasum -a 256 \
  "${workstation_backup_dir}/${ciphertext_name}" \
  | awk '{print $1}')"

# Write one consolidated 0600 sidecar holding every dynamic piece
# of metadata for this run. The sidecar is local dynamic metadata,
# not Git.
sidecar_name="openbao-c0-${snapshot_name}.sidecar"
printf 'snapshot_name=%s\nsnapshot_utc=%s\nopenbao_version=%s\nplaintext_sha256=%s\nciphertext_sha256=%s\n' \
  "$snapshot_name" \
  "${snapshot_name%.snap}" \
  "$openbao_version" \
  "$plaintext_sha" \
  "$ciphertext_sha" \
  > "${workstation_backup_dir}/${sidecar_name}"
chmod 0600 "${workstation_backup_dir}/${sidecar_name}"

ls -ld "$workstation_backup_dir" \
  "${workstation_backup_dir}/${ciphertext_name}" \
  "${workstation_backup_dir}/${sidecar_name}"
```
`$RECOVERY_AGE_RECIPIENT` is the public `age1…` recipient recorded in
the reviewed custody section of the repository `.sops.yaml`. It is
supplied to the operator at runtime and is not stored in this
document. The developer workstation identity is the second recipient;
no third recipient is invented.

The plaintext SHA-256, the ciphertext SHA-256, the OpenBao version,
and the snapshot UTC stamp are written to one consolidated `0600`
sidecar file in `$HOME/.local/share/openbao-backups/c0/`. The values
are local dynamic metadata for this run only; they are not committed
to Git and are not derived again at runtime.

### Remove the remote snapshot

After the ciphertext and sidecar are on disk, remove the remote
snapshot from c0 via `ssh c0 docker exec rm`. The container itself
never holds the plaintext checksum or any sidecar data.

```sh
# Mac
ssh monosense@10.25.10.20 \
  docker exec "$openbao_cid" \
    rm -f "/openbao/data/${snapshot_name}"
ssh monosense@10.25.10.20 \
  docker exec "$openbao_cid" \
    test ! -e "/openbao/data/${snapshot_name}"
# openbao_cid is released (the connection closes) but
# snapshot_name, ciphertext_name, and plaintext_sha are RETAINED
# across the developer proof, the c1 recovery proof, and the
# teardown so the operator can compare computed hashes against
# plaintext_sha. They are unset only at the end of the runbook.
unset openbao_cid openbao_version ciphertext_sha sidecar_name

```

### Delete the production sentinel

Reopen the c0 OpenBao container shell and delete the sentinel using
the same KV v2 CLI form used to write it.

```sh
# c0 OpenBao container
BAO_ADDR=https://vault.monosense.io:8200
export BAO_ADDR

stty -echo
printf 'monosense-admin password: '
read -r admin_password
printf '\n'
stty echo
unset REPLY

export BAO_TOKEN="$(printf '%s' "$admin_password" \
  | bao write -field=token auth/userpass/login/monosense-admin password=-)"
unset admin_password

bao kv delete -mount=kv platform/recovery-proof
unset BAO_TOKEN
exit
```

After exiting, only the ciphertext and the `0600` sidecar remain in
operator storage under `$HOME/.local/share/openbao-backups/c0/`.

## Verify developer decryption (workstation identity)

Before relying on the artifact, decrypt it locally with the developer
identity and confirm the plaintext checksum matches the recorded one.
The plaintext SHA-256 is computed inline by streaming `age --decrypt`
straight into `shasum -a 256`; no plaintext file is ever written to disk
and `shred` is not required because no protected plaintext exists.

```sh
# Mac
# Workstation identity decrypt is a pure stream; plaintext bytes never
# touch disk. The resulting SHA-256 must equal the plaintext_sha value
# captured during snapshot save and recorded in the 0600 sidecar.
age --decrypt \
  --identity "$HOME/.config/sops/age/keys.txt" \
  --output - \
  "${workstation_backup_dir}/${ciphertext_name}" \
  | shasum -a 256 \
  | awk '{print $1}'
```

Compare the displayed value to `$plaintext_sha` (still in scope from
the snapshot-save step) and to the `plaintext_sha256=` line in the
`0600` sidecar. Both values are intentionally not recorded in this
document. If they disagree, treat the artifact as untrustworthy.

## Run the destructive restore drill on c1

The restore proof is destructive, isolated, and runs only on c1.
The c1 user `monosense` keeps its own standard SOPS age identity at
`$HOME/.config/sops/age/keys.txt` (mode `0600`, owned by the
operator); the `age` binary is supplied by the workstation's mise
toolchain.

### Build the isolated scratch Compose project

The scratch project is a real Compose project named
`openbao-restore-test`, not ad-hoc `docker run` invocations. It runs on
the default private bridge, owns a named volume, and exposes only
`127.0.0.1:18200`. The Compose file and the restore HCL live directly
at the scratch root; the HCL is `0644` so the scratch OpenBao runtime
user (UID 100) can read it while the scratch directory itself stays
root-owned `0700`.
The Compose file and the restore HCL live directly at the scratch root;
the HCL is `0644` so the scratch OpenBao runtime user (UID 100) can read
it while the scratch directory itself stays root-owned `0700`.

Prepare the scratch root and switch into it:

```sh
# c1
# Run as the monosense user; Docker access already works.

scratch_root=/tmp/openbao-restore-test
install -d -m 0700 "$scratch_root"
cd "$scratch_root"
```

Write the scratch project files directly at the scratch root:

```sh
# c1
cat > compose.yml <<'YAML'

services:
  volume-init:
    # yamllint disable-line rule:line-length
    image: docker.io/openbao/openbao:2.6.2@sha256:e29524ba7c3f20d01f562c481e3eccbad6c91df45a2f2531433da4951e408cff
    platform: linux/amd64
    user: "0:0"
    network_mode: none
    entrypoint: ["/bin/sh", "-ec"]
    command:
      - >-
        mkdir -p /openbao/data &&
        chown 0:0 /openbao/data &&
        chmod 0700 /openbao/data &&
        chown 100:1000 /openbao/data
    cap_drop: [ALL]
    cap_add: [CHOWN]
    volumes:
      - scratch-data:/openbao/data

  openbao:
    # yamllint disable-line rule:line-length
    image: docker.io/openbao/openbao:2.6.2@sha256:e29524ba7c3f20d01f562c481e3eccbad6c91df45a2f2531433da4951e408cff
    platform: linux/amd64
    user: "100:1000"
    command: server
    depends_on:
      volume-init:
        condition: service_completed_successfully
    cap_drop: [ALL]
    security_opt:
      - no-new-privileges:true
    ports:
      - "127.0.0.1:18200:8200"
    volumes:
      - ./restore.hcl:/openbao/config/openbao.hcl:ro
      - scratch-data:/openbao/data

volumes:
  scratch-data:
    name: openbao-restore-test-data
YAML

cat > restore.hcl <<'HCL'
ui = false
api_addr = "http://127.0.0.1:8200"
cluster_addr = "https://127.0.0.1:8201"

storage "raft" {
  path = "/openbao/data"
  node_id = "c0-openbao-1"
}

listener "tcp" {
  address = "0.0.0.0:8200"
  cluster_address = "127.0.0.1:8201"
  tls_disable = true
}

audit "file" "stdout" {
  description = "Write audit information to standard output."
  options = {
    file_path = "stdout"
  }
}
HCL

chmod 0644 restore.hcl
ls -ld compose.yml restore.hcl
```

Snapshots do not contain listener or audit configuration, so the
scratch HCL supplies them independently. The node ID matches production
so the restored single-node Raft cluster keeps the same identity. TLS is
disabled on the loopback-only listener because the restore proof never
leaves c1 and never traverses any network. The project stays sealed
because it has not been initialized yet.

### Initialize the scratch cluster with disposable credentials

Initialize the empty scratch cluster with disposable Shamir values. The
disposable root token, the disposable shares, and the init/unseal
payloads all live as mode-`0600` JSON inside the protected scratch
root. Keys and tokens never appear on the command line or in
here-strings.

The init POST itself runs over the loopback HTTP path that OpenBao serves
even while sealed, so it goes straight through the published port. The
disposable shares and root token then live only as protected JSON files
used by `curl --data @file` from the c1 host — they never appear in argv
or as here-strings.

```sh
# All scratch credentials live as mode-0600 JSON inside the 0700
# scratch root. Keys and tokens never appear on the command line or
# in here-strings.
init_request="${scratch_root}/init-request.json"
init_response="${scratch_root}/init-response.json"
unseal_request="${scratch_root}/unseal-request.json"
scratch_token_file="${scratch_root}/scratch-root-token"
install -m 0600 /dev/null "$init_request"
install -m 0600 /dev/null "$init_response"
install -m 0600 /dev/null "$unseal_request"
install -m 0600 /dev/null "$scratch_token_file"

# Init request body: single share, threshold 1.
jq -n '{secret_shares:1,secret_threshold:1}' > "$init_request"
chmod 0600 "$init_request"

# Send the init request via --data @file; the response is stored in
# its own 0600 file so the JSON body never sits in argv.
curl --silent --request POST \
  --data @"$init_request" \
  --output "$init_response" \
  http://127.0.0.1:18200/v1/sys/init
test -s "$init_response"
shred -u "$init_request"

# Capture the disposable root token into its own 0600 file.
jq -r '.root_token' "$init_response" > "$scratch_token_file"
chmod 0600 "$scratch_token_file"

# Build a single unseal payload from the first base64 share in the
# init response. The threshold is 1, so a single POST is sufficient.
jq '{key:.keys_base64[0]}' "$init_response" > "$unseal_request"
chmod 0600 "$unseal_request"

# Send the unseal payload via --data @file.
curl --silent --request POST --data @"$unseal_request" \
  http://127.0.0.1:18200/v1/sys/unseal
shred -u "$unseal_request"
```

The scratch cluster is now unsealed with disposable Shamir material.




### Force-restore the production snapshot

`--force` is intentional: the scratch Shamir keys are disposable, so the
leader check that normally blocks a restore must be overridden.

The transfer runs from the Mac workstation: the developer identity
decrypts the artifact as a stream and pipes it into `ssh` on c1, which
writes the protected plaintext directly to the scratch root under a
`umask 077` mask so the file is mode `0600` from the start. The
plaintext does temporarily land on the c1 filesystem at
`/tmp/openbao-restore-test/restoring.snap` (mode `0600`); that is the
required staging point for the subsequent `curl --data-binary` POST.

```sh
# Mac
workstation_backup_dir="$HOME/.local/share/openbao-backups/c0"

age --decrypt \
  --identity "$HOME/.config/sops/age/keys.txt" \
  --output - \
  "${workstation_backup_dir}/${ciphertext_name}" \
  | ssh monosense@10.25.10.101 \
      'umask 077
       cat > /tmp/openbao-restore-test/restoring.snap
       chmod 0600 /tmp/openbao-restore-test/restoring.snap'
```

On c1, verify the staged plaintext SHA-256 against `$plaintext_sha` retained
in the Mac shell and the `plaintext_sha256` field in the mode-`0600` sidecar.
If the comparison fails, stop before any restore POST.

```sh
# c1
sha256sum /tmp/openbao-restore-test/restoring.snap \
  | awk '{print $1}'
```

The displayed SHA-256 must match both recorded values.

Post the raw snapshot to the scratch cluster through a protected
`curl` config. The `X-Vault-Token` header is supplied by the config
file, never by a `--header` argument that would expose the token in
`argv` and `/proc`.

```sh
# c1
scratch_curl_config="${scratch_root}/scratch-curl.conf"
install -m 0600 /dev/null "$scratch_curl_config"
printf 'header = "X-Vault-Token: %s"\n' \
  "$(cat "$scratch_token_file")" > "$scratch_curl_config"
chmod 0600 "$scratch_curl_config"

curl --silent --config "$scratch_curl_config" \
  --request POST \
  --data-binary "@/tmp/openbao-restore-test/restoring.snap" \
  "http://127.0.0.1:18200/v1/sys/storage/raft/snapshot-force"
shred -u /tmp/openbao-restore-test/restoring.snap
```


### Delete scratch credentials

The restored scratch root token is invalid: the force-restore replaced
the root token and Shamir material with production values. Do not
attempt to use, rotate, or revoke it. Delete every scratch credential
file.
```sh
# c1
shred -u "$scratch_token_file" "$init_response" \
  "${scratch_root}/scratch-curl.conf"
unset scratch_curl_config
test ! -e "$scratch_token_file"
test ! -e "$init_response"
test ! -e "${scratch_root}/scratch-curl.conf"
```

The scratch service now requires two production Shamir shares before
any API call can succeed.

### Resolve the scratch container by Compose labels

Resolve exactly one container ID for the scratch `openbao` service with
Compose labels; do not assume a generated name and do not use `head`.

```sh
# c1
scratch_cid="$(docker ps --no-trunc --quiet \
  --filter label=com.docker.compose.project=openbao-restore-test \
  --filter label=com.docker.compose.service=openbao)"
case "$(printf '%s' "$scratch_cid" | wc -l | tr -d ' ')" in
  1) ;;
  *) printf 'expected exactly one scratch container, found %s\n' \
       "$(printf '%s' "$scratch_cid" | wc -l | tr -d ' ')" >&2
     unset scratch_cid
     exit 1 ;;
esac
test -n "$scratch_cid"
```

### Verify with two production shares

Two distinct production shares, held in offline custody, change scratch
health from 503 to 200 and authenticate the verification as
`monosense-admin`.

Production Shamir material must never appear in a shell variable, a
file, or a `curl --data` argument. The shares are typed directly into
`bao operator unseal` inside the scratch container, where OpenBao's own
prompt reads them from the terminal and forwards them straight into the
unseal RPC.

Open the scratch container shell from the c1 host:

```sh
# c1
docker exec -it -u 100:1000 "$scratch_cid" /bin/sh
```

Inside the scratch container, run `bao operator unseal` twice. OpenBao
prints its own `Unseal Key (will be hidden):` prompt; type each
production share and press Enter. The second call returns
`sealed=false`.

```sh
# c1 scratch container
bao operator unseal
# prompt: Unseal Key (will be hidden): <type share 1, press Enter>
bao operator unseal
# prompt: Unseal Key (will be hidden): <type share 2, press Enter>
```

The shares pass through OpenBao's terminal reader into the unseal RPC
and disappear with the process. Do not assign them to a shell variable,
write them to a file, or include them in a `curl` argument. Disposable
scratch Shamir keys from the prior disposable init were used with the
protected-JSON-file pattern; production shares are not.

The OpenBao image does not include `curl` or `jq`. Run the entire
verification from the scratch container using the `bao` CLI only. The
authentication step uses the same hidden `stty -echo` + `read` pattern
as the production initialization; the resulting token is captured into
a short-lived exported `BAO_TOKEN`, then unset after verification. The
repository contract forbids `bao login`, so `BAO_TOKEN` is the only
acceptable transport for the auth token inside the scratch container.

```sh
# c1 scratch container (continued)
BAO_ADDR=http://127.0.0.1:8200
export BAO_ADDR

stty -echo
printf 'monosense-admin password: '
read -r admin_password
printf '\n'
stty echo
unset REPLY

export BAO_TOKEN="$(printf '%s' "$admin_password" \
  | bao write -field=token auth/userpass/login/monosense-admin password=-)"
unset admin_password
```

Run the verification queries through the `bao` CLI. The expected results
are:

| Query                                              | Expected result                                          |
|----------------------------------------------------|----------------------------------------------------------|
| `bao status`                                       | `Sealed=false`, `Initialized=true`                       |
| `bao operator raft list-peers`                     | exactly one peer with `node_id=c0-openbao-1`, leader     |
| `bao kv get -field=value -mount=kv platform/recovery-proof` | exactly the sentinel written in production       |
| `bao policy list`                                  | `admin`, `junos-operator`                                |
| `bao auth list`                                    | `userpass/` enabled                                      |
| stdout audit log                                   | login, policy lookup, mount, recovery-proof read         |

```sh
# c1 scratch container (continued)
bao status
bao operator raft list-peers
bao kv get -field=value -mount=kv platform/recovery-proof
bao policy list
bao auth list
unset BAO_TOKEN
exit
```

## Prove c1 recovery decryption

The recovery proof has two halves: the workstation developer identity
already proved the artifact above. The c1 user identity proves the
artifact can be decrypted by c1's own age identity — the artifact
still originates from workstation transport, but the decryption step
uses only c1's local `$HOME/.config/sops/age/keys.txt`. The encrypted
artifact is staged on c1 only for the duration of this single
comparison and is shredded immediately after.

Copy the encrypted artifact from the Mac workstation backup to a
protected file under the c1 scratch root. The copy originates on the
workstation (which is the only place a complete, multi-recipient
ciphertext exists); c1 only receives ciphertext.

```sh
# Mac
scp "$workstation_backup_dir/${ciphertext_name}" \
  "monosense@10.25.10.101:/tmp/openbao-restore-test/recovery.snap.age"
ssh monosense@10.25.10.101 \
  'chmod 0600 /tmp/openbao-restore-test/recovery.snap.age'
```

Decrypt with the c1 user identity and compute the SHA-256 inline. The
plaintext is destroyed as soon as the checksum is compared; no
plaintext file is ever created on c1.
```sh
# c1
age --decrypt \
  --identity "$HOME/.config/sops/age/keys.txt" \
  --output - \
  /tmp/openbao-restore-test/recovery.snap.age \
  | sha256sum \
  | awk '{print $1}'
shred -u /tmp/openbao-restore-test/recovery.snap.age
test ! -e /tmp/openbao-restore-test/recovery.snap.age
```

The displayed SHA-256 must equal `$plaintext_sha` retained in the Mac shell
and the `plaintext_sha256` field in the local sidecar. After comparison, the
staged ciphertext copy is destroyed on c1; no plaintext file is created by
this independent identity proof.

## Tear down the c1 scratch project

After verification, remove every scratch object and compare the
post-teardown state to the captured baseline. `docker compose down
--volumes --remove-orphans` removes the scratch services, the named
project volume, and the project default-bridge network; no separate
`docker network prune` is needed or safe. The defensive `volume rm`
is conditional on `docker volume inspect` finding the volume, so it
does not fail when Compose has already removed it.

Run the diff from inside the scratch root before any removal so the
baseline and post files exist on disk at the same time.

```sh
# Run as the monosense user; Docker access already works.



cd /tmp/openbao-restore-test

docker compose -f compose.yml down --volumes --remove-orphans
if docker volume inspect openbao-restore-test-data >/dev/null 2>&1; then
  docker volume rm openbao-restore-test-data
fi

docker ps --all --no-trunc                       > post-containers.txt
docker volume ls                                 > post-volumes.txt
docker network ls                                > post-networks.txt
ss -tlnp                                         > post-listeners.txt
docker ps --format '{{.Names}} {{.Ports}}' \
  | tee post-port-mappings.txt >/dev/null

diff -u baseline-containers.txt    post-containers.txt
diff -u baseline-volumes.txt       post-volumes.txt
diff -u baseline-networks.txt      post-networks.txt
diff -u baseline-listeners.txt     post-listeners.txt
diff -u baseline-port-mappings.txt post-port-mappings.txt

shred -u compose.yml restore.hcl \
  post-containers.txt post-volumes.txt post-networks.txt \
  post-listeners.txt post-port-mappings.txt \
  baseline-*.txt
rm -rf /tmp/openbao-restore-test
```

unset snapshot_name ciphertext_name plaintext_sha workstation_backup_dir

Every diff above must be empty. Any leftover container, volume,
network, listener, port mapping, scratch file, or mode-`0600`
JSON/config file in `/tmp/openbao-restore-test/` indicates an
incomplete teardown and blocks declaring the restore proof
successful.

## Failure handling

If any step fails, stop. Specific actions:

| Failure                                       | Action                                                                |
|-----------------------------------------------|-----------------------------------------------------------------------|
| Container label filter resolves zero/many IDs | Stop; inspect `docker ps` for unexpected OpenBao containers           |
| Snapshot save or streaming errors             | Discard the partial ciphertext and sidecars; rerun from snapshot save |
| `age` encryption exits non-zero               | Discard the partial ciphertext and sidecars; rerun from snapshot save |
| Sentinel write or delete fails                | Stop; investigate OpenBao ACL state before another backup             |
| Developer decrypt SHA-256 mismatches          | Stop; treat the artifact as untrustworthy                             |
| Scratch `docker compose` does not converge    | Stop; inspect the named volume and `openbao.hcl` for typos            |
| Restore reports non-empty diff                | Stop; do not touch production c0; capture logs and rerun on a fresh c1 |
| Two production shares do not unseal scratch   | Stop; the snapshot is suspect; do not declare restore successful      |
| Sentinel missing after force restore          | Stop; do not trust the artifact; rerun from snapshot save             |
| c1 recovery decrypt SHA-256 mismatches        | Stop; rotate the c1 identity through [SOPS.md](../SOPS.md) and rerun |
| Audit log leaks raw secrets                   | Stop; treat credentials as exposed and rotate per [OPERATIONS.md](OPERATIONS.md) |

A successful drill produces no artifacts outside
`$HOME/.local/share/openbao-backups/c0/`, the offline recovery system,
and operator memory during the run.

## Operational cadence

Run the destructive restore drill after every Shamir share rotation,
after every OpenBao upgrade that touches Raft, and at least once per
quarter. Each run produces a fresh artifact under
`$HOME/.local/share/openbao-backups/c0/`, so prune older ciphertexts
after each successful drill; never prune the most recent.

References:

- [OPENBAO.md](../OPENBAO.md) — architecture, identities, and Shamir
  policy.
- [BOOTSTRAP.md](BOOTSTRAP.md) — initialization and unseal.
- [OPERATIONS.md](OPERATIONS.md) — named-identity usage and rotation.
- [SOPS.md](../SOPS.md) — developer and offline recovery age identities.
