#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import os
import pathlib
import re
import shutil
import ssl
import stat
import tempfile
import urllib.error
import urllib.request

from cryptography import x509

import install_certificate


class FetchError(Exception):
    pass

def _fence_path(target: pathlib.Path) -> pathlib.Path:
    return target / ".openbao-certificate-fence.json"


def _read_fence(target: pathlib.Path) -> dict[str, object]:
    path = _fence_path(target)
    if not path.exists():
        return {"kv_version": 0, "blocked_version": 0, "serial": ""}
    if path.is_symlink() or stat.S_IMODE(path.stat().st_mode) != 0o600:
        raise FetchError("wildcard certificate fence custody is unsafe")
    fence = json.loads(path.read_text(encoding="utf-8"))
    if set(fence) != {"kv_version", "blocked_version", "serial"}:
        raise FetchError("wildcard certificate fence schema is invalid")
    if not isinstance(fence["kv_version"], int) or not isinstance(fence["blocked_version"], int):
        raise FetchError("wildcard certificate fence versions are invalid")
    if not isinstance(fence["serial"], str):
        raise FetchError("wildcard certificate fence serial is invalid")
    return fence


def _write_fence(target: pathlib.Path, version: int, serial: str) -> None:
    target.mkdir(mode=0o755, parents=True, exist_ok=True)
    fence = _read_fence(target)
    content = json.dumps(
        {"kv_version": version, "blocked_version": fence["blocked_version"], "serial": serial},
        sort_keys=True,
        separators=(",", ":"),
    ).encode("ascii") + b"\n"
    descriptor, name = tempfile.mkstemp(prefix=".openbao-certificate-fence.", dir=target)
    temporary = pathlib.Path(name)
    try:
        os.fchmod(descriptor, 0o600)
        os.fchown(descriptor, 0, 0)
        with os.fdopen(descriptor, "wb") as stream:
            stream.write(content)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, _fence_path(target))
        directory = os.open(target, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0))
        try:
            os.fsync(directory)
        finally:
            os.close(directory)
    finally:
        temporary.unlink(missing_ok=True)


def _validate_fence(target: pathlib.Path, version: int, serial: str) -> None:
    fence = _read_fence(target)
    if version <= fence["blocked_version"]:
        raise FetchError("wildcard record version is fenced after rollback")
    if version < fence["kv_version"]:
        raise FetchError("wildcard record version regressed")
    if version == fence["kv_version"] and fence["serial"] not in ("", serial):
        raise FetchError("wildcard serial changed without a KV version change")




def main() -> int:
    parser = argparse.ArgumentParser(description="Fetch and atomically install the shared wildcard")
    parser.add_argument("--token-file", required=True, type=pathlib.Path)
    parser.add_argument("--target", required=True, type=pathlib.Path)
    parser.add_argument("--uid", required=True, type=int)
    parser.add_argument("--gid", required=True, type=int)
    parser.add_argument("--combined", action="store_true")
    parser.add_argument("--minio", action="store_true")
    parser.add_argument("--url", default="https://vault.monosense.io:8200")
    args = parser.parse_args()
    temporary: pathlib.Path | None = None
    try:
        metadata = args.token_file.stat()
        if args.token_file.is_symlink() or not stat.S_ISREG(metadata.st_mode) or metadata.st_mode & 0o077:
            raise FetchError("reader token file is unsafe")
        token = args.token_file.read_text(encoding="utf-8").strip()
        if not token or re.search(r"\s", token):
            raise FetchError("reader token is invalid")
        renew_request = urllib.request.Request(
            args.url.rstrip("/") + "/v1/auth/token/renew-self",
            data=b"",
            method="POST",
            headers={"X-Vault-Token": token},
        )
        with urllib.request.urlopen(
            renew_request, context=ssl.create_default_context(), timeout=15
        ) as response:
            renewed = json.load(response)["auth"]
        if renewed.get("renewable") is not True or not isinstance(
            renewed.get("lease_duration"), int
        ) or renewed["lease_duration"] <= 0:
            raise FetchError("reader token did not renew as a periodic credential")
        request = urllib.request.Request(
            args.url.rstrip("/") + "/v1/kv/data/platform/tls/monosense-wildcard",
            headers={"X-Vault-Token": token},
        )
        with urllib.request.urlopen(request, context=ssl.create_default_context(), timeout=15) as response:
            envelope = json.load(response)["data"]
        record = envelope["data"]
        version = envelope["metadata"]["version"]
        if not isinstance(version, int) or version <= 0:
            raise FetchError("wildcard record has no committed KV version")
        if set(record) != {"certificate", "fullchain", "private_key", "serial", "not_after"}:
            raise FetchError("wildcard record keys differ from the exact contract")
        temporary = pathlib.Path(tempfile.mkdtemp(prefix="wildcard-reader-"))
        fullchain = record["fullchain"].encode("ascii")
        private_key = record["private_key"].encode("ascii")
        (temporary / "fullchain.pem").write_bytes(fullchain)
        (temporary / "privkey.pem").write_bytes(private_key)
        cert_pem, key_pem, serial = install_certificate.validate_pair(
            temporary / "fullchain.pem", temporary / "privkey.pem", "*.monosense.io", 14
        )
        certificate = x509.load_pem_x509_certificate(cert_pem)
        leaf = re.search(
            br"-----BEGIN CERTIFICATE-----\r?\n.*?-----END CERTIFICATE-----\r?\n?",
            cert_pem,
            re.DOTALL,
        )
        if leaf is None or leaf.group().decode("ascii") != record["certificate"]:
            raise FetchError("leaf certificate field does not match fullchain")
        not_after = certificate.not_valid_after_utc.isoformat().replace("+00:00", "Z")
        if record["serial"] != serial or record["not_after"] != not_after:
            raise FetchError("wildcard metadata does not match parsed certificate")
        _validate_fence(args.target, version, serial)
        install_certificate.install_pair(
            cert_pem,
            key_pem,
            serial,
            args.target,
            uid=args.uid,
            gid=args.gid,
            combined=args.combined,
            minio=args.minio,
        )
        _write_fence(args.target, version, serial)
    except (KeyError, TypeError, UnicodeError, OSError, ValueError, FetchError, urllib.error.URLError) as error:
        print(f"wildcard fetch failed: {error}", file=os.sys.stderr)
        return 1
    finally:
        if temporary is not None:
            shutil.rmtree(temporary, ignore_errors=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
