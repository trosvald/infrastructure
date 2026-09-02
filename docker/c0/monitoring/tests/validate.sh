#!/usr/bin/env bash
set -euo pipefail
readonly ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
cd "$ROOT"
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
  and .services["vector-prune"].user == "0:0"
  and any(.services.vector.volumes[]; .source == "/var/lib/monosense-monitoring/tls" and .target == "/run/tls" and .read_only == true)
  and .volumes["vector-evidence"] != null
  and .services.gatus.tmpfs == ["/tmp:rw,nosuid,nodev,noexec,size=64m,mode=1777"]
  and .services.vector.tmpfs == ["/tmp:rw,nosuid,nodev,noexec,size=64m,mode=1777"]
  and .services["vector-prune"].tmpfs == ["/tmp:rw,nosuid,nodev,noexec,size=16m,mode=1777"]
  and .services["vector-prune"].cap_add == ["CHOWN"]
  and .services["vector-prune"].entrypoint == ["/bin/sh","-ceu"]
  and .services["vector-prune"].command == ["install -d -o 0 -g 65534 -m 0770 /var/lib/vector/evidence; while :; do find /var/lib/vector/evidence -type f -mtime +13 -delete; sleep 21600; done"]
  and .services.gatus.healthcheck == null
  and .services.vector.depends_on["vector-prune"].condition == "service_started"
' "$rendered" >/dev/null
python3 - <<'PY'
from pathlib import Path
compose = Path("docker/c0/monitoring/compose.yml").read_text()
gatus = Path("docker/c0/monitoring/config/gatus.yaml.template").read_text()
vector = Path("docker/c0/monitoring/config/vector.yaml.template").read_text()
combined = compose + gatus + vector
for value in ("metrics: false", "hide-url: true", "hide-hostname: true", "hide-conditions: true", "hide-errors: true", "@@telegram_bot_token@@", "@@backup_heartbeat_token@@", "external-endpoints:", "heartbeat: { interval: 26h }", "0.0.0.0:6514", "-mtime +13", ".appname", ".msgid", "RT_FLOW", "authorization", "request_body", "https://vlogs-ingest.internal:8444/insert/jsonline", "/run/vector-client/certificate.pem", "type: disk", "when_full: block"):
    assert value in combined, value
assert "if !allowed { abort }" in vector
for value in ("/var/lib/monosense-monitoring/vector-tls", "/run/vector-tls/fullchain.pem", "/run/vector-tls/privkey.pem"):
    assert value in combined, value
assert "0.0.0.0:8686" not in vector and "@@vector_ingest_token@@" in gatus
endpoint_documents = gatus.split("\nendpoints:\n", 1)[1].split("\n  - ")[1:]
assert endpoint_documents and all("\n    alerts: *telegram-alerts" in endpoint for endpoint in endpoint_documents)
assert "verify_certificate: true" in vector and "verify_hostname: true" in vector
for host_endpoint in ("tcp://10.25.13.16:22", "tcp://10.25.10.101:22"):
    assert host_endpoint in gatus, host_endpoint
assert "env_file" not in compose and "MONITORING_" not in compose
for forbidden in ("alertmanager", "/var/run/docker.sock"):
    assert forbidden not in combined.lower(), forbidden
PY
