#!/usr/bin/env bash
set -euo pipefail
readonly ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
cd "$ROOT"
rendered="$(mktemp)"
trap 'rm -f "$rendered"' EXIT
docker compose -f docker/c1/edge/compose.yml config --format json >"$rendered"
jq -e '
  .name == "edge-c1"
  and (.services | with_entries(.value = .value.image)) == {
    "certbot":"docker.io/certbot/dns-cloudflare:v5.7.0@sha256:ed5e95feb4d64690df77b4628876f3b72ae856d6e0acd51927a2fd45baf1ccd2",
    "crowdsec":"docker.io/crowdsecurity/crowdsec:v1.7.8@sha256:95a25d0f0fb92d96204e74fd48a5c4bd2c949b1b2a31769fa3487ad4769314e1",
    "geoipupdate":"docker.io/maxmindinc/geoipupdate:v7.1.1@sha256:45e15eb310528fd308c5c0abee9a8e6d580f1e2b1251e960dec2863dc7f0102f",
    "haproxy":"docker.io/library/haproxy:3.2.23-alpine@sha256:0666a2c2f41d341084ed2da85392b48cdcd766adfa28231f31305724ed5c6ea5",
    "spoa":"docker.io/crowdsecurity/spoa-bouncer:v0.3.1@sha256:94707833e96caf215160c10dacfb9f13bf71d59136feb574cf425e84010f33f3",
    "vector":"docker.io/timberio/vector:0.58.0-alpine@sha256:645f51687e293577f2134d2907444da139538710f3c334f091c6070e122ef2ee"
  }
  and (.services | keys | sort) == ["certbot","crowdsec","geoipupdate","haproxy","spoa","vector"]
  and all(.services[]; ((.ports // []) | length) == 0 and .privileged != true and .read_only == true and .cap_drop == ["ALL"] and .security_opt == ["no-new-privileges:true"])
  and all(.services[]; all((.volumes // [])[]; .source != "/var/run/docker.sock"))
  and .services.haproxy.networks.c1_edge.ipv4_address == "10.25.15.10"
  and ([.services | to_entries[] | select(.value.networks.c1_edge? != null) | .key] == ["haproxy"])
  and ([.services | to_entries[] | select(.value.networks.forgejo_frontend? != null) | .key] == ["haproxy"])
  and .services.haproxy.cap_add == ["NET_BIND_SERVICE"]
  and .services.haproxy.ulimits.nofile == {"soft":65536,"hard":65536}
  and (.services.haproxy.mem_limit | tonumber) == 1073741824
  and (.services.haproxy.memswap_limit | tonumber) == 1073741824
' "$rendered" >/dev/null
python3 - <<'PY'
from pathlib import Path
cfg = Path("docker/c1/edge/config/haproxy.cfg").read_text()
for value in ("maxconn 1000", "maxconn 500", "maxconn 100", "timeout connect 5s", "timeout http-request 10s", "timeout client 60s", "timeout server 60s", "timeout http-keep-alive 15s", "timeout queue 15s", "timeout tunnel 1h", "sc0_conn_cur gt 20", "sc0_conn_rate gt 60", "sc1_http_req_rate gt 300", "10737418240", "send-proxy-v2", "strict-sni", "alpn h2,http/1.1"):
    assert value in cfg, value
for header in ("Forwarded", "X-Forwarded-For", "X-Forwarded-Host", "X-Forwarded-Proto", "X-Real-IP", "X-Request-ID", "CF-Connecting-IP", "CF-IPCountry", "True-Client-IP"):
    assert f"del-header {header}" in cfg, header
assert "unique-id-header X-Request-ID" not in cfg
assert cfg.count("set-header X-Request-ID %[unique-id]") == 1
compose = Path("docker/c1/edge/compose.yml").read_text()
assert "${EDGE_" not in compose
assert "var(txn.crowdsec.remediation)" in cfg
assert "var(txn.crowdsec.isocode)" in cfg
assert "default_backend reject_unknown" in cfg
assert "SPOA_BYPASS" in cfg and "200ms" in cfg
PY
