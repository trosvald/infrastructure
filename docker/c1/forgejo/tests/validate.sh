#!/usr/bin/env bash
set -euo pipefail
readonly ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
cd "$ROOT"
rendered="$(mktemp)"
trap 'rm -f "$rendered"' EXIT
docker compose --profile backup -f docker/c1/forgejo/compose.yml config --format json >"$rendered"
jq -e '
  .name == "forgejo-c1"
  and (.services | with_entries(.value = .value.image)) == {
    "forgejo":"codeberg.org/forgejo/forgejo:16.0.3-rootless@sha256:727608279c44f32a18fdc3dc8050f55367f2708cf9edfee8cc61e05b2a6e034e",
    "kopia":"docker.io/kopia/kopia:0.23.1@sha256:83d8bc7bce313dd8b2c17771b5f3f804e18e79ad7d7cc6bc994ff5872374794d",
    "postgres":"docker.io/library/postgres:18.3-alpine@sha256:1b13c640ae11f2f165d1e89667e5862b0017baf4c80fec2fb7377d86319859ba"
  }
  and (.services | keys | sort) == ["forgejo","kopia","postgres"]
  and all(.services[]; ((.ports // []) | length) == 0 and .privileged != true and .read_only == true and .cap_drop == ["ALL"] and .security_opt == ["no-new-privileges:true"])
  and all(.services[]; all((.volumes // [])[]; .source != "/var/run/docker.sock" and (.type != "bind" or .bind.create_host_path == false)))
  and (.services.forgejo.networks | keys | sort) == ["database","frontend","outbound"]
  and (.services.postgres.networks | keys) == ["database"]
  and (.services.kopia.networks | keys) == ["outbound"]
  and .services.forgejo.networks.outbound.ipv4_address == "172.30.15.66"
  and .services.kopia.networks.outbound.ipv4_address == "172.30.15.67"
  and .services.kopia.environment.KOPIA_LOG_DIR == "/logs"
  and .networks.outbound.ipam.config == [{"subnet":"172.30.15.64/28"}]
  and ([.services | to_entries[] | select(.value.networks | has("frontend")) | .key] == ["forgejo"])
  and ([.services | to_entries[] | select(.value.networks | has("database")) | .key] | sort) == ["forgejo","postgres"]
  and .services.forgejo.healthcheck.test == ["CMD","wget","--spider","--quiet","http://127.0.0.1:3000/api/healthz"]
  and .services.postgres.healthcheck.test == ["CMD-SHELL","pg_isready -U forgejo -d forgejo"]
  and ([.services.forgejo.volumes[].source] | sort) == (["/srv/applications/apps/forgejo/app","/srv/applications/apps/forgejo/logs/forgejo","/srv/applications/apps/forgejo/staging","/srv/applications/apps/forgejo/secrets/app.ini","/srv/applications/apps/forgejo/secrets/kubernetes-ca.crt"] | sort)
' "$rendered" >/dev/null
python3 - <<'PY'
import importlib.util
import os
import tempfile
import time
import urllib.error
import urllib.request
from pathlib import Path

compose = Path("docker/c1/forgejo/compose.yml").read_text()
template = Path("docker/c1/forgejo/config/app.ini.template").read_text()
assert "${FORGEJO_" not in compose
for value in ("ROOT_URL = https://git.monosense.io/", "SSH_SERVER_USE_PROXY_PROTOCOL = true", "SSH_PORT = 22", "DISABLE_REGISTRATION = true", "DEFAULT_PRIVATE = private", "ENABLED = false", "MAX_SIZE = 10240", "MAX_FILE_SIZE = 10737418240", "smtp+starttls", "smtp.zoho.com", "FORCE_TRUST_SERVER_CERT = false"):
    assert value in template, value

os.environ["HTTP_PROXY"] = "http://127.0.0.1:9"
spec = importlib.util.spec_from_file_location(
    "configure_mirror", "docker/c1/forgejo/scripts/configure-mirror.py"
)
mirror = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mirror)
os.environ.pop("HTTP_PROXY")
assert not any(isinstance(handler, urllib.request.ProxyHandler) for handler in mirror.OPENER.handlers)

events = []
state = {
    "repo": {"mirror": True, "mirror_updated": "2026-09-01T02:00:00Z", "private": True},
    "protected": False,
    "owner": {"visibility": "private"},
}


def fake_request(base, token, method, path, data=None):
    events.append((method, path, data))
    assert base == "http://forgejo:3000"
    assert token == "token"
    if path == f"/api/v1/admin/users/{mirror.USERNAME}" and method == "PATCH":
        state["owner"]["visibility"] = data["visibility"]
        return state["owner"].copy()
    if path == f"/api/v1/users/{mirror.USERNAME}" and method == "GET":
        return state["owner"].copy()
    repo_path = f"/api/v1/repos/{mirror.USERNAME}/{mirror.REPOSITORY}"
    if path == repo_path and method == "GET":
        return state["repo"].copy()
    if path == repo_path and method == "PATCH":
        state["repo"]["private"] = data["private"]
        return state["repo"].copy()
    if path.endswith("/mirror-sync"):
        return None
    if path.endswith("/convert"):
        state["repo"]["mirror"] = False
        return None
    if path.endswith("/branch_protections/main"):
        if method == "GET" and not state["protected"]:
            raise urllib.error.HTTPError(path, 404, "missing", None, None)
        state["protected"] = True
        return {}
    if path.endswith("/branch_protections"):
        state["protected"] = True
        assert data["rule_name"] == "main"
        assert data["enable_push"] is False
        assert data["required_approvals"] == 1
        assert data["merge_whitelist_usernames"] == [mirror.USERNAME]
        assert mirror.AUTOMATION_USERNAME not in data["merge_whitelist_usernames"]
        return {}
    raise AssertionError((method, path, data))


mirror.request = fake_request
mirror.prove_parity = lambda: "a" * 64
mirror.refs = lambda url: ("a" * 64, "ref")
digest = mirror.prepare("http://forgejo:3000", "token", {"id": 7})
assert digest == "a" * 64
assert state["repo"]["private"] is False
assert state["owner"]["visibility"] == "public"
assert any(path.endswith("/mirror-sync") for _, path, _ in events)

with tempfile.TemporaryDirectory() as directory:
    backup = Path(directory) / "last-success.log"
    backup.write_text("2026-09-01T00:00:00Z generation\n")
    os.utime(backup, (time.time(), time.time()))
    mirror.BACKUP_LOG = backup
    mirror.cutover("http://forgejo:3000", "token")
assert state["repo"] == {
    "mirror": False,
    "mirror_updated": "2026-09-01T02:00:00Z",
    "private": False,
}
assert state["protected"]
assert any(path.endswith("/convert") for _, path, _ in events)

source = Path("docker/c1/forgejo/scripts/configure-mirror.py").read_text()
assert '"private": False' in source
assert 'choices=("prepare", "cutover")' in source
assert "/convert" in source
PY
