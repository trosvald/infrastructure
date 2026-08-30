#!/usr/bin/env bash
set -euo pipefail
readonly ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
cd "$ROOT"
export MONITORING_WILDCARD_FULLCHAIN_PEM=x MONITORING_WILDCARD_PRIVATE_KEY_PEM=x
export MONITORING_JUNOS_CA_PEM=x MONITORING_TELEGRAM_BOT_TOKEN=x
export MONITORING_TELEGRAM_CHAT_ID=x MONITORING_VECTOR_INGEST_TOKEN=x
rendered="$(mktemp)"
trap 'rm -f "$rendered"' EXIT
docker compose -f docker/c0/monitoring/compose.yml config --format json >"$rendered"
jq -e '
  .name == "monitoring-c0"
  and (.services | with_entries(.value = .value.image)) == {
    "gatus":"docker.io/twinproduction/gatus:v5.36.0@sha256:8df964117ac6a78749ec8cd00039a499268156b874c3a110dc58de7e312c1ab5",
    "vector":"docker.io/timberio/vector:0.58.0-alpine@sha256:645f51687e293577f2134d2907444da139538710f3c334f091c6070e122ef2ee",
    "vector-prune":"docker.io/timberio/vector:0.58.0-alpine@sha256:645f51687e293577f2134d2907444da139538710f3c334f091c6070e122ef2ee"
  }
  and (.services | keys | sort) == ["gatus","vector","vector-prune"]
  and all(.services[]; ((.ports // []) | length) == 0 and .privileged != true and .read_only == true and .cap_drop == ["ALL"] and .security_opt == ["no-new-privileges:true"])
  and all(.services[]; all((.volumes // [])[]; .source != "/var/run/docker.sock"))
  and .services.gatus.networks.c0_services.ipv4_address == "10.25.13.36"
  and .services.vector.networks.c0_services.ipv4_address == "10.25.13.37"
  and ([.services | to_entries[] | select(.value.networks.c0_services? != null) | .key] | sort) == ["gatus","vector"]
  and .services["vector-prune"].networks == {"maintenance":null}
  and .services.gatus.user == "65534:65534"
  and .services.vector.user == "65534:65534"
  and .volumes["vector-evidence"] != null
' "$rendered" >/dev/null
python3 - <<'PY'
from pathlib import Path
compose = Path("docker/c0/monitoring/compose.yml").read_text()
for value in ("metrics: false", "hide-url: true", "hide-hostname: true", "hide-conditions: true", "hide-errors: true", "MONITORING_TELEGRAM_BOT_TOKEN", "MONITORING_BACKUP_HEARTBEAT_TOKEN", "external-endpoints:", "heartbeat: { interval: 26h }", "0.0.0.0:8686", "strategy: custom", "Bearer \" + token", "0.0.0.0:6514", "-mtime +13", "authorization", "request_body"):
    assert value in compose, value
for forbidden in ("victoriametrics", "victorialogs", "alertmanager", "/var/run/docker.sock"):
    assert forbidden not in compose.lower(), forbidden
PY
