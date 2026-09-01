#!/usr/bin/env python3
"""Create one atomic, checksummed, non-secret host rollback generation."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shutil
import stat
import sys
import tempfile
from pathlib import Path


def fsync_directory(path: Path) -> None:
    descriptor = os.open(path, os.O_RDONLY | os.O_DIRECTORY)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def write_bytes(path: Path, payload: bytes, mode: int = 0o600) -> None:
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, mode)
    try:
        remaining = memoryview(payload)
        while remaining:
            remaining = remaining[os.write(descriptor, remaining):]
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def canonical_bytes(value: object) -> bytes:
    return (json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=True) + "\n").encode()


def validate_existing(generation: Path) -> None:
    manifest = generation / "manifest.json"
    marker = generation / "complete"
    if generation.is_symlink() or not manifest.is_file() or not marker.is_file():
        raise RuntimeError("existing rollback generation is incomplete or unsafe")
    expected = marker.read_text(encoding="ascii").strip()
    actual = hashlib.sha256(manifest.read_bytes()).hexdigest()
    if expected != actual:
        raise RuntimeError("existing rollback manifest checksum differs from completion marker")


def capture(root: Path, generation_id: str, host: str, audit_sha256: str, contract: int, paths: list[str]) -> bool:
    if not re.fullmatch(r"[0-9a-f]{64}", generation_id):
        raise ValueError("generation id must be lowercase SHA-256")
    if not re.fullmatch(r"[0-9a-f]{64}", audit_sha256):
        raise ValueError("audit digest must be lowercase SHA-256")
    if host not in {"c0", "c1"} or contract < 1:
        raise ValueError("host or contract is invalid")
    if paths != sorted(set(paths)) or not paths:
        raise ValueError("rollback paths must be a nonempty sorted unique allowlist")
    for source in paths:
        if not source.startswith("/") or ".." in Path(source).parts:
            raise ValueError(f"unsafe rollback path: {source}")
        if source == "/opt/doco-cd/secrets" or source.startswith("/opt/doco-cd/secrets/"):
            raise ValueError("secret custody paths are forbidden")
        if source.startswith(("/srv/", "/var/lib/docker/", "/var/lib/containerd/")):
            raise ValueError("application and engine state paths are forbidden")

    for ancestor in (root.parent.parent, root.parent, root):
        if ancestor.is_symlink():
            raise RuntimeError(f"rollback path component is a symlink: {ancestor}")
    root.mkdir(parents=True, exist_ok=True, mode=0o700)
    root_stat = root.stat()
    if not stat.S_ISDIR(root_stat.st_mode) or root_stat.st_uid != os.geteuid():
        raise RuntimeError("rollback root must be owned by the invoking account")
    os.chmod(root, 0o700)
    destination = root / generation_id
    if os.path.lexists(destination):
        validate_existing(destination)
        return False

    staging = Path(tempfile.mkdtemp(prefix=f".{generation_id}.", dir=root))
    os.chmod(staging, 0o700)
    manifest_entries: list[dict[str, object]] = []
    try:
        tree = staging / "tree"
        tree.mkdir(mode=0o700)
        for source_text in paths:
            source = Path(source_text)
            target = tree / source_text.lstrip("/")
            try:
                source_stat = source.lstat()
            except FileNotFoundError:
                manifest_entries.append({"path": source_text, "state": "absent"})
                continue
            target.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
            mode = stat.S_IMODE(source_stat.st_mode)
            entry: dict[str, object] = {
                "gid": source_stat.st_gid,
                "mode": f"{mode:04o}",
                "path": source_text,
                "uid": source_stat.st_uid,
            }
            if stat.S_ISREG(source_stat.st_mode):
                descriptor = os.open(source, os.O_RDONLY | os.O_NOFOLLOW)
                try:
                    payload = b""
                    while chunk := os.read(descriptor, 1024 * 1024):
                        payload += chunk
                finally:
                    os.close(descriptor)
                write_bytes(target, payload, mode)
                entry.update(state="file", sha256=hashlib.sha256(payload).hexdigest())
            elif stat.S_ISLNK(source_stat.st_mode):
                link_target = os.readlink(source)
                os.symlink(link_target, target)
                entry.update(state="symlink", target=link_target)
            else:
                raise RuntimeError(f"allowlisted path is not a regular file or symlink: {source_text}")
            manifest_entries.append(entry)

        manifest_value = {
            "audit_sha256": audit_sha256,
            "contract_version": contract,
            "generation_id": generation_id,
            "host": host,
            "paths": manifest_entries,
            "schema_version": 1,
        }
        manifest_payload = canonical_bytes(manifest_value)
        write_bytes(staging / "manifest.json", manifest_payload)
        marker_payload = (hashlib.sha256(manifest_payload).hexdigest() + "\n").encode("ascii")
        write_bytes(staging / "complete", marker_payload)
        for directory, _, _ in os.walk(staging, topdown=False):
            fsync_directory(Path(directory))
        os.replace(staging, destination)
        fsync_directory(root)
        return True
    except BaseException:
        shutil.rmtree(staging, ignore_errors=True)
        raise


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", required=True, type=Path)
    parser.add_argument("--generation", required=True)
    parser.add_argument("--host", required=True)
    parser.add_argument("--audit-sha256", required=True)
    parser.add_argument("--contract", required=True, type=int)
    args = parser.parse_args()
    if os.geteuid() != 0:
        raise PermissionError("rollback capture must run as root")
    serialized = os.environ.get("CONTAINER_NODES_ROLLBACK_PATHS")
    document = json.loads(serialized) if serialized is not None else json.load(sys.stdin)
    if not isinstance(document, list) or not all(isinstance(item, str) for item in document):
        raise ValueError("stdin must be a JSON array of paths")
    changed = capture(args.root, args.generation, args.host, args.audit_sha256, args.contract, document)
    print("created" if changed else "present")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
