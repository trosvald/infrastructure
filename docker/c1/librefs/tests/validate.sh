#!/usr/bin/env bash
set -euo pipefail
readonly ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
readonly COMPOSE="$ROOT/docker/c1/librefs/compose.yml"
work="$(mktemp -d)"
rendered="$work/rendered.json"
test_id="$$"
test_octet=$((test_id % 180 + 40))
test_network="librefs-config-test-$test_id"
test_container="librefs-c1-config-test-$test_id"
test_volume="librefs-config-test-data-$test_id"
test_subnet="172.29.${test_octet}.0/24"
test_gateway="172.29.${test_octet}.1"
test_ip="172.29.${test_octet}.65"
LIBREFS_ROOT_USER="C1_SAFE_CANARY_USER_$(python3 -c 'import secrets; print(secrets.token_hex(12))')"
LIBREFS_ROOT_PASSWORD="C1_SAFE_CANARY_PASSWORD_$(python3 -c 'import secrets; print(secrets.token_hex(24))')"
export LIBREFS_ROOT_USER LIBREFS_ROOT_PASSWORD
cleanup() {
    docker rm -f "$test_container" >/dev/null 2>&1 || true
    docker network rm "$test_network" >/dev/null 2>&1 || true
    docker volume rm "$test_volume" >/dev/null 2>&1 || true
    rm -rf "$work"
}
trap cleanup EXIT
docker compose -f "$COMPOSE" config --format json >"$rendered"
python3 - "$rendered" "$COMPOSE" <<'PY'
import json,os,sys
from pathlib import Path
r=json.load(open(sys.argv[1])); source=Path(sys.argv[2]).read_text()
assert r["name"] == "librefs-c1" and set(r["services"]) == {"librefs"}
s=r["services"]["librefs"]
assert s["image"] == "ghcr.io/librefs/librefs:release.2026-05-04t00-42-47z@sha256:707de0b1fa0ff7c83dd72ad4bcd8225302f06a4ce5278b7356700401e95004ab"
assert s["platform"] == "linux/amd64" and s["container_name"] == "librefs-c1"
assert s["command"] == ["server","/data","--address",":443","--console-address",":9001","--certs-dir","/certs/current"] and s["user"] == "1000:1000"
assert s.get("read_only",False) is False and s["restart"] == "no"
assert s["environment"] == {"HOME":"/tmp","MINIO_ROOT_PASSWORD_FILE":"/run/secrets/librefs_root_password","MINIO_ROOT_USER_FILE":"/run/secrets/librefs_root_user"}
assert s["cap_drop"] == ["ALL"] and s["security_opt"] == ["no-new-privileges:true"]
assert s["sysctls"] == {"net.ipv4.ip_unprivileged_port_start":"443"}
assert s["tmpfs"] == ["/tmp:rw,nosuid,nodev,noexec,mode=1777"]
volumes={volume["target"]:volume for volume in s["volumes"]}
data=volumes["/data"]
assert data["type"]=="bind" and data["source"]=="/srv/librefs/data"
assert data.get("bind",{}).get("create_host_path",False) is False
certs=volumes["/certs"]
assert certs["type"]=="bind" and certs["source"]=="/srv/librefs/certs" and certs["read_only"] is True
assert certs.get("bind",{}).get("create_host_path",False) is False
assert s["networks"] == {"c1_services":{"ipv4_address":"10.25.13.65"}}
network=r["networks"]["c1_services"]
assert network["name"] == "c1_services" and network["external"] is True
assert network.get("ipam", {}) == {}
configs={x["source"]:x for x in s["configs"]}
assert set(configs)=={"librefs_root_user","librefs_root_password"}
for name in configs:
 target=f"/run/secrets/{name}"
 assert configs[name]["target"]==target
 assert configs[name].get("uid")=="1000" and configs[name].get("gid")=="1000"
 mode=configs[name].get("mode")
 assert mode in ("0400",256)
assert r["configs"]["librefs_root_user"]["content"]==os.environ["LIBREFS_ROOT_USER"]
assert r["configs"]["librefs_root_password"]["content"]==os.environ["LIBREFS_ROOT_PASSWORD"]
assert "secrets" not in r and "secrets" not in s
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
assert "openssl s_client -connect 127.0.0.1:443" in command
assert "-verify_hostname s3.monosense.io" in command
assert "-CAfile /certs/current/public.crt" in command
assert "GET /minio/health/ready HTTP/1.0" in command and "Host: s3.monosense.io" in command
assert ('[[ "$status" == *" 200 "* ]]' in command
        or '[[ "$$status" == *" 200 "* ]]' in command)
redacted=json.loads(json.dumps(r))
for config in redacted["configs"].values(): config["content"]="<redacted>"
assert os.environ["LIBREFS_ROOT_USER"] not in json.dumps(redacted)
assert os.environ["LIBREFS_ROOT_PASSWORD"] not in json.dumps(redacted)
assert "MINIO_ROOT_USER:" not in source and "MINIO_ROOT_PASSWORD:" not in source
assert "content: ${LIBREFS_ROOT_USER:?required}" in source
assert "content: ${LIBREFS_ROOT_PASSWORD:?required}" in source
PY
printf 'libreFS rendered Compose contract passed\n'

docker network create --driver bridge --subnet "$test_subnet" \
    --gateway "$test_gateway" "$test_network" >/dev/null
docker volume create "$test_volume" >/dev/null
docker run --rm --platform linux/amd64 --network none --user 0:0 \
    --mount type=volume,src="$test_volume",dst=/data \
    --entrypoint /bin/sh \
    ghcr.io/librefs/librefs:release.2026-05-04t00-42-47z@sha256:707de0b1fa0ff7c83dd72ad4bcd8225302f06a4ce5278b7356700401e95004ab \
    -ec 'chown 1000:1000 /data; chmod 0750 /data'
mkdir -p "$work/certs/current"
openssl req -x509 -newkey rsa:2048 -nodes -days 2 \
    -subj /CN=s3.monosense.io -addext 'subjectAltName=DNS:s3.monosense.io' \
    -keyout "$work/certs/current/private.key" -out "$work/certs/current/public.crt" \
    >/dev/null 2>&1
chmod 0644 "$work/certs/current/private.key" "$work/certs/current/public.crt"
override="$work/override.yml"
cat >"$override" <<'YAML'
---
name: ${LIBREFS_TEST_PROJECT:?required}
services:
  librefs:
    container_name: ${LIBREFS_TEST_CONTAINER:?required}
    volumes:
      - type: volume
        source: librefs_test_data
        target: /data
        volume:
          nocopy: true
      - type: bind
        source: ${LIBREFS_TEST_CERTS:?required}
        target: /certs
        read_only: true
        bind:
          create_host_path: false
    networks:
      c1_services:
        ipv4_address: ${LIBREFS_TEST_IP:?required}
networks:
  c1_services:
    name: ${LIBREFS_TEST_NETWORK:?required}
    external: true
volumes:
  librefs_test_data:
    name: ${LIBREFS_TEST_VOLUME:?required}
    external: true
YAML
LIBREFS_TEST_PROJECT="librefs-c1-config-test-$test_id" \
LIBREFS_TEST_CONTAINER="$test_container" \
LIBREFS_TEST_IP="$test_ip" \
LIBREFS_TEST_NETWORK="$test_network" \
LIBREFS_TEST_VOLUME="$test_volume" \
LIBREFS_TEST_CERTS="$work/certs" \
    docker compose -f "$COMPOSE" -f "$override" up -d --pull always >/dev/null
ready=false
for _ in $(seq 1 60); do
    if [[ "$(docker inspect "$test_container" \
        --format '{{if .State.Health}}{{.State.Health.Status}}{{end}}')" == healthy ]]; then
        ready=true
        break
    fi
    sleep 1
done
[[ "$ready" == true ]]
docker exec "$test_container" /bin/sh -ec '
    test "$(id -u)" = 1000
    test "$(id -g)" = 1000
    test -r /run/secrets/librefs_root_user
    test -r /run/secrets/librefs_root_password
    test "$(stat -c "%u:%g:%a" /run/secrets/librefs_root_user)" = 1000:1000:400
    test "$(stat -c "%u:%g:%a" /run/secrets/librefs_root_password)" = 1000:1000:400
    test "$(cat /run/secrets/librefs_root_user)" = "$1"
    test "$(cat /run/secrets/librefs_root_password)" = "$2"
' probe "$LIBREFS_ROOT_USER" "$LIBREFS_ROOT_PASSWORD"
! docker inspect "$test_container" | grep -F "$LIBREFS_ROOT_USER" >/dev/null
! docker inspect "$test_container" | grep -F "$LIBREFS_ROOT_PASSWORD" >/dev/null
! docker logs "$test_container" 2>&1 | grep -F "$LIBREFS_ROOT_USER" >/dev/null
! docker logs "$test_container" 2>&1 | grep -F "$LIBREFS_ROOT_PASSWORD" >/dev/null
docker rm -f "$test_container" >/dev/null
printf 'libreFS config-backed credential file canary passed\n'
