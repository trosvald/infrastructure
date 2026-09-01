#!/usr/bin/env python3
from __future__ import annotations

import json
import subprocess
import urllib.error
import urllib.request
import uuid

CONTAINER = "forgejo-c1"
POSTGRES_CONTAINER = "forgejo-postgres-c1"
USERNAME = "trosvald"
LEGACY_USERNAME = "mono-admin"
TOKEN_NAME = "bootstrap-infrastructure-mirror"
OPENER = urllib.request.build_opener(urllib.request.ProxyHandler({}))


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
    with OPENER.open(req, timeout=15) as response:
        if response.status == 204 or response.length == 0:
            return None
        return json.load(response)


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
    token_name = f"{TOKEN_NAME}-{uuid.uuid4().hex}"
    output = run(
        "docker",
        "exec",
        CONTAINER,
        "forgejo",
        "--config",
        "/etc/gitea/conf/app.ini",
        "admin",
        "user",
        "generate-access-token",
        "--username",
        USERNAME,
        "--token-name",
        token_name,
        "--scopes",
        "all",
    )
    token = output.rsplit(maxsplit=1)[-1]
    try:
        user = request(base, token, "GET", "/api/v1/user")
        if not user.get("is_admin"):
            raise SystemExit(f"{USERNAME} is not a Forgejo administrator")
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
        elif not existing.get("mirror") or existing.get("mirror_updated") is None:
            raise SystemExit("existing infrastructure repository is not a refreshed pull mirror")
        try:
            request(base, token, "GET", f"/api/v1/users/{LEGACY_USERNAME}")
        except urllib.error.HTTPError as error:
            if error.code != 404:
                raise
        else:
            request(
                base,
                token,
                "DELETE",
                f"/api/v1/admin/users/{LEGACY_USERNAME}?purge=true",
            )
    finally:
        # Forgejo 16 removed the CLI revocation command, and its administrative token
        # endpoints require password authentication. Delete only this script's tokens.
        run(
            "docker",
            "exec",
            POSTGRES_CONTAINER,
            "psql",
            "--no-psqlrc",
            "--username",
            "forgejo",
            "--dbname",
            "forgejo",
            "--set",
            "ON_ERROR_STOP=1",
            "--command",
            (
                'DELETE FROM access_token WHERE uid = '
                f'(SELECT id FROM "user" WHERE lower_name = \'{USERNAME}\') '
                f"AND name LIKE '{TOKEN_NAME}%';"
            ),
        )
        try:
            request(base, token, "GET", "/api/v1/user")
        except urllib.error.HTTPError as error:
            if error.code not in (401, 403):
                raise
        else:
            raise SystemExit("temporary Forgejo access token remains valid after revocation")
    print("Forgejo infrastructure pull mirror is configured without a GitHub writer")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
