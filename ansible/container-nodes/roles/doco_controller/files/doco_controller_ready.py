#!/usr/bin/python3
"""Bounded authenticated readiness gate for the local Doco-CD controller."""

import json
import os
import stat
import time
import urllib.error
import urllib.request
from pathlib import Path

SECRET_FILE = Path(os.environ.get("DOCO_API_SECRET_FILE", "/opt/doco-cd/secrets/api_secret"))
API_URL = os.environ.get("DOCO_API_URL", "http://127.0.0.1:8080").rstrip("/")


def fail(message: str) -> "NoReturn":
    raise SystemExit(f"doco-controller-ready: {message}")


def main() -> None:
    if os.geteuid() != 0:
        fail("must run as root")
    try:
        metadata = SECRET_FILE.lstat()
    except FileNotFoundError:
        fail(f"API secret is missing: {SECRET_FILE}")
    if (stat.S_ISLNK(metadata.st_mode) or not stat.S_ISREG(metadata.st_mode)
            or metadata.st_uid != 0 or metadata.st_gid != 0
            or stat.S_IMODE(metadata.st_mode) != 0o600):
        fail(f"API secret custody mismatch: {SECRET_FILE}")
    secret = SECRET_FILE.read_text(encoding="utf-8")
    if not secret or secret != secret.strip() or any(character.isspace() for character in secret):
        fail("API secret has invalid whitespace")
    request = urllib.request.Request(
        f"{API_URL}/v1/api/projects", headers={"X-API-Key": secret}
    )
    last_error = "controller did not answer"
    deadline = time.monotonic() + 90
    while time.monotonic() < deadline:
        try:
            with urllib.request.urlopen(request, timeout=2) as response:
                payload = json.load(response)
                if 200 <= response.status < 300 and isinstance(payload.get("content"), list):
                    return
                last_error = f"invalid authenticated response (HTTP {response.status})"
        except (urllib.error.URLError, TimeoutError, ValueError) as error:
            last_error = str(error)
        remaining = deadline - time.monotonic()
        if remaining > 0:
            time.sleep(min(1, remaining))
    fail(f"controller was not authenticated-ready within 90 seconds: {last_error}")


if __name__ == "__main__":
    main()
