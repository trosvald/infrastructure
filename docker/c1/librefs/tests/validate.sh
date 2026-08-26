#!/usr/bin/env bash
set -euo pipefail
readonly ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
readonly COMPOSE="$ROOT/docker/c1/librefs/compose.yml"
rendered="$(mktemp)"; trap 'rm -f "$rendered"' EXIT
LIBREFS_ROOT_USER=C1_SAFE_CANARY_USER LIBREFS_ROOT_PASSWORD=C1_SAFE_CANARY_PASSWORD_NOT_FOR_USE \
  docker compose -f "$COMPOSE" config --format json >"$rendered"
python3 - "$rendered" "$COMPOSE" <<'PY'
import json,sys
from pathlib import Path
r=json.load(open(sys.argv[1])); source=Path(sys.argv[2]).read_text()
assert r["name"] == "librefs-c1" and set(r["services"]) == {"librefs"}
s=r["services"]["librefs"]
assert s["image"] == "ghcr.io/librefs/librefs:release.2026-05-04t00-42-47z@sha256:707de0b1fa0ff7c83dd72ad4bcd8225302f06a4ce5278b7356700401e95004ab"
assert s["platform"] == "linux/amd64" and s["container_name"] == "librefs-c1"
assert s["command"] == ["server","/data","--console-address",":9001"] and s["user"] == "1000:1000"
assert s["read_only"] is True and s["restart"] == "no"
assert s["environment"] == {"HOME":"/tmp","MINIO_ROOT_PASSWORD_FILE":"/run/secrets/librefs_root_password","MINIO_ROOT_USER_FILE":"/run/secrets/librefs_root_user"}
assert s["cap_drop"] == ["ALL"] and s["security_opt"] == ["no-new-privileges:true"]
assert s["tmpfs"] == ["/tmp:rw,nosuid,nodev,noexec,mode=1777"]
assert s["volumes"] == [{"type":"bind","source":"/srv/librefs/data","target":"/data","bind":{"create_host_path":False}}]
assert s["networks"] == {"c1_services":{"ipv4_address":"10.25.13.65"}}
network=r["networks"]["c1_services"]
assert network["name"] == "c1_services" and network["external"] is True
assert network.get("ipam", {}) == {}
assert {(x["source"],x["target"]) for x in s["secrets"]} == {
 ("librefs_root_user","/run/secrets/librefs_root_user"),
 ("librefs_root_password","/run/secrets/librefs_root_password"),
}
assert r["secrets"]["librefs_root_user"]["environment"] == "LIBREFS_ROOT_USER"
assert r["secrets"]["librefs_root_password"]["environment"] == "LIBREFS_ROOT_PASSWORD"
assert not any(k in s for k in ("ports","expose","devices","privileged","network_mode","pid","ipc"))
assert "docker.sock" not in json.dumps(r).lower() and ":latest" not in source
assert s["cpus"] == 4.0 and s["mem_limit"] == "8589934592"
assert s["memswap_limit"] == "8589934592" and s["pids_limit"] == 512
assert s["ulimits"]["nofile"] == {"soft":65536,"hard":65536}
assert s["stop_grace_period"] == "1m0s"
assert s["logging"] == {"driver":"json-file","options":{"max-file":"3","max-size":"10m"}}
h=s["healthcheck"]; assert h["interval"] == "30s" and h["timeout"] == "5s" and h["retries"] == 3 and h["start_period"] == "1m0s"
assert h["test"][:3] == ["CMD","/usr/bin/bash","-ceu"]
command=h["test"][3]
assert "/dev/tcp/127.0.0.1/9000" in command
assert "GET /minio/health/ready HTTP/1.0" in command and "Host: localhost" in command
assert ('[[ "$status" == *" 200 "* ]]' in command
        or '[[ "$$status" == *" 200 "* ]]' in command)
assert "C1_SAFE_CANARY" not in json.dumps(r)
assert "MINIO_ROOT_USER:" not in source and "MINIO_ROOT_PASSWORD:" not in source
PY
printf 'libreFS rendered Compose contract passed\n'
