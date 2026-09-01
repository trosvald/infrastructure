#!/usr/bin/env bash
set -euo pipefail

[[ -n "${BAO_TOKEN:-}" && -n "${OPENBAO_RUNTIME_DIR:-}" ]] || {
    printf '%s\n' 'ERROR: run only through scripts/with-openbao-runtime.sh' >&2
    exit 1
}
readonly mode="${1:-provision}"
case "$mode" in
    provision|enable-public|disable-public) ;;
    *)
        printf '%s\n' 'ERROR: expected no argument, enable-public, or disable-public' >&2
        exit 2
        ;;
esac

readonly path=network/junos/srx1500/topology
readonly response="$OPENBAO_RUNTIME_DIR/edge-topology-current.json"
readonly payload="$OPENBAO_RUNTIME_DIR/edge-topology-updated.json"
readonly version_file="$OPENBAO_RUNTIME_DIR/edge-topology-version"
readonly changed_file="$OPENBAO_RUNTIME_DIR/edge-topology-changed"

bao kv get -mount=kv -format=json "$path" >"$response"
chmod 0600 "$response"
python3 - "$response" "$payload" "$version_file" "$changed_file" "$mode" <<'PY'
import ipaddress
import json
import os
import pathlib
import ssl
import sys
import urllib.request

source, target, version_path, changed_path, mode = (
    pathlib.Path(value) if index < 4 else value
    for index, value in enumerate(sys.argv[1:])
)
response = json.loads(source.read_text(encoding="utf-8"))
record = response["data"]["data"]
version = response["data"]["metadata"]["version"]
opener = urllib.request.build_opener(
    urllib.request.ProxyHandler({}),
    urllib.request.HTTPSHandler(context=ssl.create_default_context()),
)
request = urllib.request.Request(
    "https://1.1.1.1/cdn-cgi/trace",
    headers={"User-Agent": "monosense-edge-topology/1"},
)
with opener.open(request, timeout=10) as observer:
    fields = dict(
        line.split("=", 1)
        for line in observer.read(4096).decode("ascii").splitlines()
        if "=" in line
    )
observed = ipaddress.ip_address(fields.get("ip", ""))
if not isinstance(observed, ipaddress.IPv4Address) or not observed.is_global:
    raise SystemExit("direct TLS observer did not return a globally routable IPv4 address")
required = {
    "dns.internal": "10.25.13.35",
    "dns.internal_cidr": "10.25.13.35/32",
    "edge.public_enabled": mode == "enable-public",
    "monitoring.gatus_cidr": "10.25.13.36/32",
    "monitoring.vector_address": "10.25.13.37",
    "monitoring.vector_cidr": "10.25.13.37/32",
    "monitoring.vector_host": "logs-ingest.monosense.io",
    "monitoring.syslog_ca_profile": "LE-ISRG-ROOT-X1",
    "networks.edge.subnet": "10.25.15.0/24",
    "networks.edge.gateway": "10.25.15.1",
    "networks.edge.gateway_cidr": "10.25.15.1/24",
    "networks.edge.haproxy": "10.25.15.10",
    "networks.edge.haproxy_cidr": "10.25.15.10/32",
    "wan.secondary_public_cidr": f"{observed}/32",
}
allowed_previous = {
    "dns.internal": {"10.25.10.100"},
    "dns.internal_cidr": {"10.25.10.100/32"},
    "edge.public_enabled": {
        mode == "disable-public",
    },
}
changed = False
for dotted, expected in required.items():
    parts = dotted.split(".")
    current = record
    for part in parts[:-1]:
        value = current.get(part)
        if value is None:
            value = {}
            current[part] = value
            changed = True
        if not isinstance(value, dict):
            raise SystemExit(f"protected topology conflict at {part}")
        current = value
    leaf = parts[-1]
    if leaf in current and current[leaf] != expected:
        if current[leaf] not in allowed_previous.get(dotted, set()):
            raise SystemExit(f"protected topology conflict at {dotted}")
        current[leaf] = expected
        changed = True
    if leaf not in current:
        current[leaf] = expected
        changed = True
wan = record.get("wan", {}).get("secondary_public_cidr")
if wan is not None:
    network = ipaddress.ip_network(wan, strict=True)
    if network.version != 4 or network.prefixlen != 32 or not network.network_address.is_global:
        raise SystemExit("wan.secondary_public_cidr is not a globally routable IPv4 /32")
target.write_text(json.dumps(record, separators=(",", ":")) + "\n", encoding="utf-8")
os.chmod(target, 0o600)
version_path.write_text(str(version), encoding="ascii")
changed_path.write_text("true" if changed else "false", encoding="ascii")
PY
if [[ "$(cat "$changed_file")" == true ]]; then
    version="$(cat "$version_file")"
    bao kv put -mount=kv -cas="$version" "$path" @"$payload" >/dev/null
    printf 'Protected Junos topology updated with CAS for mode %s\n' "$mode"
else
    printf 'Protected Junos topology already matches mode %s\n' "$mode"
fi
