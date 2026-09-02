#!/usr/bin/env python3
from __future__ import annotations

import argparse
import hashlib
import json
import os
import pathlib
import subprocess
import time
import urllib.error
import urllib.request
import uuid

CONTAINER = "forgejo-c1"
POSTGRES_CONTAINER = "forgejo-postgres-c1"
USERNAME = "trosvald"
LEGACY_USERNAME = "mono-admin"
AUTOMATION_USERNAME = "flux-image-automation"
REPOSITORY = "infrastructure"
TOKEN_NAME = "bootstrap-infrastructure-source"
PUBLIC_URL = "https://git.monosense.io/trosvald/infrastructure.git"
UPSTREAM_URL = "https://github.com/trosvald/infrastructure.git"
MIRROR_SYNC_TIMEOUT = 120
MIRROR_SYNC_INTERVAL = 2
BACKUP_LOG = pathlib.Path(
    os.environ.get(
        "FORGEJO_BACKUP_LOG",
        "/srv/applications/apps/forgejo/logs/backup/last-success.log",
    )
)
OPENER = urllib.request.build_opener(urllib.request.ProxyHandler({}))


class RefParityError(RuntimeError):
    pass


def run(*args: str) -> str:
    try:
        return subprocess.check_output(args, text=True, timeout=60).strip()
    except subprocess.TimeoutExpired as error:
        raise SystemExit(f"command timed out after 60 seconds: {args[0]}") from error


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


def refs(url: str) -> tuple[str, str]:
    lines = sorted(
        line
        for line in run("git", "ls-remote", "--refs", url).splitlines()
        if line and not line.endswith("^{}")
    )
    if not lines:
        raise SystemExit(f"repository advertises no refs: {url}")
    payload = "\n".join(lines) + "\n"
    return hashlib.sha256(payload.encode()).hexdigest(), payload


def matching_ref_digest() -> str:
    upstream_digest, upstream_refs = refs(UPSTREAM_URL)
    public_digest, public_refs = refs(PUBLIC_URL)
    if public_refs != upstream_refs:
        raise RefParityError(
            "Forgejo/GitHub ref parity failed: "
            f"upstream={upstream_digest} forgejo={public_digest}"
        )
    return public_digest


def prove_parity() -> str:
    try:
        return matching_ref_digest()
    except RefParityError as error:
        raise SystemExit(str(error)) from error


def wait_for_parity(
    timeout: float = MIRROR_SYNC_TIMEOUT,
    interval: float = MIRROR_SYNC_INTERVAL,
) -> str:
    deadline = time.monotonic() + timeout
    while True:
        try:
            return matching_ref_digest()
        except RefParityError as error:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise SystemExit(str(error)) from error
            time.sleep(min(interval, remaining))


def repository(base: str, token: str):
    return request(base, token, "GET", f"/api/v1/repos/{USERNAME}/{REPOSITORY}")


def ensure_public_owner(base: str, token: str) -> None:
    request(
        base,
        token,
        "PATCH",
        f"/api/v1/admin/users/{USERNAME}",
        {"visibility": "public"},
    )
    owner = request(base, token, "GET", f"/api/v1/users/{USERNAME}")
    if owner.get("visibility") != "public":
        # Forgejo releases that map public visibility to enum zero ignore it in
        # the admin API's non-default optional wrapper. Apply the same single
        # field update atomically and verify it through the API.
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
            f'UPDATE "user" SET visibility = 0 WHERE lower_name = \'{USERNAME}\';',
        )
        owner = request(base, token, "GET", f"/api/v1/users/{USERNAME}")
    if owner.get("visibility") != "public":
        raise SystemExit("Forgejo infrastructure owner visibility update failed")


def ensure_public(base: str, token: str) -> None:
    request(
        base,
        token,
        "PATCH",
        f"/api/v1/repos/{USERNAME}/{REPOSITORY}",
        {"private": False},
    )


def prepare(base: str, token: str, user: dict) -> str:
    try:
        existing = repository(base, token)
    except urllib.error.HTTPError as error:
        if error.code != 404:
            raise
        existing = request(
            base,
            token,
            "POST",
            "/api/v1/repos/migrate",
            {
                "clone_addr": UPSTREAM_URL,
                "repo_name": REPOSITORY,
                "repo_owner": USERNAME,
                "uid": user["id"],
                "mirror": True,
                "mirror_interval": "8h0m0s",
                "private": False,
                "service": "git",
            },
        )
    if not existing.get("mirror"):
        raise SystemExit("prepare requires the infrastructure repository to remain a pull mirror")
    request(
        base,
        token,
        "POST",
        f"/api/v1/repos/{USERNAME}/{REPOSITORY}/mirror-sync",
    )
    ensure_public(base, token)
    ensure_public_owner(base, token)
    refreshed = repository(base, token)
    if refreshed.get("private") or refreshed.get("mirror_updated") is None:
        raise SystemExit("Forgejo mirror is not public and refreshed")
    digest = wait_for_parity()
    print(f"Forgejo public mirror prepared at parity digest {digest}")
    return digest


def require_fresh_backup() -> None:
    if not BACKUP_LOG.is_file() or BACKUP_LOG.is_symlink():
        raise SystemExit(f"fresh Forgejo backup evidence is missing: {BACKUP_LOG}")
    age = time.time() - BACKUP_LOG.stat().st_mtime
    if age < 0 or age > 24 * 60 * 60:
        raise SystemExit(f"Forgejo backup evidence is older than 24 hours: {BACKUP_LOG}")
    if not BACKUP_LOG.read_text().strip():
        raise SystemExit(f"Forgejo backup evidence is empty: {BACKUP_LOG}")


def protect_main(base: str, token: str) -> None:
    path = f"/api/v1/repos/{USERNAME}/{REPOSITORY}/branch_protections"
    policy = {
        "rule_name": "main",
        "enable_push": False,
        "enable_push_whitelist": False,
        "push_whitelist_usernames": [],
        "push_whitelist_teams": [],
        "push_whitelist_deploy_keys": False,
        "enable_merge_whitelist": True,
        "merge_whitelist_usernames": [USERNAME],
        "merge_whitelist_teams": [],
        "required_approvals": 1,
        "enable_approvals_whitelist": True,
        "approvals_whitelist_username": [USERNAME],
        "approvals_whitelist_teams": [],
        "block_on_rejected_reviews": True,
        "block_on_official_review_requests": True,
        "block_on_outdated_branch": True,
        "dismiss_stale_approvals": True,
        "ignore_stale_approvals": False,
        "require_signed_commits": False,
        "apply_to_admins": True,
    }
    try:
        request(base, token, "GET", f"{path}/main")
    except urllib.error.HTTPError as error:
        if error.code != 404:
            raise
        request(base, token, "POST", path, policy)
    else:
        request(base, token, "PATCH", f"{path}/main", policy)


def cutover(base: str, token: str) -> None:
    require_fresh_backup()
    existing = repository(base, token)
    if not existing.get("mirror"):
        raise SystemExit("cutover requires a refreshed pull mirror")
    before = prove_parity()
    # Install protection while the pull mirror is intrinsically read-only, so the
    # conversion never exposes an unprotected writable main branch.
    protect_main(base, token)
    request(
        base,
        token,
        "POST",
        f"/api/v1/repos/{USERNAME}/{REPOSITORY}/convert",
    )
    ensure_public(base, token)
    converted = repository(base, token)
    if converted.get("mirror") or converted.get("private"):
        raise SystemExit("Forgejo repository conversion did not produce a public normal repository")
    after = refs(PUBLIC_URL)[0]
    if after != before:
        raise SystemExit(f"post-conversion ref digest changed: before={before} after={after}")
    print(f"Forgejo is the public writable source at parity digest {after}; main is review-protected")


def revoke_token(token: str) -> None:
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


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("mode", choices=("prepare", "cutover"))
    args = parser.parse_args(argv)
    address = run(
        "docker",
        "inspect",
        CONTAINER,
        "--format",
        '{{(index .NetworkSettings.Networks "c1_forgejo_frontend").IPAddress}}',
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
        if args.mode == "prepare":
            prepare(base, token, user)
        else:
            cutover(base, token)
        try:
            request(base, token, "GET", f"/api/v1/users/{LEGACY_USERNAME}")
        except urllib.error.HTTPError as error:
            if error.code != 404:
                raise
        else:
            request(base, token, "DELETE", f"/api/v1/admin/users/{LEGACY_USERNAME}?purge=true")
    finally:
        revoke_token(token)
        try:
            request(base, token, "GET", "/api/v1/user")
        except urllib.error.HTTPError as error:
            if error.code not in (401, 403):
                raise
        else:
            raise SystemExit("temporary Forgejo access token remains valid after revocation")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
