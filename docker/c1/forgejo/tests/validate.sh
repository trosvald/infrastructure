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
  and ([.services.forgejo.volumes[].source] | sort) == (["/srv/applications/apps/forgejo/app","/srv/applications/apps/forgejo/logs/forgejo","/srv/applications/apps/forgejo/staging","/srv/applications/apps/forgejo/secrets/app.ini"] | sort)
' "$rendered" >/dev/null
python3 - <<'PY'
import importlib.util
import os
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


def exercise(existing):
    state = {"revoked": False}
    events = []

    def fake_run(*args):
        events.append(("run", args))
        if args[:3] == ("docker", "inspect", mirror.CONTAINER):
            return "172.30.15.3"
        if "generate-access-token" in args:
            assert args[args.index("--config") + 1] == "/etc/gitea/conf/app.ini"
            token_name = args[args.index("--token-name") + 1]
            assert token_name.startswith(mirror.TOKEN_NAME + "-")
            assert token_name != mirror.TOKEN_NAME
            return "Access token was successfully created: test-token"
        assert args[:3] == ("docker", "exec", mirror.POSTGRES_CONTAINER)
        assert "DELETE FROM access_token" in args[-1]
        assert f"LIKE '{mirror.TOKEN_NAME}%'" in args[-1]
        state["revoked"] = True
        return "DELETE 1"

    def fake_request(base, token, method, path, data=None):
        events.append(("request", method, path, data))
        assert base == "http://172.30.15.3:3000"
        assert token == "test-token"
        if path == "/api/v1/user":
            if state["revoked"]:
                raise urllib.error.HTTPError(path, 401, "revoked", None, None)
            return {"id": 7, "is_admin": True}
        if path == f"/api/v1/repos/{mirror.USERNAME}/infrastructure":
            if existing is None:
                raise urllib.error.HTTPError(path, 404, "missing", None, None)
            return existing
        if path == f"/api/v1/users/{mirror.LEGACY_USERNAME}":
            if existing is None:
                raise urllib.error.HTTPError(path, 404, "missing", None, None)
            return {"login": mirror.LEGACY_USERNAME}
        return None

    mirror.run = fake_run
    mirror.request = fake_request
    assert mirror.main() == 0
    assert state["revoked"]
    return events


created = exercise(None)
assert any(event[0:3] == ("request", "POST", "/api/v1/repos/migrate") for event in created)
updated = exercise({"mirror": True, "mirror_updated": "2026-09-01T02:00:00Z"})
assert any(
    event[0:3]
    == ("request", "DELETE", f"/api/v1/admin/users/{mirror.LEGACY_USERNAME}?purge=true")
    for event in updated
)
PY
