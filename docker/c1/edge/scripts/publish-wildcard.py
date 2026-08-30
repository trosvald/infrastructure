#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import os
import pathlib
import re
import ssl
import stat
import urllib.error
import urllib.request

from cryptography import x509

import install_certificate


class PublishError(Exception):
    pass


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--target", required=True, type=pathlib.Path)
    parser.add_argument("--token-file", required=True, type=pathlib.Path)
    parser.add_argument("--url", default="https://vault.monosense.io:8200")
    args = parser.parse_args()
    try:
        token_stat = args.token_file.stat()
        if not stat.S_ISREG(token_stat.st_mode) or args.token_file.is_symlink():
            raise PublishError("publisher token path is unsafe")
        if token_stat.st_mode & 0o077:
            raise PublishError("publisher token must not be accessible by group or other")
        token = args.token_file.read_text(encoding="utf-8").strip()
        if not token or re.search(r"\s", token):
            raise PublishError("publisher token is invalid")
        current = args.target / "current"
        cert_pem, key_pem, serial = install_certificate.validate_pair(
            current / "fullchain.pem", current / "privkey.pem", "*.monosense.io", 14
        )
        certificate = x509.load_pem_x509_certificate(cert_pem)
        leaf_match = re.search(
            br"-----BEGIN CERTIFICATE-----\r?\n.*?-----END CERTIFICATE-----\r?\n?",
            cert_pem,
            re.DOTALL,
        )
        if leaf_match is None:
            raise PublishError("full chain contains no certificate")
        not_after = certificate.not_valid_after_utc.isoformat().replace("+00:00", "Z")
        payload = json.dumps(
            {
                "data": {
                    "certificate": leaf_match.group().decode("ascii"),
                    "fullchain": cert_pem.decode("ascii"),
                    "private_key": key_pem.decode("ascii"),
                    "serial": serial,
                    "not_after": not_after,
                }
            }
        ).encode()
        request = urllib.request.Request(
            args.url.rstrip("/") + "/v1/kv/data/platform/tls/monosense-wildcard",
            data=payload,
            method="POST",
            headers={"Content-Type": "application/json", "X-Vault-Token": token},
        )
        with urllib.request.urlopen(request, context=ssl.create_default_context(), timeout=15) as response:
            if response.status not in (200, 204):
                raise PublishError(f"OpenBao returned HTTP {response.status}")
    except (OSError, ValueError, PublishError, urllib.error.URLError) as error:
        print(f"wildcard publication failed: {error}", file=os.sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
