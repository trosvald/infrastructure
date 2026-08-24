#!/usr/bin/env python3

from __future__ import annotations

import argparse
import datetime
import os
import pathlib
import re
import shutil
import signal
import sys
import tempfile
import uuid

from cryptography import x509
from cryptography.hazmat.primitives import serialization


class CertificateError(Exception):
    """A certificate pair or installation invariant is invalid."""


def validate_pair(
    fullchain: pathlib.Path,
    private_key: pathlib.Path,
    hostname: str,
    min_valid_days: int,
) -> tuple[bytes, bytes, str]:
    try:
        cert_pem = fullchain.read_bytes()
        key_pem = private_key.read_bytes()
        certificate = x509.load_pem_x509_certificate(cert_pem)
        key = serialization.load_pem_private_key(key_pem, password=None)
    except (OSError, ValueError, TypeError) as error:
        raise CertificateError("certificate or private key could not be parsed") from error

    encoding = serialization.Encoding.DER
    public_format = serialization.PublicFormat.SubjectPublicKeyInfo
    cert_public_key = certificate.public_key().public_bytes(encoding, public_format)
    private_public_key = key.public_key().public_bytes(encoding, public_format)
    if cert_public_key != private_public_key:
        raise CertificateError("certificate and private key do not match")

    try:
        names = certificate.extensions.get_extension_for_class(
            x509.SubjectAlternativeName
        ).value.get_values_for_type(x509.DNSName)
    except x509.ExtensionNotFound as error:
        raise CertificateError("certificate has no DNS subject alternative names") from error
    if hostname.lower() not in {name.lower() for name in names}:
        raise CertificateError("certificate does not cover the required hostname")

    threshold = datetime.datetime.now(datetime.timezone.utc) + datetime.timedelta(
        days=min_valid_days
    )
    if hasattr(certificate, "not_valid_after_utc"):
        not_valid_after = certificate.not_valid_after_utc
    else:
        not_valid_after = certificate.not_valid_after.replace(tzinfo=datetime.timezone.utc)
    if not_valid_after <= threshold:
        raise CertificateError("certificate validity is below the required threshold")

    return cert_pem, key_pem, format(certificate.serial_number, "x")


def _ensure_root_directory(path: pathlib.Path) -> None:
    path.mkdir(mode=0o755, parents=True, exist_ok=True)
    if path.is_symlink() or not path.is_dir():
        raise CertificateError(f"{path.name} is not a directory")
    os.chown(path, 0, 0)
    os.chmod(path, 0o755)


def _fsync_directory(path: pathlib.Path) -> None:
    descriptor = os.open(path, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0))
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def _write_file(path: pathlib.Path, content: bytes, mode: int, uid: int, gid: int) -> None:
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, mode)
    try:
        os.fchmod(descriptor, mode)
        os.fchown(descriptor, uid, gid)
        view = memoryview(content)
        while view:
            written = os.write(descriptor, view)
            if written == 0:
                raise OSError("short write while publishing certificate material")
            view = view[written:]
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def _validated_release_target(target_dir: pathlib.Path, target: str) -> pathlib.Path:
    if pathlib.PurePath(target).is_absolute():
        raise CertificateError("certificate symlink target must be relative")
    try:
        releases = (target_dir / "releases").resolve(strict=True)
        resolved = (target_dir / target).resolve(strict=True)
    except OSError as error:
        raise CertificateError("certificate symlink target is invalid") from error
    if resolved.parent != releases or not resolved.is_dir():
        raise CertificateError("certificate symlink target is outside releases")
    return resolved


def _read_link(target_dir: pathlib.Path, name: str) -> str | None:
    path = target_dir / name
    if not path.exists() and not path.is_symlink():
        return None
    if not path.is_symlink():
        raise CertificateError(f"{name} is not a symbolic link")
    target = os.readlink(path)
    _validated_release_target(target_dir, target)
    return target


def _replace_link(target_dir: pathlib.Path, name: str, target: str) -> None:
    _validated_release_target(target_dir, target)
    temporary = target_dir / f".{name}.{os.getpid()}.{uuid.uuid4().hex}"
    try:
        os.symlink(target, temporary)
        os.replace(temporary, target_dir / name)
    finally:
        if temporary.is_symlink():
            temporary.unlink()


def _switch_current(target_dir: pathlib.Path, new_target: str) -> bool:
    old_target = _read_link(target_dir, "current")
    if old_target == new_target:
        _replace_link(target_dir, "current", new_target)
        _fsync_directory(target_dir)
        return True
    if old_target is not None:
        _replace_link(target_dir, "previous", old_target)
    _replace_link(target_dir, "current", new_target)
    _fsync_directory(target_dir)
    return True


def _verify_existing_generation(
    generation: pathlib.Path,
    cert_pem: bytes,
    key_pem: bytes,
    uid: int,
    gid: int,
) -> None:
    expected = (
        (generation / "fullchain.pem", cert_pem, 0o644),
        (generation / "privkey.pem", key_pem, 0o600),
    )
    if generation.is_symlink() or not generation.is_dir():
        raise CertificateError("existing certificate generation is invalid")
    generation_stat = generation.stat()
    if (generation_stat.st_uid, generation_stat.st_gid, generation_stat.st_mode & 0o777) != (
        0,
        0,
        0o755,
    ):
        raise CertificateError("existing certificate generation metadata is invalid")
    for path, content, mode in expected:
        if path.is_symlink() or not path.is_file() or path.read_bytes() != content:
            raise CertificateError("existing certificate generation content is invalid")
        metadata = path.stat()
        if (metadata.st_uid, metadata.st_gid, metadata.st_mode & 0o777) != (uid, gid, mode):
            raise CertificateError("existing certificate generation metadata is invalid")


def install_pair(
    cert_pem: bytes,
    key_pem: bytes,
    serial: str,
    target_dir: pathlib.Path,
    uid: int = 100,
    gid: int = 1000,
) -> str:
    if re.fullmatch(r"[0-9a-f]+", serial) is None:
        raise CertificateError("certificate serial is not lowercase hexadecimal")

    _ensure_root_directory(target_dir)
    releases = target_dir / "releases"
    _ensure_root_directory(releases)
    generation = releases / serial

    if generation.exists() or generation.is_symlink():
        _verify_existing_generation(generation, cert_pem, key_pem, uid, gid)
    else:
        temporary = pathlib.Path(tempfile.mkdtemp(prefix=f".{serial}.", dir=releases))
        try:
            os.chown(temporary, 0, 0)
            os.chmod(temporary, 0o755)
            _write_file(temporary / "fullchain.pem", cert_pem, 0o644, uid, gid)
            _write_file(temporary / "privkey.pem", key_pem, 0o600, uid, gid)
            _fsync_directory(temporary)
            os.rename(temporary, generation)
            _fsync_directory(releases)
        finally:
            if temporary.exists():
                shutil.rmtree(temporary)

    _switch_current(target_dir, f"releases/{serial}")
    return serial


def rollback_pair(target_dir: pathlib.Path, reload_pid: int | None) -> None:
    previous = _read_link(target_dir, "previous")
    if previous is None:
        raise CertificateError("no previous certificate generation exists")
    switched = _switch_current(target_dir, previous)
    if reload_pid is not None and switched:
        os.kill(reload_pid, signal.SIGHUP)




def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Validate and atomically install TLS material")
    subparsers = parser.add_subparsers(dest="command", required=True)

    install = subparsers.add_parser("install")
    install.add_argument("--lineage", required=True, type=pathlib.Path)
    install.add_argument("--target", required=True, type=pathlib.Path)
    install.add_argument("--hostname", required=True)
    install.add_argument("--min-valid-days", type=int, default=0)
    install.add_argument("--reload-pid", type=int)

    check = subparsers.add_parser("check")
    check.add_argument("--target", required=True, type=pathlib.Path)
    check.add_argument("--hostname", required=True)
    check.add_argument("--min-valid-days", required=True, type=int)

    rollback = subparsers.add_parser("rollback")
    rollback.add_argument("--target", required=True, type=pathlib.Path)
    rollback.add_argument("--reload-pid", type=int)

    return parser


def main() -> int:
    arguments = _parser().parse_args()
    try:
        if arguments.command == "install":
            cert_pem, key_pem, serial = validate_pair(
                arguments.lineage / "fullchain.pem",
                arguments.lineage / "privkey.pem",
                arguments.hostname,
                arguments.min_valid_days,
            )
            install_pair(cert_pem, key_pem, serial, arguments.target)
            if arguments.reload_pid is not None:
                os.kill(arguments.reload_pid, signal.SIGHUP)
        elif arguments.command == "check":
            validate_pair(
                arguments.target / "fullchain.pem",
                arguments.target / "privkey.pem",
                arguments.hostname,
                arguments.min_valid_days,
            )
        else:
            rollback_pair(arguments.target, arguments.reload_pid)
    except (CertificateError, OSError, ValueError) as error:
        print(f"certificate operation failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
