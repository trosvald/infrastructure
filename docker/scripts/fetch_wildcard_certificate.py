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
        request = urllib.request.Request(
            args.url.rstrip("/") + "/v1/kv/data/platform/tls/monosense-wildcard",
            headers={"X-Vault-Token": token},
        )
        with urllib.request.urlopen(request, context=ssl.create_default_context(), timeout=15) as response:
            record = json.load(response)["data"]["data"]
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
    except (KeyError, TypeError, UnicodeError, OSError, ValueError, FetchError, urllib.error.URLError) as error:
        print(f"wildcard fetch failed: {error}", file=os.sys.stderr)
        return 1
    finally:
        if temporary is not None:
            shutil.rmtree(temporary, ignore_errors=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
