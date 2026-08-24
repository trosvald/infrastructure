# SOPS and age

This guide defines the repository-wide workstation convention for SOPS identities. Junos automation does not use SOPS for topology or credentials; it reads those values from OpenBao. Junos uses age directly only when encrypting configuration backups.

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

References: [SOPS age support and key management](https://github.com/getsops/sops), [age and age-keygen](https://github.com/FiloSottile/age), and [WSL file permissions](https://learn.microsoft.com/windows/wsl/file-permissions).
