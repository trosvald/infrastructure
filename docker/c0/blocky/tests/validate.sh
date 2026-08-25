#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
app_dir="$repo_root/docker/c0/blocky"
image="docker.io/spx01/blocky:v0.34.0@sha256:595136fb127f4c952b621113e668c09acdcf15ac054d96ee6d4c51a76c35f5fd"
helper_image="docker.io/powerdns/pdns-auth-51:5.1.4@sha256:bb5b1c133bcca1dd455075321de7d55db4945a8d7f2ba23339e3c7bbe416b205"
network="blocky-validation-$$"
container="blocky-validation-$$"

cleanup() {
    docker rm --force "$container" >/dev/null 2>&1 || true
    docker network rm "$network" >/dev/null 2>&1 || true
}
trap cleanup EXIT HUP INT TERM

# Parse and semantically validate the Git-owned configuration without network access or a DNS listener.
docker run --rm \
    --platform linux/amd64 \
    --network none \
    --read-only \
    --cap-drop ALL \
    --security-opt no-new-privileges:true \
    --mount "type=bind,src=$app_dir/config.yml,dst=/app/config.yml,readonly" \
    "$image" validate

# Prove the final rootless security model can bind and answer DNS 53 over both transports.
docker network create --internal "$network" >/dev/null
docker run --detach \
    --name "$container" \
    --platform linux/amd64 \
    --network "$network" \
    --network-alias blocky \
    --user 100:100 \
    --read-only \
    --cap-drop ALL \
    --security-opt no-new-privileges:true \
    --sysctl net.ipv4.ip_unprivileged_port_start=53 \
    --memory-swappiness 0 \
    --cpus 0.5 \
    --memory 256m \
    --memory-swap 256m \
    --ulimit nofile=4096:8192 \
    --mount "type=bind,src=$app_dir/config.yml,dst=/app/config.yml,readonly" \
    "$image" >/dev/null

for _ in $(seq 1 30); do
    if docker exec "$container" /app/blocky healthcheck >/dev/null 2>&1; then
        break
    fi
    sleep 1
done
docker exec "$container" /app/blocky healthcheck

for _ in $(seq 1 40); do
    if [[ "$(docker inspect "$container" --format '{{.State.Health.Status}}')" == "healthy" ]]; then
        break
    fi
    sleep 1
done

docker run --rm \
    --platform linux/amd64 \
    --network "$network" \
    --mount "type=bind,src=$app_dir/tests/dns_probe.py,dst=/dns_probe.py,readonly" \
    --entrypoint python3 \
    "$helper_image" /dns_probe.py udp --host blocky
docker run --rm \
    --platform linux/amd64 \
    --network "$network" \
    --mount "type=bind,src=$app_dir/tests/dns_probe.py,dst=/dns_probe.py,readonly" \
    --entrypoint python3 \
    "$helper_image" /dns_probe.py tcp --host blocky

runtime="$(mktemp)"
status="$(mktemp)"
trap 'rm -f "$runtime" "$status"; cleanup' EXIT HUP INT TERM
docker inspect "$container" >"$runtime"
docker run --rm \
    --platform linux/amd64 \
    --network none \
    --pid "container:$container" \
    --entrypoint /bin/cat \
    "$helper_image" /proc/1/status >"$status"

jq -e --arg image "$image" --arg network "$network" '
    length == 1
    and .[0].Config.Image == $image
    and .[0].Config.User == "100:100"
    and .[0].Config.Healthcheck.Test == ["CMD", "/app/blocky", "healthcheck"]
    and .[0].HostConfig.ReadonlyRootfs == true
    and .[0].HostConfig.CapDrop == ["ALL"]
    and ((.[0].HostConfig.CapAdd // []) | length) == 0
    and .[0].HostConfig.SecurityOpt == ["no-new-privileges:true"]
    and .[0].HostConfig.Sysctls == {"net.ipv4.ip_unprivileged_port_start": "53"}
    and .[0].HostConfig.NetworkMode == $network
    and .[0].HostConfig.PortBindings == {}
    and .[0].HostConfig.Privileged == false
    and .[0].HostConfig.ReadonlyRootfs == true
    and .[0].HostConfig.Memory == 268435456
    and .[0].HostConfig.MemorySwap == 268435456
    and ((.[0].HostConfig.MemorySwappiness // 0) == 0)
    and .[0].HostConfig.NanoCpus == 500000000
    and .[0].HostConfig.Ulimits == [{"Name": "nofile", "Hard": 8192, "Soft": 4096}]
    and (.[0].Mounts | length) == 1
    and .[0].Mounts[0].Type == "bind"
    and .[0].Mounts[0].Destination == "/app/config.yml"
    and .[0].Mounts[0].RW == false
    and .[0].State.Running == true
    and .[0].State.Health.Status == "healthy"
' "$runtime" >/dev/null

python3 - "$status" <<'PY'
import re
import sys
from pathlib import Path

status = Path(sys.argv[1]).read_text()
expected = {
    "Uid": "100\\s+100\\s+100\\s+100",
    "Gid": "100\\s+100\\s+100\\s+100",
    "CapInh": "0{16}",
    "CapPrm": "0{16}",
    "CapEff": "0{16}",
    "CapBnd": "0{16}",
    "CapAmb": "0{16}",
    "NoNewPrivs": "1",
}
for field, value in expected.items():
    assert re.search(rf"^{field}:\s+{value}$", status, re.MULTILINE), f"unexpected {field} in runtime status"
PY
