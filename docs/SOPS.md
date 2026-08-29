# SOPS and age

This guide defines the repository-wide workstation convention for SOPS identities. Junos uses
SOPS only to decrypt the tracked `encrypted/monosense-infra.env` for fixed `monosense-infra`
service authentication. Junos topology and device credentials come from OpenBao; configuration
backups use age directly rather than SOPS.

## Storage boundary

All private SOPS/age identities and user-local settings live under:

```text
~/.config/sops/
```

The canonical identity file is:

```text
~/.config/sops/age/keys.txt
```

This path is identical on Linux, macOS, and inside WSL2. Under WSL2, keep it in the distribution's Linux home, never under `/mnt/c`. Native Windows execution is outside this Bash/Just workflow.

SOPS otherwise chooses an operating-system-specific default path, including a
macOS Application Support path. This repository deliberately overrides that
lookup with `SOPS_AGE_KEY_FILE`, so one reviewed path works on every supported
controller. The override is also safer operationally: an operator never has to
guess which platform default SOPS selected.

A project's `.sops.yaml` may remain beside that project only when it contains non-secret public recipients and reviewed creation rules. Private identities never belong in a repository policy file.

## Create a workstation identity

Run locally on each trusted workstation:

```bash
umask 077
test ! -L "$HOME/.config/sops"
test ! -L "$HOME/.config/sops/age"
install -d -m 0700 "$HOME/.config/sops/age"
test ! -e "$HOME/.config/sops/age/keys.txt"
age-keygen -o "$HOME/.config/sops/age/keys.txt"
chmod 0600 "$HOME/.config/sops/age/keys.txt"
age-keygen -y "$HOME/.config/sops/age/keys.txt"
```

The last command prints the public `age1…` recipient. Share only that recipient. Never copy a workstation's private identity to another workstation.

If either symlink check fails, stop and inspect the path instead of writing a
key through it. `test ! -e` intentionally prevents accidental replacement of
an existing identity. A key rotation creates and proves a new identity first;
it does not overwrite `keys.txt` in place.

The root mise configuration exports only the identity path:

```bash
SOPS_AGE_KEY_FILE="$HOME/.config/sops/age/keys.txt"
```

It never stores identity contents. Outside a mise-activated repository shell, export the same path explicitly before invoking SOPS.

## Offline recovery identity

Generate the recovery identity on an offline recovery system using that system's own `~/.config/sops/age/keys.txt`. Keep the private identity offline and transfer only its public recipient to the system that encrypts data.

For Junos, an OpenBao administrator stores that public recipient in the topology record as `backup_age_recipient`. Developer laptops and CI never receive the recovery private identity.

Prove recovery before relying on it:

```bash
age --decrypt \
  --identity "$HOME/.config/sops/age/keys.txt" \
  --output recovered.conf \
  srx1500-DOCUMENTATION-TIMESTAMP.conf.age
chmod 0600 recovered.conf
```

Inspect the result on the offline system and securely remove the plaintext afterward.

## Recipient maintenance for future SOPS projects

Public recipients may be committed in a project's `.sops.yaml`. After adding or removing a recipient, an authorized operator runs:

```bash
sops updatekeys path/to/file.sops.yaml
```

`updatekeys` changes recipient wrapping but does not rotate the data key. If an identity may be compromised, remove its recipient and rotate the data key:

```bash
sops rotate --in-place path/to/file.sops.yaml
```

Rotation cannot revoke ciphertext already copied from history. Rotate exposed underlying secret values at their source as well.

## Safety checklist

- Identity directory is mode `0700`; identity file is mode `0600`.
- Identity is owned by the current Linux/macOS user and is not a symlink.
- No identity resides in Git, cloud-synchronized storage, `/mnt/c`, logs, tickets, or chat.
- Each workstation has a distinct identity.
- Offline recovery material is absent from development workstations and CI.
- Repository `.sops.yaml` files contain only public recipients and creation rules.

## c0 and OpenBao: runtime SOPS

This section extends the workstation convention to the Doco-CD-managed c0 host
and the OpenBao project. It does not replace the workstation guidance above;
workstation authoring continues to follow the storage boundary, identity
creation, and offline recovery procedures already documented.

### Three-recipient policy and `docker/c0/<stack>/encrypted/`

SOPS ciphertext for c0 applications lives under each direct Doco-CD child of
`docker/c0/`, never elsewhere:

```text
docker/c0/<stack>/encrypted/
```

Root `.sops.yaml` carries one creation rule scoped to that path, naming three
`age1…` public recipients: the workstation developer identity, the dedicated
c0 Doco-CD machine identity, and the offline recovery identity. Any one
recipient can decrypt. This recipient set is independent of OpenBao's later
Shamir threshold and does not name any human userpass account.

The `.env` and `.ini` extensions are required for Doco-CD v0.111.0 to select
the correct SOPS formats:

| File                              | Format | Single key            |
| --------------------------------- | ------ | --------------------- |
| `docker/c0/<stack>/encrypted/acme.env`    | dotenv | `ACME_EMAIL`          |
| `docker/c0/<stack>/encrypted/cloudflare.ini` | ini | `dns_cloudflare_api_token` |

Both ciphertext files are created with `sops encrypt --filename-override
<final-path> --output <final-path>` from a mode-`0600` temporary plaintext
under a mode-`0700` directory, and subsequent edits use `sops edit`. The
Cloudflare token is restricted to `Zone:DNS:Edit` on `monosense.io`; a Global
API Key is never used. The ACME account email is the monitored operator
mailbox.

### Doco-CD decrypt scope

Doco-CD decrypts only what Compose and the project explicitly reference:
`env_file` entries and Compose `secrets` mounted into application containers.
Arbitrary repository ciphertext is not decrypted. The CI workflow's path
filter validates structure and format on `.sops.yaml` and the encrypted files,
but it cannot surface runtime decryption failures: CI never receives an age
identity, so a successful CI run does not prove any one of the three
recipients can open the ciphertext. Decryption proof is a runtime concern,
not a CI concern.

For the `openbao-c0` project, only the certificate services consume
decrypted material: `certificate-init` and `certificate-renewer` receive
`encrypted/acme.env` as `env_file` and `encrypted/cloudflare.ini` as a
Compose secret. The `openbao` server itself receives neither an `env_file`
nor a mounted Compose secret; it reads only its HCL, its TLS material, and
Raft data. The `volume-init` service touches no decrypted material at all.
Application containers never mount the age identity; they receive only the
already-decrypted `env_file` or a mounted Compose secret whose value Doco has
already unwrapped on the host.

### Doco machine identity and process-cached restart

The c0 Doco-CD machine identity is generated by the workstation
`age-keygen`, piped over SSH directly into `sudo install -o root -g root -m
0600 /dev/stdin /opt/doco-cd/secrets/sops_age_key`, and never written to
workstation storage. The file's owner, mode, and secret-key syntax are
validated after the pipe; on failure the new invalid file is removed and the
pipeline retried. The corresponding public recipient is the only output
captured, and is the same one already present in `.sops.yaml`.

Doco-CD process-caches the key once at startup. Replacing
`/opt/doco-cd/secrets/sops_age_key` does not affect the running container.
A SOPS key correction requires restarting the host-bootstrap Doco-CD
container so the new key is loaded into the process. OpenBao itself does
not need to restart for a SOPS key rotation; its own configuration is not
SOPS-protected.

### Actual v0.111 file-mode behavior

Repository files keep their existing `0644` mode after Doco v0.111
decryption-in-place. Doco writes the decrypted content back to the same
Git-tracked path via `os.WriteFile` rather than staging a new file, so the
resulting mode remains root-owned `0644`. Effective protection is provided
by Docker's storage boundary, not by per-file modes in the working clone.

The chain that gives runtime plaintext its confidentiality is:

| Layer                                              | Owner / mode          | Purpose                                       |
| -------------------------------------------------- | --------------------- | --------------------------------------------- |
| Repository files in working clone (before and after Doco decryption) | root / `0644` | Public ciphertext, declarative config, and Doco's decrypt-in-place output |
| `/var/lib/docker` on c0                            | `root:root` / `0710`  | Boundary that protects all Docker state       |
| Application tmpfs credential copy (Certbot)        | root / `0600`         | What `certbot` actually reads; trapped on exit |

Certificate services assert that the source `cloudflare.ini` is not
group- or world-writable before copying it to the `mode=0700` tmpfs path
with `install -m 0600`; the runtime tmpfs copy is the only file Certbot
ever sees, and is removed by an `EXIT HUP INT TERM` trap. The Doco-CD data
volume (`doco-cd-data`), `openbao-data`, `openbao-acme`, and `openbao-tls`
are reachable only because `/var/lib/docker` is `root:root` mode `0710`.
Weakening that mode breaks the root-only file-secret design and is a
regression to be detected during preflight, not silently worked around.

### c1 recovery custody

The offline recovery identity is, by current operator decision, held on c1.
Until that custody moves, the offline recovery recipient in `.sops.yaml`
decrypts to the c1-resident identity, and c1 is treated as part of the
recovery trust set rather than as a separate application host.

Recommendation: take the offline recovery identity off c1 and onto a host
that does not run other workloads. The recovery identity's job is to open
ciphertext when both the workstation and c0 are unavailable; sharing that
host with anything else re-introduces the very coupling the offline identity
is meant to escape. The recovery runbook
[openbao/BACKUP-RESTORE.md](openbao/BACKUP-RESTORE.md) documents the
destructive restore proof that both the developer and offline identities
must pass.

### What stays in this guide

The workstation identity path, `age-keygen` procedure, `sops updatekeys` and
`sops rotate` maintenance, and the safety checklist above remain the
authoritative SOPS reference. The c0/OpenBao additions here only describe
how Doco-CD consumes that work; they do not redefine author-side workflow.

For OpenBao architecture, contracts, and the private DNS publication gate, see
[OPENBAO.md](OPENBAO.md). For day-2 operations and recovery procedure, see
[openbao/BOOTSTRAP.md](openbao/BOOTSTRAP.md) and
[openbao/OPERATIONS.md](openbao/OPERATIONS.md).

References: [SOPS age support and key management](https://github.com/getsops/sops), [age and age-keygen](https://github.com/FiloSottile/age), and [WSL file permissions](https://learn.microsoft.com/windows/wsl/file-permissions). See [OPENBAO.md](OPENBAO.md) for the OpenBao deployment contract and [openbao/BACKUP-RESTORE.md](openbao/BACKUP-RESTORE.md) for the off-host encrypted snapshot and isolated restore proof.
