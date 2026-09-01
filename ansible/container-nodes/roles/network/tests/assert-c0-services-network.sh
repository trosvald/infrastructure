#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; SCRIPT="$HERE/../files/assert-c0-services-network"; work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
cat >"$work/network.json" <<'JSON'
[{"Name":"c0_services","Driver":"ipvlan","Scope":"local","EnableIPv4":true,"EnableIPv6":false,"Internal":false,"Attachable":false,"Ingress":false,"ConfigOnly":false,"IPAM":{"Driver":"default","Options":{},"Config":[{"Subnet":"10.25.13.0/24","Gateway":"10.25.13.1"}]},"Options":{"com.docker.network.driver.mtu":"1496","ipvlan_flag":"bridge","ipvlan_mode":"l2","parent":"enp0s31f6.2513"},"Labels":{},"Containers":{"a":{"Name":"powerdns-c0-powerdns-1","IPv4Address":"10.25.13.33/24","IPv6Address":""},"b":{"Name":"openbao-c0-openbao-1","IPv4Address":"10.25.13.34/24","IPv6Address":""},"c":{"Name":"blocky-c0-blocky-1","IPv4Address":"10.25.13.35/24","IPv6Address":""},"d":{"Name":"gatus-c0","IPv4Address":"10.25.13.36/24","IPv6Address":""},"e":{"Name":"vector-c0","IPv4Address":"10.25.13.37/24","IPv6Address":""}}}]
JSON
cat >"$work/docker" <<'SH'
#!/usr/bin/env bash
[[ "$*" == 'network inspect c0_services' ]] || exit 70
cat "$FAKE_NETWORK"
SH
cat >"$work/ip" <<'SH'
#!/usr/bin/env bash
case "$*" in
  '-j -d link show dev enp0s31f6.2513') printf '%s\n' '[{"ifname":"enp0s31f6.2513","mtu":1496,"flags":["UP"],"linkinfo":{"info_kind":"vlan","info_data":{"id":2513}}}]';;
  '-j address show dev enp0s31f6.2513') printf '%s\n' '[{"ifname":"enp0s31f6.2513","addr_info":[]}]';;
  *) exit 71;;
esac
SH
chmod +x "$work/docker" "$work/ip"
run(){ FAKE_NETWORK="$1" DOCKER_BIN="$work/docker" IP_BIN="$work/ip" "$SCRIPT" apply >/dev/null; }
run "$work/network.json"
jq '.[0].Options["com.docker.network.driver.mtu"]="1500"' "$work/network.json" >"$work/drift.json"
if run "$work/drift.json" 2>/dev/null; then
    printf 'expected MTU option drift refusal\n' >&2
    exit 1
fi
printf 'c0 services network contract tests passed\n'
