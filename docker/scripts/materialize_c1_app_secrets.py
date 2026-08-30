#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import os
import pathlib
import re
import ssl
import stat
import tempfile
import urllib.error
import urllib.request


class MaterializeError(Exception):
    pass


EDGE_KEYS = {
    "acme_email",
    "cloudflare_dns_token",
    "maxmind_account_id",
    "maxmind_license_key",
    "crowdsec_lapi_key",
    "crowdsec_bouncer_key",
    "vector_ingest_token",
}
FORGEJO_KEYS = {
    "postgres_password",
    "forgejo_secret_key",
    "forgejo_internal_token",
    "forgejo_jwt_secret",
    "forgejo_lfs_jwt_secret",
    "bootstrap_admin_password",
    "bootstrap_admin_email",
    "zoho_username",
    "zoho_password",
    "kopia_repository_password",
    "librefs_access_key",
    "librefs_secret_key",
}


def read_token(path: pathlib.Path) -> str:
    metadata = path.stat()
    if path.is_symlink() or not stat.S_ISREG(metadata.st_mode) or metadata.st_mode & 0o077:
        raise MaterializeError("OpenBao token file is unsafe")
    token = path.read_text(encoding="utf-8").strip()
    if not token or re.search(r"\s", token):
        raise MaterializeError("OpenBao token is invalid")
    return token


def fetch(url: str, token: str, record: str, expected: set[str]) -> dict[str, str]:
    request = urllib.request.Request(
        f"{url.rstrip('/')}/v1/kv/data/docker/c1/{record}",
        headers={"X-Vault-Token": token},
    )
    with urllib.request.urlopen(request, context=ssl.create_default_context(), timeout=15) as response:
        data = json.load(response)["data"]["data"]
    if set(data) != expected or any(not isinstance(data[key], str) or not data[key] for key in expected):
        raise MaterializeError(f"{record} record differs from the exact secret contract")
    return data


def render(template: pathlib.Path, values: dict[str, str]) -> str:
    text = template.read_text(encoding="utf-8")
    for key, value in values.items():
        marker = f"@@{key}@@"
        if marker in text:
            text = text.replace(marker, value)
    unresolved = sorted(set(re.findall(r"@@([a-z0-9_]+)@@", text)))
    if unresolved:
        raise MaterializeError(f"unresolved template fields: {', '.join(unresolved)}")
    return text


def install(path: pathlib.Path, content: str, uid: int, gid: int) -> None:
    path.parent.mkdir(mode=0o755, parents=True, exist_ok=True)
    if path.parent.is_symlink() or path.is_symlink():
        raise MaterializeError(f"unsafe secret path: {path}")
    os.chown(path.parent, 0, 0)
    os.chmod(path.parent, 0o755)
    descriptor, temporary_name = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    temporary = pathlib.Path(temporary_name)
    try:
        os.fchmod(descriptor, 0o400)
        os.fchown(descriptor, uid, gid)
        with os.fdopen(descriptor, "w", encoding="utf-8") as stream:
            stream.write(content)
            if not content.endswith("\n"):
                stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
        directory = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY)
        try:
            os.fsync(directory)
        finally:
            os.close(directory)
    finally:
        temporary.unlink(missing_ok=True)


def main() -> int:
    parser = argparse.ArgumentParser(description="Materialize c1 application secrets from OpenBao")
    parser.add_argument("--token-file", type=pathlib.Path, default=pathlib.Path("/opt/doco-cd/secrets/openbao-token"))
    parser.add_argument("--edge-root", type=pathlib.Path, default=pathlib.Path("/srv/applications/apps/edge/secrets"))
    parser.add_argument("--forgejo-root", type=pathlib.Path, default=pathlib.Path("/srv/applications/apps/forgejo/secrets"))
    parser.add_argument("--template-root", type=pathlib.Path, default=pathlib.Path("/usr/local/share/c1-app-secrets"))
    parser.add_argument("--url", default="https://vault.monosense.io:8200")
    args = parser.parse_args()
    try:
        if os.geteuid() != 0:
            raise MaterializeError("materializer must run as root")
        token = read_token(args.token_file)
        edge = fetch(args.url, token, "edge", EDGE_KEYS)
        forgejo = fetch(args.url, token, "forgejo", FORGEJO_KEYS)
        install(args.edge_root / "bouncer_key_spoa", edge["crowdsec_bouncer_key"], 1000, 1000)
        install(args.edge_root / "spoa.yaml", render(args.template_root / "spoa.yaml", edge), 1000, 1000)
        install(args.edge_root / "cloudflare.ini", f"dns_cloudflare_api_token = {edge['cloudflare_dns_token']}", 0, 0)
        install(args.edge_root / "acme_email", edge["acme_email"], 0, 0)
        install(args.edge_root / "GeoIP.conf", render(args.template_root / "GeoIP.conf", edge), 1000, 1000)
        install(args.edge_root / "vector_token", edge["vector_ingest_token"], 1000, 1000)
        install(args.forgejo_root / "app.ini", render(args.template_root / "app.ini", forgejo), 1000, 1000)
        install(args.forgejo_root / "postgres_password", forgejo["postgres_password"], 70, 70)
        install(args.forgejo_root / "kopia_password", forgejo["kopia_repository_password"], 1000, 1000)
        install(args.forgejo_root / "librefs_access_key", forgejo["librefs_access_key"], 1000, 1000)
        install(args.forgejo_root / "librefs_secret_key", forgejo["librefs_secret_key"], 1000, 1000)
        install(args.forgejo_root / "bootstrap_admin_password", forgejo["bootstrap_admin_password"], 1000, 1000)
        install(args.forgejo_root / "bootstrap_admin_email", forgejo["bootstrap_admin_email"], 1000, 1000)
    except (KeyError, OSError, TypeError, ValueError, MaterializeError, urllib.error.URLError) as error:
        print(f"c1 secret materialization failed: {error}", file=os.sys.stderr)
        return 1
    print("c1 application secrets materialized into protected runtime files")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
