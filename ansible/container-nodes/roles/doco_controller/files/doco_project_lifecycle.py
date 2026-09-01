#!/usr/bin/python3
"""Start or stop an allowlisted, already-deployed Doco-CD project."""

import os
import stat
import sys
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

API_SECRET_FILE = Path(os.environ.get("DOCO_API_SECRET_FILE", "/opt/doco-cd/secrets/api_secret"))
ALLOWLIST_FILE = Path(os.environ.get("DOCO_PROJECT_ALLOWLIST", "/etc/monosense/doco-projects"))
API_URL = os.environ.get("DOCO_API_URL", "http://127.0.0.1:8080").rstrip("/")
TIMEOUT = 40


def fail(message: str) -> "NoReturn":
    raise SystemExit(f"doco-project-lifecycle: {message}")


def read_protected(path: Path, expected_mode: int) -> str:
    try:
        metadata = path.lstat()
    except FileNotFoundError:
        fail(f"protected file is missing: {path}")
    if stat.S_ISLNK(metadata.st_mode) or not stat.S_ISREG(metadata.st_mode):
        fail(f"protected path is not a regular non-symlink file: {path}")
    if metadata.st_uid != 0 or metadata.st_gid != 0 or stat.S_IMODE(metadata.st_mode) != expected_mode:
        fail(f"protected file custody mismatch: {path}")
    value = path.read_text(encoding="utf-8")
    if not value:
        fail(f"protected file is empty: {path}")
    return value


def main() -> None:
    if os.geteuid() != 0:
        fail("must run as root")
    if len(sys.argv) != 3 or sys.argv[1] not in {"start", "stop"}:
        fail("usage: doco-project-lifecycle start|stop PROJECT")
    action, project = sys.argv[1:]
    allowlist = {line for line in read_protected(ALLOWLIST_FILE, 0o600).splitlines() if line}
    if project not in allowlist:
        fail(f"project is not allowlisted: {project}")
    secret = read_protected(API_SECRET_FILE, 0o600)
    if secret != secret.strip() or any(character.isspace() for character in secret):
        fail("Doco API secret has invalid whitespace")
    encoded_project = urllib.parse.quote(project, safe="")
    url = f"{API_URL}/v1/api/project/{encoded_project}/{action}?timeout=30"
    request = urllib.request.Request(url, method="POST", headers={"X-API-Key": secret})
    try:
        with urllib.request.urlopen(request, timeout=TIMEOUT) as response:
            if not 200 <= response.status < 300:
                fail(f"Doco API returned HTTP {response.status} for {action} {project}")
    except urllib.error.HTTPError as error:
        fail(f"Doco API returned HTTP {error.code} for {action} {project}")
    except (urllib.error.URLError, TimeoutError) as error:
        fail(f"Doco API {action} failed for {project}: {error.reason if hasattr(error, 'reason') else error}")


if __name__ == "__main__":
    main()
