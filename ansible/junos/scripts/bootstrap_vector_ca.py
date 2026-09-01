#!/usr/bin/env python3
"""Bootstrap and verify the fixed Vector stream CA through administrator NETCONF."""

from __future__ import annotations

import hashlib
import os
import pathlib
import re
import ssl
import sys


def required(name: str) -> str:
    value = os.environ.get(name, "")
    if not value:
        raise RuntimeError(f"missing required runtime value: {name}")
    return value


def normalized_fingerprint(text: str) -> str:
    return re.sub(r"[^0-9A-F]", "", text.upper())


def main() -> int:
    certificate_path = pathlib.Path(__file__).resolve().parents[1] / "files" / "vector-srx-root-ca.pem"
    remote_path = "/var/tmp/vector-srx-root-ca.pem"
    try:
        from jnpr.junos import Device
        from jnpr.junos.utils.config import Config
        from lxml import etree

        if not certificate_path.is_file() or certificate_path.is_symlink():
            raise RuntimeError("tracked Vector CA certificate is missing or unsafe")
        certificate = certificate_path.read_text(encoding="ascii")
        der = ssl.PEM_cert_to_DER_cert(certificate)
        fingerprints = (
            hashlib.sha256(der).hexdigest().upper(),
            hashlib.sha1(der, usedforsecurity=False).hexdigest().upper(),
        )
        if {len(value) for value in fingerprints} != {40, 64}:
            raise RuntimeError("tracked Vector CA certificate fingerprint is invalid")

        with Device(
            host=required("JUNOS_MANAGEMENT_ADDRESS"),
            user=required("JUNOS_NETCONF_USERNAME"),
            port=830,
            ssh_private_key_file=required("JUNOS_NETCONF_PRIVATE_KEY_FILE"),
            ssh_config=required("JUNOS_NETCONF_SSH_CONFIG"),
            hostkey_verify=True,
            look_for_keys=False,
            allow_agent=False,
            gather_facts=False,
        ) as device:
            expected_profile = "\n".join((
                "set security pki ca-profile VECTOR-SRX-ROOT ca-identity VECTOR-SRX-ROOT",
                "set security pki ca-profile VECTOR-SRX-ROOT revocation-check disable",
            ))
            current_profile = device.cli(
                "show configuration security pki ca-profile VECTOR-SRX-ROOT "
                "| display set | no-more",
                warning=False,
            )
            if current_profile.strip() != expected_profile:
                profile_commands = expected_profile
                if current_profile.strip():
                    profile_commands = (
                        "delete security pki ca-profile VECTOR-SRX-ROOT\n"
                        + expected_profile
                    )
                with Config(device, mode="exclusive") as config:
                    config.load(profile_commands, format="set")
                    config.commit_check()
                    config.commit(comment="Bootstrap dedicated Vector SRX CA profile")

            current = device.cli(
                "show security pki ca-certificate ca-profile VECTOR-SRX-ROOT detail | no-more",
                warning=False,
            )
            if any(value in normalized_fingerprint(current) for value in fingerprints):
                print("Dedicated Vector SRX CA certificate already verified")
                return 0
            try:
                device.cli(
                    "request security pki ca-certificate delete ca-profile VECTOR-SRX-ROOT",
                    warning=False,
                )
            except Exception:
                pass

            upload = etree.Element("file-put")
            etree.SubElement(upload, "filename").text = remote_path
            etree.SubElement(upload, "permission").text = "0600"
            etree.SubElement(upload, "encoding").text = "ascii"
            etree.SubElement(upload, "delete-if-exist")
            etree.SubElement(upload, "file-contents").text = certificate
            try:
                device.execute(upload)
                device.cli(
                    "request security pki ca-certificate load "
                    "ca-profile VECTOR-SRX-ROOT filename " + remote_path,
                    warning=False,
                )
            finally:
                try:
                    device.cli(f"file delete {remote_path}", warning=False)
                except Exception:
                    pass

            installed = device.cli(
                "show security pki ca-certificate ca-profile VECTOR-SRX-ROOT detail | no-more",
                warning=False,
            )
            if not any(value in normalized_fingerprint(installed) for value in fingerprints):
                raise RuntimeError("SRX did not retain the exact Vector CA certificate")
        print("Dedicated Vector SRX CA profile and certificate installed and verified")
    except Exception as error:
        print(f"Vector CA bootstrap failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
