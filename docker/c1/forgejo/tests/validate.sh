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
  and .networks.outbound.ipam.config == [{"subnet":"172.30.15.64/28"}]
  and ([.services | to_entries[] | select(.value.networks | has("frontend")) | .key] == ["forgejo"])
  and ([.services | to_entries[] | select(.value.networks | has("database")) | .key] | sort) == ["forgejo","postgres"]
  and .services.forgejo.healthcheck.test == ["CMD","wget","--spider","--quiet","http://127.0.0.1:3000/api/healthz"]
  and .services.postgres.healthcheck.test == ["CMD-SHELL","pg_isready -U forgejo -d forgejo"]
  and ([.services.forgejo.volumes[].source] | sort) == (["/srv/applications/apps/forgejo/app/archives","/srv/applications/apps/forgejo/app/attachments","/srv/applications/apps/forgejo/app/avatars","/srv/applications/apps/forgejo/app/lfs","/srv/applications/apps/forgejo/app/packages","/srv/applications/apps/forgejo/app/queues","/srv/applications/apps/forgejo/app/repositories","/srv/applications/apps/forgejo/app/sessions","/srv/applications/apps/forgejo/app/ssh","/srv/applications/apps/forgejo/logs/forgejo","/srv/applications/apps/forgejo/staging","/srv/applications/apps/forgejo/secrets/app.ini","/srv/applications/apps/forgejo/secrets/bootstrap_admin_email","/srv/applications/apps/forgejo/secrets/bootstrap_admin_password"] | sort)
' "$rendered" >/dev/null
python3 - <<'PY'
from pathlib import Path
compose = Path("docker/c1/forgejo/compose.yml").read_text()
template = Path("docker/c1/forgejo/config/app.ini.template").read_text()
assert "${FORGEJO_" not in compose
for value in ("ROOT_URL = https://git.monosense.io/", "SSH_SERVER_USE_PROXY_PROTOCOL = true", "SSH_PORT = 22", "DISABLE_REGISTRATION = true", "DEFAULT_PRIVATE = private", "ENABLED = false", "MAX_SIZE = 10240", "MAX_FILE_SIZE = 10737418240", "smtp+starttls", "smtp.zoho.com", "FORCE_TRUST_SERVER_CERT = false"):
    assert value in template, value
bootstrap = Path("docker/c1/forgejo/scripts/bootstrap-admin.sh").read_text()
assert 'username="trosvald"' in bootstrap
assert '--must-change-password=false' in bootstrap
backup = Path("docker/c1/forgejo/scripts/backup.sh").read_text()
for value in ('python3 "$RUNTIME_HELPER" drain', 'docker stop --time 60 "$FORGEJO"', '--volumes-from "$FORGEJO"', 'docker exec "$POSTGRES" pg_dump', 'kopia snapshot verify', 'docker start "$FORGEJO"', 'backups_forgejo-backup/external?success=true', 'Authorization: Bearer $heartbeat_token'):
    assert value in backup, value
PY
