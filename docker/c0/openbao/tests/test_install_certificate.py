from __future__ import annotations

import contextlib
import datetime
import io
import os
import pathlib
import signal
import stat
import sys
import tempfile
import unittest
from unittest import mock

from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.x509.oid import NameOID

sys.path.insert(0, str(pathlib.Path(__file__).parents[1] / "scripts"))
import install_certificate as installer  # noqa: E402


HOSTNAME = "vault.monosense.io"


def make_pair(
    serial: int,
    *,
    hostname: str | None = HOSTNAME,
    valid_days: int = 90,
    key: ec.EllipticCurvePrivateKey | None = None,
) -> tuple[bytes, bytes]:
    private_key = key or ec.generate_private_key(ec.SECP256R1())
    now = datetime.datetime.now(datetime.timezone.utc)
    builder = (
        x509.CertificateBuilder()
        .subject_name(x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, HOSTNAME)]))
        .issuer_name(x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, "Test issuer")]))
        .public_key(private_key.public_key())
        .serial_number(serial)
        .not_valid_before(now - datetime.timedelta(minutes=1))
        .not_valid_after(now + datetime.timedelta(days=valid_days))
    )
    if hostname is not None:
        builder = builder.add_extension(
            x509.SubjectAlternativeName([x509.DNSName(hostname)]), critical=False
        )
    certificate = builder.sign(private_key, hashes.SHA256())
    return (
        certificate.public_bytes(serialization.Encoding.PEM),
        private_key.private_bytes(
            serialization.Encoding.PEM,
            serialization.PrivateFormat.PKCS8,
            serialization.NoEncryption(),
        ),
    )


def write_pair(directory: pathlib.Path, pair: tuple[bytes, bytes]) -> None:
    directory.mkdir(parents=True)
    (directory / "fullchain.pem").write_bytes(pair[0])
    (directory / "privkey.pem").write_bytes(pair[1])


class CertificateInstallerTests(unittest.TestCase):
    def setUp(self) -> None:
        if os.geteuid() != 0:
            self.skipTest("ownership contract requires the root Certbot container")
        self.temporary = tempfile.TemporaryDirectory()
        self.root = pathlib.Path(self.temporary.name)
        os.chmod(self.root, 0o755)
        self.target = self.root / "tls"

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def validate(self, pair: tuple[bytes, bytes], min_valid_days: int = 21):
        lineage = self.root / f"lineage-{len(list(self.root.glob('lineage-*')))}"
        write_pair(lineage, pair)
        return installer.validate_pair(
            lineage / "fullchain.pem", lineage / "privkey.pem", HOSTNAME, min_valid_days
        )

    def install(self, serial: int, **kwargs) -> tuple[bytes, bytes, str]:
        validated = self.validate(make_pair(serial, **kwargs))
        installer.install_pair(*validated, self.target)
        return validated

    def assert_current(self, serial: int) -> None:
        self.assertTrue((self.target / "current").is_symlink())
        self.assertEqual(os.readlink(self.target / "current"), f"releases/{serial:x}")

    def test_valid_pair_installs_complete_owned_generation(self) -> None:
        cert_pem, key_pem, serial = self.install(0xA1)
        generation = self.target / "releases" / serial

        for directory in (self.target, self.target / "releases", generation):
            metadata = directory.stat()
            self.assertEqual((metadata.st_uid, metadata.st_gid), (0, 0))
            self.assertEqual(stat.S_IMODE(metadata.st_mode), 0o755)

        certificate = generation / "fullchain.pem"
        private_key = generation / "privkey.pem"
        self.assertEqual(certificate.read_bytes(), cert_pem)
        self.assertEqual(private_key.read_bytes(), key_pem)
        self.assertEqual(
            (certificate.stat().st_uid, certificate.stat().st_gid, stat.S_IMODE(certificate.stat().st_mode)),
            (100, 1000, 0o644),
        )
        self.assertEqual(
            (private_key.stat().st_uid, private_key.stat().st_gid, stat.S_IMODE(private_key.stat().st_mode)),
            (100, 1000, 0o600),
        )
        self.assert_current(0xA1)

        child = os.fork()
        if child == 0:
            try:
                os.setgroups([])
                os.setgid(1000)
                os.setuid(100)
                if certificate.read_bytes() != cert_pem or private_key.read_bytes() != key_pem:
                    os._exit(1)
                os._exit(0)
            except BaseException:
                os._exit(1)
        _, status = os.waitpid(child, 0)
        self.assertEqual(os.waitstatus_to_exitcode(status), 0)

    def test_mismatched_private_key_is_rejected(self) -> None:
        certificate, _ = make_pair(1)
        _, other_key = make_pair(2)
        with self.assertRaisesRegex(installer.CertificateError, "do not match"):
            self.validate((certificate, other_key))

    def test_missing_san_is_rejected(self) -> None:
        with self.assertRaisesRegex(installer.CertificateError, "no DNS"):
            self.validate(make_pair(3, hostname=None))

    def test_wrong_san_is_rejected(self) -> None:
        with self.assertRaisesRegex(installer.CertificateError, "required hostname"):
            self.validate(make_pair(4, hostname="other.example"))

    def test_expiring_certificate_is_rejected(self) -> None:
        with self.assertRaisesRegex(installer.CertificateError, "validity"):
            self.validate(make_pair(5, valid_days=20))

    def test_failure_before_generation_rename_preserves_current(self) -> None:
        self.install(0x10)
        new_pair = self.validate(make_pair(0x11))
        with mock.patch.object(installer.os, "rename", side_effect=OSError("injected")):
            with self.assertRaises(OSError):
                installer.install_pair(*new_pair, self.target)
        self.assert_current(0x10)
        self.assertFalse((self.target / "releases" / "11").exists())

    def test_failure_before_current_replacement_preserves_current(self) -> None:
        self.install(0x20)
        new_pair = self.validate(make_pair(0x21))
        real_replace = os.replace

        def fail_current(source, destination):
            if pathlib.Path(destination).name == "current":
                raise OSError("injected")
            return real_replace(source, destination)

        with mock.patch.object(installer.os, "replace", side_effect=fail_current):
            with self.assertRaises(OSError):
                installer.install_pair(*new_pair, self.target)
        self.assert_current(0x20)
        self.assertTrue((self.target / "releases" / "21").is_dir())

    def test_repeated_serial_is_idempotent(self) -> None:
        validated = self.install(0x30)
        before = os.readlink(self.target / "current")
        self.assertEqual(installer.install_pair(*validated, self.target), "30")
        self.assertEqual(os.readlink(self.target / "current"), before)
        self.assertEqual([path.name for path in (self.target / "releases").iterdir()], ["30"])

    def test_previous_generation_rolls_back(self) -> None:
        self.install(0x40)
        self.install(0x41)
        self.assertEqual(os.readlink(self.target / "previous"), "releases/40")
        installer.rollback_pair(self.target, None)
        self.assert_current(0x40)
        self.assertEqual(os.readlink(self.target / "previous"), "releases/41")

    def test_rollback_rejects_traversal(self) -> None:
        self.install(0x50)
        (self.target / "previous").symlink_to("../outside")
        with self.assertRaises(installer.CertificateError):
            installer.rollback_pair(self.target, None)

    def test_check_handles_missing_and_expiring_files(self) -> None:
        for target in (self.root / "missing", self.root / "expiring"):
            if target.name == "expiring":
                write_pair(target, make_pair(0x60, valid_days=20))
            with mock.patch.object(
                sys,
                "argv",
                [
                    "install_certificate.py",
                    "check",
                    "--target",
                    str(target),
                    "--hostname",
                    HOSTNAME,
                    "--min-valid-days",
                    "21",
                ],
            ):
                with contextlib.redirect_stderr(io.StringIO()):
                    self.assertEqual(installer.main(), 1)

    def test_install_signals_only_after_successful_switch(self) -> None:
        lineage = self.root / "signal-lineage"
        write_pair(lineage, make_pair(0x70))

        def assert_switched(pid, sent_signal):
            self.assertEqual((pid, sent_signal), (1, signal.SIGHUP))
            self.assert_current(0x70)

        arguments = [
            "install_certificate.py",
            "install",
            "--lineage",
            str(lineage),
            "--target",
            str(self.target),
            "--hostname",
            HOSTNAME,
            "--reload-pid",
            "1",
        ]
        with mock.patch.object(sys, "argv", arguments), mock.patch.object(
            installer.os, "kill", side_effect=assert_switched
        ) as kill:
            self.assertEqual(installer.main(), 0)
            kill.assert_called_once_with(1, signal.SIGHUP)

        failed_lineage = self.root / "failed-signal-lineage"
        write_pair(failed_lineage, make_pair(0x71))
        with mock.patch.object(sys, "argv", [*arguments[:3], str(failed_lineage), *arguments[4:]]), mock.patch.object(
            installer.os, "replace", side_effect=OSError("injected")
        ), mock.patch.object(installer.os, "kill") as failed_kill, contextlib.redirect_stderr(
            io.StringIO()
        ):
            self.assertEqual(installer.main(), 1)
            failed_kill.assert_not_called()
            self.assert_current(0x70)

    def test_rollback_signals_after_switch(self) -> None:
        self.install(0x80)
        self.install(0x81)

        def assert_switched(pid, sent_signal):
            self.assertEqual((pid, sent_signal), (1, signal.SIGHUP))
            self.assert_current(0x80)

        with mock.patch.object(installer.os, "kill", side_effect=assert_switched) as kill:
            installer.rollback_pair(self.target, 1)
            kill.assert_called_once_with(1, signal.SIGHUP)


if __name__ == "__main__":
    unittest.main()
