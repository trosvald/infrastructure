#!/usr/bin/env python3
from __future__ import annotations

import json
import subprocess
import urllib.error
import urllib.request

CONTAINER = "forgejo-c1"
USERNAME = "trosvald"
TOKEN_NAME = "bootstrap-infrastructure-mirror"


def run(*args: str) -> str:
    return subprocess.check_output(args, text=True).strip()


def request(base: str, token: str, method: str, path: str, data: dict | None = None):
    payload = None if data is None else json.dumps(data).encode()
    req = urllib.request.Request(
        base + path,
        data=payload,
        method=method,
        headers={"Authorization": f"token {token}", "Content-Type": "application/json"},
    )
    with urllib.request.urlopen(req, timeout=15) as response:
        return json.load(response) if response.length != 0 else None


def main() -> int:
    address = run(
        "docker",
        "inspect",
        CONTAINER,
        "--format",
        "{{(index .NetworkSettings.Networks \"c1_forgejo_frontend\").IPAddress}}",
    )
    if not address:
        raise SystemExit("Forgejo frontend address is unavailable")
    base = f"http://{address}:3000"
    output = run(
        "docker",
        "exec",
        CONTAINER,
        "forgejo",
        "admin",
        "user",
        "generate-access-token",
        "--username",
        USERNAME,
        "--token-name",
        TOKEN_NAME,
        "--scopes",
        "all",
    )
    token = output.rsplit(" ", 1)[-1]
    try:
        user = request(base, token, "GET", f"/api/v1/users/{USERNAME}")
        try:
            existing = request(base, token, "GET", f"/api/v1/repos/{USERNAME}/infrastructure")
        except urllib.error.HTTPError as error:
            if error.code != 404:
                raise
            existing = None
        if existing is None:
            request(
                base,
                token,
                "POST",
                "/api/v1/repos/migrate",
                {
                    "clone_addr": "https://github.com/trosvald/infrastructure.git",
                    "repo_name": "infrastructure",
                    "repo_owner": USERNAME,
                    "uid": user["id"],
                    "mirror": True,
                    "mirror_interval": "8h0m0s",
                    "private": True,
                    "service": "git",
                },
            )
        elif not existing.get("mirror") or existing.get("mirror_updated_at") is None:
            raise SystemExit("existing infrastructure repository is not a refreshed pull mirror")
    finally:
        subprocess.run(
            [
                "docker",
                "exec",
                CONTAINER,
                "forgejo",
                "admin",
                "user",
                "delete-access-token",
                "--username",
                USERNAME,
                "--token-name",
                TOKEN_NAME,
            ],
            check=True,
            stdout=subprocess.DEVNULL,
        )
    print("Forgejo infrastructure pull mirror is configured without a GitHub writer")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
