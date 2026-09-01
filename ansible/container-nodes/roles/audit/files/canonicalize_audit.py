#!/usr/bin/env python3
"""Sanitize and canonicalize container-node audit evidence."""

from __future__ import annotations

import argparse
import hashlib
import json
import sys
from pathlib import Path
from typing import Any

SCHEMA_VERSION = 1
PRIVATE_KEYS = {
    "machine_id",
    "product_uuid",
    "product_serial",
    "serial_number",
    "wwn",
    "mac_address",
    "host_public_key",
    "host_key",
    "ip_address",
    "device_id",
    "filesystem_uuid",
    "host_key_fingerprint",
    "management_address",
    "system_uuid",
}
SECRET_FRAGMENTS = ("password", "private_key", "secret", "token", "credential")


def _digest(value: Any) -> str:
    encoded = json.dumps(value, ensure_ascii=True, sort_keys=True, separators=(",", ":")).encode()
    return "sha256:" + hashlib.sha256(encoded).hexdigest()


def sanitize(value: Any, key: str = "") -> Any:
    lowered = key.lower()
    if any(fragment in lowered for fragment in SECRET_FRAGMENTS):
        raise ValueError(f"secret-bearing field is forbidden: {key}")
    if lowered in PRIVATE_KEYS or lowered.endswith(("_serial", "_uuid", "_wwn", "_mac", "_address")):
        if isinstance(value, str) and value.startswith("sha256:") and len(value) == 71:
            return value
        return _digest(value)
    if isinstance(value, dict):
        return {str(k): sanitize(v, str(k)) for k, v in value.items()}
    if isinstance(value, list):
        return [sanitize(item) for item in value]
    if value is None or isinstance(value, (str, int, float, bool)):
        return value
    raise ValueError(f"unsupported audit value type: {type(value).__name__}")


def canonicalize(value: Any) -> bytes:
    if not isinstance(value, dict):
        raise ValueError("audit input must be a JSON object")
    if value.get("schema_version") != SCHEMA_VERSION:
        raise ValueError(f"audit schema_version must be {SCHEMA_VERSION}")
    return (json.dumps(sanitize(value), ensure_ascii=True, sort_keys=True, separators=(",", ":")) + "\n").encode()


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("input", nargs="?", help="JSON input file; stdin when omitted")
    parser.add_argument("--output", help="write canonical JSON atomically to this path")
    parser.add_argument("--sha256-only", action="store_true")
    args = parser.parse_args()
    raw = Path(args.input).read_bytes() if args.input else sys.stdin.buffer.read()
    try:
        canonical = canonicalize(json.loads(raw))
    except (OSError, UnicodeError, json.JSONDecodeError, ValueError) as exc:
        print(f"audit canonicalization failed: {exc}", file=sys.stderr)
        return 2
    digest = hashlib.sha256(canonical).hexdigest()
    if args.output:
        destination = Path(args.output)
        temporary = destination.with_name(destination.name + ".tmp")
        temporary.write_bytes(canonical)
        temporary.replace(destination)
    if args.sha256_only:
        print(digest)
    else:
        sys.stdout.buffer.write(canonical)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
