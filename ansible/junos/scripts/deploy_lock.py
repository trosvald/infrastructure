#!/usr/bin/env python3
"""Serialize the complete supported Junos deployment transaction."""

from __future__ import annotations

import contextlib
import fcntl
import os
import pathlib
import stat
import subprocess
import sys
from collections.abc import Iterator

CONTENTION_MESSAGE = "Deployment already in progress; refusing to queue."


class DeploymentLockError(RuntimeError):
    """The controller deployment lock cannot be acquired safely."""


def _require_private_directory(path: pathlib.Path) -> None:
    try:
        metadata = path.lstat()
    except FileNotFoundError:
        path.mkdir(mode=0o700)
        metadata = path.lstat()
    if (
        not stat.S_ISDIR(metadata.st_mode)
        or stat.S_ISLNK(metadata.st_mode)
        or metadata.st_uid != os.getuid()
        or stat.S_IMODE(metadata.st_mode) != 0o700
    ):
        raise DeploymentLockError(
            "Junos artifact directory must be an owner-controlled real 0700 directory."
        )


@contextlib.contextmanager
def deployment_lock(path: pathlib.Path) -> Iterator[None]:
    _require_private_directory(path.parent)
    flags = os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW
    try:
        descriptor = os.open(path, flags, 0o600)
    except OSError as error:
        raise DeploymentLockError(f"Unsafe deployment lock file: {error}") from error
    try:
        metadata = os.fstat(descriptor)
        if (
            not stat.S_ISREG(metadata.st_mode)
            or metadata.st_uid != os.getuid()
            or stat.S_IMODE(metadata.st_mode) != 0o600
        ):
            raise DeploymentLockError(
                "Deployment lock must be an owner-controlled regular 0600 file."
            )
        try:
            fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as error:
            raise DeploymentLockError(CONTENTION_MESSAGE) from error
        try:
            yield
        finally:
            fcntl.flock(descriptor, fcntl.LOCK_UN)
    finally:
        os.close(descriptor)


def main() -> int:
    if len(sys.argv) != 1:
        print("deploy_lock.py does not accept arguments", file=sys.stderr)
        return 2
    project_dir = pathlib.Path(__file__).resolve().parents[1]
    lock_path = project_dir / ".build" / "srx1500.deploy.lock"
    try:
        with deployment_lock(lock_path):
            environment = os.environ.copy()
            environment["JUNOS_DEPLOY_LOCK_HELD"] = "1"
            result = subprocess.run(
                [str(project_dir / "scripts" / "deploy.sh")],
                cwd=project_dir,
                env=environment,
                check=False,
            )
            return result.returncode
    except DeploymentLockError as error:
        print(error, file=sys.stderr)
        return 1
    except KeyboardInterrupt:
        return 130


if __name__ == "__main__":
    raise SystemExit(main())
