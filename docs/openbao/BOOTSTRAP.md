# OpenBao bootstrap

Chronological, one-time runbook that turns a clean `main` branch, a clean c0
host, and three age recipients into a production single-node OpenBao service
named `openbao-c0`. Architecture lives in [OPENBAO](../OPENBAO.md); daily
operations in [OPERATIONS](OPERATIONS.md); encrypted recovery in
[BACKUP-RESTORE](BACKUP-RESTORE.md); SOPS/age policy in [SOPS](../SOPS.md).

Every command below is grounded against the actual repository artifacts:

- `docker/c0/.doco-cd.yaml` — host-scoped Doco auto-discovery (`working_dir:
  ./docker/c0`, depth `1`, delete `false`, force_recreate `false`).
- `docker/c0/openbao/.doco-cd.yaml` — nested project name `openbao-c0`.
- `docker/c0/openbao/compose.yml` — four services, three named volumes,
  one static address, no host ports.
- `docker/c0/openbao/config/openbao.hcl` — Raft + TLS + stdout audit.
- `docker/c0/openbao/scripts/install_certificate.py` and
  `docker/c0/openbao/scripts/renew_certificate.sh` — installer and renewer.
- `docker/mod.just` — sole task runner; CI and the operator call
  `just docker validate-c0`.

## Conventions

### Shell scopes

| Prompt | Host | Shell | Where secrets live |
| --- | --- | --- | --- |
| `ws$` | workstation | zsh, mise-managed | `$HOME/.config/sops/age/keys.txt`, hidden prompts |
| `c0$` | c0 (Linux) | Bash over SSH; some steps need `sudo -H` | `/opt/doco-cd/secrets/sops_age_key`, hidden prompts |
| `c0-ct#` | openbao container | `/bin/sh` via `docker exec -it` | short-lived `BAO_TOKEN` only |

Container IDs are resolved through Compose labels
(`label=com.docker.compose.project=openbao-c0`,
`label=com.docker.compose.service=openbao`), never through generated names or
short-id prefixes.

### Secret handling rules

- Never pass a share, root token, ACME token, Cloudflare token, or user
  password as an argument. Plaintext enters the system through a hidden
  prompt piped into `bao write`/`bao operator init`, or a SOPS plaintext
  stream. Shares for unseal are typed at OpenBao's own hidden prompt;
  they never enter argv, a shell variable, a file, or a pipe.
- No `read -p` inside the container; the container's `/bin/sh` lacks
  GNU `read -p`. Use `printf 'prompt: ' >&2; stty -echo; read -r VAR; stty
  echo; printf '\n' >&2` instead.
- No token-helper file is ever created; `~/.vault-token` and
  `~/.bao-token` must not exist at any point.
- `bao operator init` runs **exactly once**, interactively. Its output
  (three shares and one initial root token) is captured on screen only;
  it is not piped plaintext, not redirected to a file, not passed in
  argv, and not passed in a Git/SOPS/log/chat artifact.
- The Cloudflare token must be restricted to `Zone:DNS:Edit` on
  `monosense.io`; a Global API Key stops the runbook. The encrypted
  source file must not be writable by group or other; the runtime copy
  Certbot uses is `0600` inside `tmpfs /run/certbot:mode=0700`, and
  the renewer requires `DAC_OVERRIDE` to re-read a key that the
  compose chown has already assigned to `uid 100`.

### Tooling

`mise` only installs and exposes the language toolchains. The actual
`docker/mod.just` recipes run `yamllint`, `sops`, `python3`, `jq`,
and `docker compose`; they do not invoke `age-keygen` or `age`
(those are operator-side tools used elsewhere in this runbook).
Image verification uses only the c0 Docker CLI (`docker pull`,
`docker image inspect`, `docker run`). The canonical task entry is
`just docker validate-c0` and there is no second runner.
## Procedure

```mermaid
flowchart LR
    A[Preflight] --> B[Three age recipients]
    B --> C[Stream c0 identity]
    C --> D[.sops.yaml]
    D --> E[Doco SOPS rollout]
    E --> F[Encrypt ACME inputs]
    F --> G[Verify images]
    G --> H[Cert tests]
    H --> I[just validate-c0 + push]
    I --> J[Doco poll + rollback key]
    J --> K[Shamir init]
    K --> L[Unseal x2]
    L --> M[KV + policies + userpass]
    M --> N[Authz + root revoke]
    N --> O[Audit proof]
    O --> P[Backup + restore]
    P --> Q[Reboot + private DNS gate]
```

## 1. Preflight

Stop on any unexpected value.

### 1.1 Git

`ws$`

```sh
test -z "$(git status --porcelain)" || {
  printf 'working tree is not clean\n' >&2; exit 1; }
git rev-parse --abbrev-ref HEAD
git fetch origin
git rev-parse origin/main
```

`main` is clean, on `main`, tracking `origin/main`. Record the SHA.

### 1.2 c0 listener, container, volume, network baseline

`c0$`

```sh
docker version --format '{{.Server.Version}} {{.Server.Arch}}'
docker compose version
docker ps --filter name=doco-cd --format '{{.Names}}\t{{.Image}}\t{{.State}}'
docker network ls --filter name=c0_services --format '{{.Name}}\t{{.ID}}'
docker volume ls --format '{{.Name}}'
ss -tlnp
stat -c '%U:%G %a %n' /var/lib/docker /opt/doco-cd /opt/doco-cd/secrets \
  /opt/doco-cd/secrets/api_secret /opt/doco-cd/compose.yml
```

Required readings:

- Docker Engine `29.7.2` (amd64), Compose `5.5.0`.
- One running `doco-cd` container.
- `/var/lib/docker` is `root:root` mode `0710`.
- `doco-cd-data` volume exists; `c0_services` bridge exists on
  `10.25.13.0/24` with gateway `10.25.13.1`.
- Host ports `8200`/`8201` free on every interface.
- `10.25.13.34` unused inside `c0_services`.
- No `openbao*` container, volume, or network.
- No `openbao-data`, `openbao-acme`, or `openbao-tls` volume.

### 1.3 Doco endpoints

`c0$`

```sh
docker exec doco-cd /doco-cd healthcheck
docker port doco-cd
ss -tlnp | grep -E '127.0.0.1:8080|127.0.0.1:9120'
```

Both loopback endpoints bind `127.0.0.1`. Doco must report a successful poll
against `main`; record the last polled SHA.

### 1.4 DNS and mailbox

`ws$`

```sh
dig +short NS monosense.io
dig +short vault.monosense.io
```

`monosense.io` is Cloudflare-delegated and public
`vault.monosense.io` must return no answer. PowerDNS now serves the reviewed private record only
when queried directly at `10.25.13.33`; AdGuard forwarding remains disabled. The operator mailbox
for ACME expiry notices is monitored. If `vault.monosense.io` resolves via public DNS, stop because
another public publisher has intervened.

### 1.5 Host swap

`c0$`

```sh
swapon --show
free -h
```

Swap may be enabled but currently used `0` bytes. Do not toggle it globally.
The OpenBao service declares `mem_swappiness: 0`.

## 2. Three age recipients

| Identity | Generated on | Private storage | Recipient in `.sops.yaml` |
| --- | --- | --- | --- |
| `developer` | workstation | `$HOME/.config/sops/age/keys.txt` | yes |
| `c0-doco` | workstation → stream into c0 | `/opt/doco-cd/secrets/sops_age_key` | yes |
| `offline-recovery` | offline recovery system | offline recovery system | yes |

Any one recipient decrypts. This is independent of OpenBao's later Shamir
threshold. Stop if no offline recipient is available; never generate its
private key on the workstation.

### 2.1 Developer identity

`ws$`

```sh
umask 077
test ! -L "$HOME/.config/sops" && test ! -L "$HOME/.config/sops/age"
install -d -m 0700 "$HOME/.config/sops/age"
test ! -e "$HOME/.config/sops/age/keys.txt"
age-keygen -o "$HOME/.config/sops/age/keys.txt"
chmod 0600 "$HOME/.config/sops/age/keys.txt"
age-keygen -y "$HOME/.config/sops/age/keys.txt"
```

The last command prints the public recipient; capture only that line. If
the symlink checks fail, stop and inspect.

`SOPS_AGE_KEY_FILE` is exported by root `.mise.toml`. Outside a
mise-activated shell:

`ws$`

```sh
export SOPS_AGE_KEY_FILE="$HOME/.config/sops/age/keys.txt"
```

### 2.2 Offline recovery identity

Generate on the offline recovery system following
[SOPS](../SOPS.md#offline-recovery-identity). The private half stays
offline; only the public recipient returns to the workstation.

### 2.3 c0 identity — streamed, never persisted locally

Stream the private key from `age-keygen` stdout directly through SSH
into a `sudo install … /dev/stdin` on c0. No local temp file. No
remote temp file. The install creates `/opt/doco-cd/secrets/sops_age_key`
with the right owner and mode atomically from a single stdin stream.
`age-keygen` writes the public recipient to stderr; capture stderr to a
mode `0600` local file for `.sops.yaml` and remove it once the recipient
is transcribed. Do **not** write `age-keygen` stdout anywhere on the
workstation.

`ws$`

```sh
umask 077
pub=$(mktemp -t c0-age-recipient.XXXXXX)
chmod 0600 "$pub"
age-keygen 2>"$pub" | ssh monosense@10.25.10.20 \
  'sudo -H install -o root -g root -m 0700 -d /opt/doco-cd/secrets && \
   sudo -H install -o root -g root -m 0600 \
     /dev/stdin /opt/doco-cd/secrets/sops_age_key'
cat "$pub"
rm -f "$pub"
```

The `cat "$pub"` line prints only the `age1…` public recipient. The
streamed private key never touches workstation storage, Git, or chat.

### 2.4 Validate the installed file silently

Validation runs as root on c0, checks metadata and the first syntax
marker line, and prints nothing on success.

`c0$`

```sh
sudo -H bash -c '
set -eu
f=/opt/doco-cd/secrets/sops_age_key
test "$(stat -c %U:%G:%a:%F "$f")" = "root:root:600:regular file"
test ! -L "$f"
seen=
while IFS= read -r line; do
  case "$line" in
    AGE-SECRET-KEY-1*) seen=yes ;;
    *) ;;
  esac
  [ "$seen" = yes ] && break
done < "$f"
test "$seen" = yes
'
```

On failure, remove only the newly created file and retry. Do **not** install
`age`, `sops`, Certbot, or `acme.sh` on c0.
## 3. `.sops.yaml`

`ws$`

```yaml
---
creation_rules:
  - path_regex: ^docker/c0/[^/]+/encrypted/.*$
    key_groups:
      - age:
          - age1DEVELOPER_PUBLIC_RECIPIENT
          - age1C0_DOCO_PUBLIC_RECIPIENT
          - age1OFFLINE_RECOVERY_PUBLIC_RECIPIENT
```

Validate:

`ws$`

```sh
sops filestatus docker/c0/openbao/encrypted/acme.env
sops filestatus docker/c0/openbao/encrypted/cloudflare.ini
```

Both must report `encrypted` and list all three recipients. `unencrypted`
means a regex mismatch; fix the rule, do not bypass.

## 4. Doco SOPS rollout

### 4.1 Update bootstrap Compose

`docker/c0/.doco-cd/docker-compose.app.yaml` gains only:

- environment literal `SOPS_AGE_KEY_FILE=/run/secrets/sops_age_key`,
- service secret `sops_age_key`,
- source `${DOCO_CD_SOPS_AGE_KEY_FILE:-/opt/doco-cd/secrets/sops_age_key}`.

The API secret, image digest, Docker socket, `doco-cd-data` volume, loopback
ports, healthcheck, and logging stay unchanged.

### 4.2 Extend validation

Append `.sops.yaml` to both `paths` filters in
`.github/workflows/docker.yaml`. `docker/mod.just`'s `validate-c0` already
invokes `validate-openbao` and lints `.sops.yaml` plus the bootstrap file
with `yamllint`; it then renders with
`DOCO_CD_API_SECRET_FILE=/dev/null DOCO_CD_SOPS_AGE_KEY_FILE=/dev/null`.
CI stays decrypt-free and receives no age identity.

### 4.3 Commit, push, install on c0

`ws$`

```sh
git add .sops.yaml docker/c0/.doco-cd/docker-compose.app.yaml \
  docker/mod.just .github/workflows/docker.yaml
git commit -m "feat(docker): enable SOPS age for Doco-CD"
git push origin main
```

After the push succeeds, byte-match the reviewed Compose file on c0:

`c0$`

```sh
install -o root -g root -m 0644 \
  /opt/doco-cd/compose.yml.new /opt/doco-cd/compose.yml
```

`ws$`

```sh
git rev-parse origin/main:docker/c0/.doco-cd/docker-compose.app.yaml
diff -u <(git show origin/main:docker/c0/.doco-cd/docker-compose.app.yaml) \
  /dev/null
```

### 4.4 Restart Doco

`c0$`

```sh
DOCO_CD_API_SECRET_FILE=/opt/doco-cd/secrets/api_secret \
DOCO_CD_SOPS_AGE_KEY_FILE=/opt/doco-cd/secrets/sops_age_key \
  docker compose -f /opt/doco-cd/compose.yml config --quiet

DOCO_CD_API_SECRET_FILE=/opt/doco-cd/secrets/api_secret \
DOCO_CD_SOPS_AGE_KEY_FILE=/opt/doco-cd/secrets/sops_age_key \
  docker compose -f /opt/doco-cd/compose.yml pull

DOCO_CD_API_SECRET_FILE=/opt/doco-cd/secrets/api_secret \
DOCO_CD_SOPS_AGE_KEY_FILE=/opt/doco-cd/secrets/sops_age_key \
  docker compose -f /opt/doco-cd/compose.yml up -d
```

Verify the contract is preserved:

`c0$`

```sh
docker exec doco-cd /doco-cd healthcheck
docker port doco-cd
ss -tlnp | grep -E '127.0.0.1:8080|127.0.0.1:9120'
docker volume ls --filter name=doco-cd-data
```

Any single failure stops the bootstrap; SOPS must not break Doco.

## 5. Encrypted ACME inputs

Two files feed Doco:

| File | Format | Doco loads as |
| --- | --- | --- |
| `docker/c0/openbao/encrypted/acme.env` | dotenv (`ACME_EMAIL=…`) | `env_file` for `certificate-init` |
| `docker/c0/openbao/encrypted/cloudflare.ini` | INI (`dns_cloudflare_api_token = …`) | Compose `secret` (target `cloudflare.ini`) |

Use `.env` and `.ini` extensions exactly so Doco v0.111.0 selects the right
SOPS formats. Plaintext is created under mode `0700`, encrypted in place,
then removed.

`ws$`

```sh
umask 077
tmp=$(mktemp -d -t openbao-acme.XXXXXX)
chmod 0700 "$tmp"
trap 'rm -rf "$tmp"' EXIT
printf 'ACME_EMAIL=%s\n' "$ACME_EMAIL" >"$tmp/acme.env"
chmod 0600 "$tmp/acme.env"
printf 'dns_cloudflare_api_token = %s\n' \
  "$CLOUDFLARE_DNS_EDIT_TOKEN" >"$tmp/cloudflare.ini"
chmod 0600 "$tmp/cloudflare.ini"
unset ACME_EMAIL CLOUDFLARE_DNS_EDIT_TOKEN

sops encrypt --filename-override docker/c0/openbao/encrypted/acme.env \
  --output docker/c0/openbao/encrypted/acme.env "$tmp/acme.env"
sops encrypt --filename-override docker/c0/openbao/encrypted/cloudflare.ini \
  --output docker/c0/openbao/encrypted/cloudflare.ini "$tmp/cloudflare.ini"
rm -f "$tmp/acme.env" "$tmp/cloudflare.ini"
rmdir "$tmp"
```

The variables are exported from the operator's interactive prompt; the runbook
shows the value form. `--filename-override` lets the recipient rule apply to
the final path; `--output` avoids printing ciphertext to the terminal.
Subsequent edits use `sops edit`.

`ws$`

```sh
sops filestatus docker/c0/openbao/encrypted/acme.env
sops filestatus docker/c0/openbao/encrypted/cloudflare.ini
```

## 6. Image and runtime verification

Pinned digests in `docker/c0/openbao/compose.yml`:

- `docker.io/openbao/openbao:2.6.2@sha256:e29524ba7c3f20d01f562c481e3eccbad6c91df45a2f2531433da4951e408cff`
- `certbot/dns-cloudflare:v5.7.0@sha256:ed5e95feb4d64690df77b4628876f3b72ae856d6e0acd51927a2fd45baf1ccd2`

Both are `linux/amd64`.

### 6.1 Confirm digest mappings via c0 Docker

Use only the Docker CLI that is already installed on c0. Pull each
pinned image at the exact tag and digest, then read its resolved
RepoDigests back from the local image store. No external registry
inspector is required.

`c0$`

```sh
docker pull --platform linux/amd64 \
  docker.io/openbao/openbao:2.6.2@sha256:e29524ba7c3f20d01f562c481e3eccbad6c91df45a2f2531433da4951e408cff
docker pull --platform linux/amd64 \
  certbot/dns-cloudflare:v5.7.0@sha256:ed5e95feb4d64690df77b4628876f3b72ae856d6e0acd51927a2fd45baf1ccd2
docker image inspect \
  --format '{{index .RepoDigests 0}}' \
  docker.io/openbao/openbao:2.6.2@sha256:e29524ba7c3f20d01f562c481e3eccbad6c91df45a2f2531433da4951e408cff
docker image inspect \
  --format '{{index .RepoDigests 0}}' \
  certbot/dns-cloudflare:v5.7.0@sha256:ed5e95feb4d64690df77b4628876f3b72ae856d6e0acd51927a2fd45baf1ccd2
```

Each returned RepoDigest must equal the pinned value. Reject any
drift; do not silently adapt.

### 6.2 Certbot runtime

`c0$`

```sh
docker run --rm --platform linux/amd64 \
  --entrypoint python3 \
  certbot/dns-cloudflare:v5.7.0@sha256:ed5e95feb4d64690df77b4628876f3b72ae856d6e0acd51927a2fd45baf1ccd2 \
  -c 'import cryptography'
```

`cryptography` must import.

### 6.3 OpenBao runtime UID/GID

The Alpine variant of `docker.io/openbao/openbao:2.6.2` uses
`addgroup openbao && adduser -S -G openbao openbao`, which lets
Alpine auto-assign numeric IDs (typically `100:100`). The
Compose file overrides the image's `USER openbao` directive by
setting `user: "100:1000"` on both `volume-init` and `openbao`,
so the data directory and the server process agree on the same
numeric IDs regardless of the image's own user mapping. The
verification below exercises the exact `user:` override the
Compose file applies — running it without the override would
inspect the image's auto-assigned IDs (typically `100:100`) and
would not match the production chown.

`c0$`

```sh
docker run --rm --platform linux/amd64 \
  --user 100:1000 \
  --entrypoint /bin/sh \
  docker.io/openbao/openbao:2.6.2@sha256:e29524ba7c3f20d01f562c481e3eccbad6c91df45a2f2531433da4951e408cff \
  -ec 'test "$(id -u)" = 100; test "$(id -g)" = 1000; id'
```

The runtime user must be `uid=100(openbao) gid=1000(openbao)`
(the displayed name reflects the image's `openbao` user even
though numeric IDs are forced by the `--user` flag). `volume-init`
runs as `0:0` and chowns `/openbao/data` to `100:1000` mode
`0700`; the runtime service then runs as the same numeric IDs.

## 7. Certificate installer tests

`docker/mod.just` already runs the suite inside the pinned Certbot image;
the same invocation can be run manually:

`ws$`

```sh
just docker validate-c0
```

`validate-openbao` mounts `docker/c0/openbao` read-only to `/src`, sets a
`1777` tmpfs at `/tmp`, and runs
`python3 -m unittest discover -s /src/tests -v` inside the pinned image.
The suite covers:
- Valid ECDSA key + cert with `vault.monosense.io` SAN installs one complete
  generation under `releases/<serial>`, file modes `0644`/`0600`,
  ownership `100:1000`, `current` switched atomically.
- Mismatched key/cert, absent SAN, expired cert, and injected failures
  before generation rename or symlink switch leave the old `current`
  unchanged.
- Repeatable serial is idempotent.
- `previous` rollback works.
- `check --min-valid-days 21` accepts fresh, rejects expired/missing.
- Mocked `os.kill` receives `SIGHUP` only after a successful switch.

A single failing assertion halts the runbook.

## 8. Project validation and publication

### 8.1 Run the canonical validator

`ws$`

```sh
just docker validate-c0
```

What this single command guarantees:

- `yamllint` clean for `.sops.yaml`, the host-scoped Doco config, controller Compose and poll
  config, plus `docker/c0/openbao/.doco-cd.yaml` and its Compose file.
- `sops filestatus` reports both ACME inputs `encrypted`.
- Both files contain the `sops_` envelope markers and no plaintext
  `dns_cloudflare_api_token` value.
- `tests/test_install_certificate.py` passes inside the pinned Certbot
  image.
- Rendered JSON: no service has a `ports:` key; only `openbao` joins
  `c0_services` at `10.25.13.34`; both Certbot services reference
  `secrets[0].target == "cloudflare.ini"`; the renewer declares
  `pid: service:openbao`; all three volume `name` fields equal their
  keys; no service mounts `/var/run/docker.sock`.

OpenBao HCL has no parse-only CLI; the pinned production container's
pre-initialization HTTP `501` is the behavioral parser.

### 8.2 Commit, push, byte-match

`ws$`

```sh
git add docker/c0/openbao docker/mod.just .github/workflows/docker.yaml
git commit -m "feat(docker): deploy OpenBao on c0"
git push origin main
for p in .sops.yaml docker/c0/.doco-cd/docker-compose.app.yaml \
         docker/c0/openbao/.doco-cd.yaml docker/c0/openbao/compose.yml \
         docker/c0/openbao/config/openbao.hcl docker/mod.just; do
  git diff --quiet origin/main -- "$p"
done
```

Every diff must be empty; otherwise the local copy disagrees with the
published artifact.

## 9. Doco poll and rollback key

### 9.1 Wait for one poll

Doco auto-discovers `docker/c0` at depth `1` with the nested
`.doco-cd.yaml` overriding the project name to `openbao-c0`. The next
180-second poll picks up `docker/c0/openbao/`.

`c0$`

```sh
docker logs --tail 200 doco-cd 2>&1
docker ps --filter label=com.docker.compose.project=openbao-c0 \
  --format '{{.Names}}\t{{.Image}}\t{{.Status}}'
docker volume ls --filter name=openbao
docker network inspect c0_services \
  --format '{{range .Containers}}{{.Name}} {{end}}'
```

Required outcomes:

- Doco logs show successful decryption of `acme.env` and `cloudflare.ini`.
- One `openbao-c0` project with four services.
- Three named volumes: `openbao-data`, `openbao-acme`, `openbao-tls`.
- Only the `openbao` service attaches to `c0_services`.

### 9.2 Decrypted clone boundary

The repository source files in `docker/c0/openbao/encrypted/` are mode
`0644` under `/var/lib/docker` (`root:root 0710`). Doco's working clone
lives inside the `doco-cd-data` volume and is only accessible to root
on the c0 host. Verify the boundary without inspecting contents:

`c0$`

```sh
mountpoint=$(docker volume inspect --format '{{.Mountpoint}}' doco-cd-data)
stat -c '%U:%G %a' "$mountpoint"
stat -c '%U:%G %a' /var/lib/docker
find /var/lib/docker -path '*openbao/encrypted*' -type f \
  -printf '%U:%G %m\n' | sort -u
```

Decrypted material is accessible only to root; this is the accepted
plaintext-at-rest boundary. **Exclude `doco-cd-data` from unencrypted
backup/support collection**; it now contains SOPS plaintexts. Do not
add a host-side file-share or copy step that would broaden access.

### 9.3 External reachability via `--resolve`

`vault.monosense.io` remains absent from public DNS and AdGuard does not forward to PowerDNS, so
clients use `curl --resolve` against the static `10.25.13.34`.

`ws$`

```sh
curl --resolve vault.monosense.io:8200:10.25.13.34 \
  https://vault.monosense.io:8200/v1/sys/health
```

The chain must validate to a public CA, the JSON must show
`initialized=false`, and the HTTP code must be `501`. From c1:

`c1$`

```sh
curl --resolve vault.monosense.io:8200:10.25.13.34 \
  https://vault.monosense.io:8200/v1/sys/health
```

A non-public chain or a non-`501` code is a bug; stop.

### 9.4 ACME TXT cleanup

`ws$`

```sh
dig +short _acme-challenge.vault.monosense.io TXT
```

The response must be empty. A lingering TXT means the deploy hook left a
challenge behind.

### 9.5 Rollback endpoint (incident only)

The Doco v0.111 endpoint is
`DELETE /v1/api/project/openbao-c0?volumes=false&images=false`. Doco
authenticates with the `x-api-key` header; the value is the
`/opt/doco-cd/secrets/api_secret` contents. Build a root-only mode
`0600` curl config file with the header line, run `curl --config` from
a single command line, and trap the file's removal. Do not pass the
secret via `-H`, here-doc, or stdin.

`c0$`

```sh
tmp=$(sudo mktemp -t doco-cd-curl.XXXXXX)
sudo chmod 0600 "$tmp"
trap 'sudo rm -f "$tmp"' EXIT HUP INT TERM
sudo sh -c 'key=$(cat /opt/doco-cd/secrets/api_secret); \
  printf "header = \"x-api-key: %s\"\n" "$key" > "$1"' sh "$tmp"
sudo curl --silent --show-error --config "$tmp" \
  --request DELETE \
  'http://127.0.0.1:8080/v1/api/project/openbao-c0?volumes=false&images=false'
```

After a successful rollback, confirm the three volume identities
persist, then stop only the host-bootstrap Doco container to prevent
the next poll from recreating the failed project. Doco is the only
process that holds the SOPS age identity in memory; restart only the
Doco container after a SOPS key correction. OpenBao never reads or
caches the age identity, so its restart is unrelated to key rotation.
If the TLS volume needs repair, restart Doco first, then explicitly
rerun `certificate-init` per [OPERATIONS](OPERATIONS.md).

## 10. Shamir initialization

Initialization runs **inside the OpenBao container's `/bin/sh`**, where
`BAO_ADDR=https://vault.monosense.io:8200` is set by the Compose
environment and the container's hosts entry resolves
`vault.monosense.io` to `10.25.13.34`. Resolve the ID with Compose labels
only.

### 10.1 Resolve one container

`c0$`

```sh
cid=$(docker ps -q \
  --filter label=com.docker.compose.project=openbao-c0 \
  --filter label=com.docker.compose.service=openbao)
test -n "$cid"
docker inspect --format '{{.Id}} {{.State.Running}}' "$cid"
```

### 10.2 Confirm pre-init

`c0-ct#`

```sh
bao operator init -status
```

Exit code must be `2` (not yet initialized). Exit `0` means a previous run
completed; stop.

### 10.3 Initialize exactly once

`c0-ct#`

```sh
bao operator init -key-shares=3 -key-threshold=2
```

The command prints three unseal shares and one initial root token. Do not
request JSON output, redirect stdout, record the terminal, or pass a share
or root token in a file, Git, SOPS, logs, or chat. Transfer each share
immediately to distinct offline media or custody; only this bootstrap
shell retains the initial root token.

## 11. Manual unseal

Unseal runs interactively inside the OpenBao container's `/bin/sh`.
Invoke `bao operator unseal` **without arguments** twice. Each invocation
prompts for one share; type the share at OpenBao's own hidden prompt.
The share never enters argv, a shell variable, a here-document, a pipe,
a file, Git, SOPS, logs, or chat.

`c0-ct#`

```sh
bao operator unseal
bao operator unseal
bao status
```

`bao status` must show `initialized=true sealed=false` and exactly one
Raft leader with `node_id=c0-openbao-1`. HTTP `200` follows. A
`sealed=true` or `standby=true` after two distinct shares means a wrong
share; stop and re-read the offline medium.

### 11.1 Capture the initial root token into the bootstrap shell

The token was already emitted by `bao operator init`. Capture it now
into a short-lived `BAO_TOKEN` through a hidden prompt. The token
stays only inside this container shell until `bao token revoke -self`
runs; it is never written to a file or passed in argv.

`c0-ct#`

```sh
printf 'paste initial root token: ' >&2
stty -echo
IFS= read -r BAO_TOKEN
stty echo
printf '\n' >&2
export BAO_TOKEN
test -n "${BAO_TOKEN:-}"
```

Repeat on every container restart. **Auto-unseal is intentionally
disabled**; the offline share set remains the sole recovery boundary.

## 12. KV, policies, userpass

The bootstrap shell still holds the initial root token in a short-lived
`BAO_TOKEN`. Use it to enable KV v2, write the two policies, enable
userpass, and create the named identities. Every secret value enters
OpenBao through a hidden `stty -echo` prompt piped into `bao write`.

### 12.1 Enable KV v2 at `kv/`

`c0-ct#`

```sh
bao secrets enable -path=kv kv-v2
```

### 12.2 Write mounted policies

`policies/` is mounted read-only at `/openbao/policies/`. The exact
filenames match the policy names.

`c0-ct#`

```sh
bao policy write admin /openbao/policies/admin.hcl
bao policy write junos-operator /openbao/policies/junos-operator.hcl
bao policy list
```

`admin` is the named administrator policy (`path "*"` with full
capabilities). `junos-operator` grants `read` only on
`kv/data/network/junos/srx1500/netconf` and
`kv/data/network/junos/srx1500/topology` — the two paths read by
`ansible/junos/scripts/with-openbao-runtime.sh`. No metadata, list, or
write capabilities.

### 12.3 Enable userpass

`c0-ct#`

```sh
bao auth enable userpass
```

### 12.4 Create the named users

`c0-ct#`

```sh
printf 'monosense-admin password: ' >&2; stty -echo; IFS= read -r admin_pw
stty echo; printf '\n' >&2
printf '%s\n' "$admin_pw" | bao write auth/userpass/users/monosense-admin \
  password=- policies=admin
unset admin_pw

printf 'monosense-junos password: ' >&2; stty -echo; IFS= read -r junos_pw
stty echo; printf '\n' >&2
printf '%s\n' "$junos_pw" | bao write auth/userpass/users/monosense-junos \
  password=- policies=junos-operator
unset junos_pw
```

Both passwords come from a hidden prompt and are unset immediately. Only
the operator password manager and offline custody retain the plaintext;
OpenBao retains only its verifier.

## 13. Authorization tests and root-token revocation

Each clean authorization test re-authenticates with the relevant named
user and unsets the password and token after the assertion. No `bao
login`; tokens come from userpass writes only.

### 13.1 Admin

`c0-ct#`

```sh
printf 'monosense-admin password: ' >&2; stty -echo; IFS= read -r admin_pw
stty echo; printf '\n' >&2
admin_token=$(printf '%s\n' "$admin_pw" | bao write -field=token \
  auth/userpass/login/monosense-admin password=-)
unset admin_pw

caps=$(BAO_TOKEN="$admin_token" bao token capabilities kv/data)
case "$caps" in
  *sudo*) ;;
  *) printf 'admin policy missing sudo on kv/data\n' >&2; exit 1 ;;
esac
BAO_TOKEN="$admin_token" bao secrets list
BAO_TOKEN="$admin_token" bao auth list
BAO_TOKEN="$admin_token" bao policy list
unset admin_token
```

Admin capabilities on `kv/data` are a comma-separated list that includes
`sudo` (the policy grants full capabilities); the listing commands
are the proof of effective reach, not the literal output string.

### 13.2 Junos read-only

`c0-ct#`

```sh
printf 'monosense-junos password: ' >&2; stty -echo; IFS= read -r junos_pw
stty echo; printf '\n' >&2
junos_token=$(printf '%s\n' "$junos_pw" | bao write -field=token \
  auth/userpass/login/monosense-junos password=-)
unset junos_pw

# Required: read capability on the two exact data paths.
test "$(BAO_TOKEN="$junos_token" bao token capabilities \
    kv/data/network/junos/srx1500/netconf)" = read
test "$(BAO_TOKEN="$junos_token" bao token capabilities \
    kv/data/network/junos/srx1500/topology)" = read

# Required: write is denied on the same path.
test "$(BAO_TOKEN="$junos_token" bao token capabilities \
    kv/data/network/junos/srx1500/netconf)" != update

# Required: one real forbidden read produces an audited denial.
if BAO_TOKEN="$junos_token" bao kv get -mount=kv \
    network/junos/srx1500/does-not-exist >/dev/null 2>&1; then
  printf 'junos-operator must not read unrelated paths\n' >&2; exit 1
fi

unset junos_token
```

The Junos policy grants `read` exactly on the two documented data paths
and refuses every other capability and unrelated data path; the
forbidden read also exercises the stdout audit device.

### 13.3 Root-token revocation

`c0-ct#`

```sh
bao token revoke -self
unset BAO_TOKEN
test ! -e "$HOME/.vault-token"
test ! -e "$HOME/.bao-token"
```

Verify both named users still authenticate:

`c0-ct#`

```sh
printf 'monosense-admin password: ' >&2; stty -echo; IFS= read -r admin_pw
stty echo; printf '\n' >&2
printf '%s\n' "$admin_pw" | bao write -field=token \
  auth/userpass/login/monosense-admin password=- >/dev/null
unset admin_pw

printf 'monosense-junos password: ' >&2; stty -echo; IFS= read -r junos_pw
stty echo; printf '\n' >&2
printf '%s\n' "$junos_pw" | bao write -field=token \
  auth/userpass/login/monosense-junos password=- >/dev/null
unset junos_pw
```

Both logins must succeed. A failure means revocation removed a capability
that should persist through userpass; stop and audit.

## 14. Audit proof

`stdout` audit is configured declaratively in `config/openbao.hcl`:

```hcl
audit "file" "stdout" {
  description = "Write audit information to standard output."
  options = { file_path = "stdout" }
}
```

`raw` logging stays disabled. `docker logs` is the authoritative audit
feed.

`c0$`

```sh
docker logs --tail 200 "$cid" 2>&1
```

Required event types:

- `auth/userpass/login/monosense-admin` with success
- `auth/userpass/login/monosense-junos` with success and the subsequent
  read paths
- `sys/policy/write` for `admin` and `junos-operator`
- `sys/mounts/kv` for the KV v2 enable
- A denied request from `monosense-junos` (write or list attempt) — look
  for the matching `denied` outcome
- `auth/token/revoke-self` for the initial root token

No line may contain `ACME_EMAIL`, `dns_cloudflare_api_token`, an unseal
share, a root token, a user password, or a KV plaintext value. If the
audit stream shows any of these, stop and audit the policy.

## 15. Backup, restore, reboot

These three phases live in separate runbooks so each stays focused.
Follow [BACKUP-RESTORE](BACKUP-RESTORE.md) for the encrypted snapshot,
[OPERATIONS](OPERATIONS.md) for the controlled c0 reboot. The bootstrap
report is complete only when all three phases pass. PowerDNS, cAdvisor, native observability on c0,
and any c1 service were prohibited until completion.

## 16. Completion checklist

The OpenBao bootstrap is complete only when **every** item below is true.
Record timestamps (without secrets) in the operator run log.

| # | Check | Source |
| --- | --- | --- |
| 1 | `.sops.yaml` lists all three recipients; both ACME inputs encrypted. | `sops filestatus` |
| 2 | Doco-CD container healthy; retains both loopback ports; polls `main`; `doco-cd-data` intact. | `docker exec`, `ss -tlnp` |
| 3 | `openbao-c0` project exists with four services and three named volumes; only `openbao` joins `c0_services` at `10.25.13.34`. | `docker ps`, `docker network inspect` |
| 4 | No host port mapping on `8200`/`8201`; only `openbao` owns `10.25.13.34`. | `docker port`, `ss -tlnp` |
| 5 | `https://vault.monosense.io:8200/v1/sys/health` returns HTTP `501` and a publicly trusted chain from c0 and c1. | `curl --resolve` |
| 6 | ACME TXT for `_acme-challenge.vault.monosense.io` is empty. | `dig` |
| 7 | Certificate installer suite passes inside the pinned Certbot image. | `just docker validate-c0` |
| 8 | `bao operator init` ran exactly once; three shares, threshold two. | offline custody |
| 9 | Two distinct shares unsealed the cluster; one Raft leader `c0-openbao-1`. | `bao status` |
| 10 | `admin` and `junos-operator` policies written; KV v2 enabled at `kv/`; userpass enabled. | `bao policy/list/secrets/auth list` |
| 11 | `monosense-admin` and `monosense-junos` authenticate; capability assertions pass; denial paths fail. | `bao token capabilities`, `bao kv get/put/list` |
| 12 | Root token self-revoked; `BAO_TOKEN` unset; `~/.vault-token` and `~/.bao-token` absent; named users still authenticate. | `bao token revoke -self`, `test ! -e ~/.vault-token ~/.bao-token` |
| 13 | Audit stdout contains login, policy, mount, denial, and revoke events; no plaintext secrets. | `docker logs` |
| 14 | Encrypted Raft snapshot staged off-host; developer and offline identities decrypt to the recorded plaintext checksum. | `age`, `sha256sum` |
| 15 | Isolated c1 restore succeeds, unseals with two production shares, returns the sentinel, and confirms audit/listener HCL. | `bao status`, `bao kv get` |
| 16 | Controlled c0 reboot returns Docker-restored `doco-cd`, `openbao`, `certificate-renewer`; OpenBao serves sealed `503`, then `200` after two shares; volume identities and served certificate serial match. | `bao status`, `docker ps` |

OpenBao is not complete until all 16 pass. After they passed, the standalone PowerDNS deployment
added the private `vault.monosense.io -> 10.25.13.34` record without changing Doco-CD's SOPS/age
boundary.
