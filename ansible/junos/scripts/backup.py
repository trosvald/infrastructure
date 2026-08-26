#!/usr/bin/env python3
"""Stream committed configuration from PyEZ into age without plaintext files."""
from __future__ import annotations

import os
import re
import stat
import subprocess
import sys
from pathlib import Path
from typing import Any

from jnpr.junos import Device


def required(name: str) -> str:
    value = os.environ.get(name, "")
    if not value:
        raise RuntimeError(f"missing runtime value: {name}")
    return value

REVIEWED_RELEASE = re.compile(r"^23[.]4R2(?:[.-]|$)")


def _validate_private_directory(fd: int, label: str, info: os.stat_result) -> None:
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) != 0o700:
        raise RuntimeError(f"backup directory must be an owner-controlled real 0700 directory: {label}")
    current = os.fstat(fd)
    if (current.st_dev, current.st_ino) != (info.st_dev, info.st_ino):
        raise RuntimeError(f"backup directory changed while opening: {label}")


def require_private_parent(path: Path) -> tuple[int, int]:
    if not path.is_absolute() or path.parent.name != "backups" or path.parent.parent.name != ".build":
        raise RuntimeError(f"backup output must be a file below .build/backups: {path}")
    build = path.parent.parent
    flags = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW
    build_fd = -1
    backups_fd = -1
    try:
        build_lstat = os.lstat(build)
        if stat.S_ISLNK(build_lstat.st_mode):
            raise RuntimeError(f"backup directory must not contain a symlink: {build}")
        build_fd = os.open(build, flags)
        _validate_private_directory(build_fd, str(build), build_lstat)
        backups_lstat = os.stat("backups", dir_fd=build_fd, follow_symlinks=False)
        if stat.S_ISLNK(backups_lstat.st_mode):
            raise RuntimeError(f"backup directory must not contain a symlink: {path.parent}")
        backups_fd = os.open("backups", flags, dir_fd=build_fd)
        _validate_private_directory(backups_fd, str(path.parent), backups_lstat)
        return build_fd, backups_fd
    except OSError as error:
        if backups_fd >= 0:
            os.close(backups_fd)
        if build_fd >= 0:
            os.close(build_fd)
        raise RuntimeError(f"backup directory is unavailable: {path.parent}") from error
    except Exception:
        if backups_fd >= 0:
            os.close(backups_fd)
        if build_fd >= 0:
            os.close(build_fd)
        raise

def configuration_text(reply: Any) -> str:
    for node in reply.iter():
        if str(node.tag).rsplit("}", 1)[-1] == "configuration-text" and node.text:
            return node.text
    raise RuntimeError("Junos did not return text configuration")


def main() -> int:
    try:
        with Device(
            host=required("JUNOS_MANAGEMENT_ADDRESS"),
            user=required("JUNOS_NETCONF_USERNAME"),
            port=830,
            ssh_private_key_file=required("JUNOS_NETCONF_PRIVATE_KEY_FILE"),
            ssh_config=required("JUNOS_NETCONF_SSH_CONFIG"),
            hostkey_verify=True,
            look_for_keys=False,
            allow_agent=False,
            gather_facts=True,
        ) as device:
            facts = device.facts
            if str(facts.get("model", "")).upper() != "SRX1500":
                raise RuntimeError("unexpected device model")
            if str(facts.get("hostname", "")) != "srx1500":
                raise RuntimeError("unexpected device hostname")
            if not REVIEWED_RELEASE.match(str(facts.get("version", ""))):
                raise RuntimeError("Junos release is outside the reviewed train")
            reply = device.rpc.get_config(options={"database": "committed", "format": "text"})
            plaintext = configuration_text(reply)

        output = Path(required("JUNOS_BACKUP_OUTPUT"))
        build_fd, backups_fd = require_private_parent(output)
        flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW
        created = False
        descriptor = -1
        try:
            descriptor = os.open(output.name, flags, 0o600, dir_fd=backups_fd)
            created = True
            os.fchmod(descriptor, 0o600)
            subprocess.run(
                [
                    "age",
                    "--encrypt",
                    "--recipient",
                    required("JUNOS_BACKUP_AGE_RECIPIENT"),
                ],
                input=(plaintext.rstrip("\n") + "\n").encode(),
                stdout=descriptor,
                check=True,
            )
            os.fsync(descriptor)
        except Exception:
            if created:
                try:
                    os.unlink(output.name, dir_fd=backups_fd)
                except FileNotFoundError:
                    pass
            raise
        finally:
            if descriptor >= 0:
                os.close(descriptor)
            os.close(backups_fd)
            os.close(build_fd)
        del plaintext
    except Exception:
        print("Backup failed; no plaintext backup was retained.", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
