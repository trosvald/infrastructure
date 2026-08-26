#!/usr/bin/env bash
set -euo pipefail

DOCKER_BIN="${DOCKER_BIN:-docker}"
IP_BIN="${IP_BIN:-ip}"
PYTHON_BIN="${PYTHON_BIN:-python3}"
readonly DOCKER_BIN IP_BIN PYTHON_BIN
readonly NETWORK_NAME=c1_services PARENT=bond0.2513
readonly MANAGED_LABEL=io.monosense.infrastructure.managed-by=bootstrap
readonly PURPOSE_LABEL=io.monosense.infrastructure.purpose=c1-services

fail() { printf 'ERROR: %s\n' "$*" >&2; return 1; }

inspect_parent() {
    local links addresses
    links="$("$IP_BIN" -j -d link show dev "$PARENT")" || fail "failed to inspect parent $PARENT"
    addresses="$("$IP_BIN" -j address show dev "$PARENT")" || fail "failed to inspect addresses on $PARENT"
    "$PYTHON_BIN" -c '
import json, sys
links=json.loads(sys.argv[1]); addresses=json.loads(sys.argv[2])
valid=(len(links)==1 and links[0].get("ifname")=="bond0.2513"
 and links[0].get("mtu")==1496 and "UP" in links[0].get("flags",[])
 and links[0].get("linkinfo",{}).get("info_kind")=="vlan"
 and links[0].get("linkinfo",{}).get("info_data",{}).get("id")==2513
 and len(addresses)==1 and not addresses[0].get("addr_info",[]))
raise SystemExit(0 if valid else 1)
' "$links" "$addresses" || fail "parent $PARENT must be UP, VLAN 2513, MTU 1496, and have no L3 address"
}

inspect_network() {
    local document
    document="$("$DOCKER_BIN" network inspect "$NETWORK_NAME")" || fail "failed to inspect Docker network $NETWORK_NAME"
    "$PYTHON_BIN" -c '
import json, sys
n=json.load(sys.stdin)
expected_ipam=[{"Subnet":"10.25.13.0/24","IPRange":"10.25.13.64/27","Gateway":"10.25.13.1","AuxiliaryAddresses":{"c1-shim":"10.25.13.17"}}]
expected_options={"parent":"bond0.2513","ipvlan_mode":"l2","ipvlan_flag":"bridge"}
expected_labels={"io.monosense.infrastructure.managed-by":"bootstrap","io.monosense.infrastructure.purpose":"c1-services"}
try:
 x=n[0]
 endpoints=sorted(
  (v.get("Name"),v.get("IPv4Address"),v.get("IPv6Address",""))
  for v in x.get("Containers",{}).values()
 )
 valid=(len(n)==1 and x["Name"]=="c1_services" and x["Driver"]=="ipvlan" and x["Scope"]=="local"
  and x["EnableIPv4"] is True and x["EnableIPv6"] is False and x["Internal"] is False
  and x["Attachable"] is False and x["Ingress"] is False and x["ConfigOnly"] is False
  and x["IPAM"]["Driver"]=="default" and x["IPAM"].get("Options",{})=={} and x["IPAM"]["Config"]==expected_ipam
  and x["Options"]==expected_options and x["Labels"]==expected_labels
  and endpoints in ([],[("librefs-c1","10.25.13.65/24","")]))
except (IndexError, KeyError, TypeError, ValueError): valid=False
raise SystemExit(0 if valid else 1)
' <<<"$document" || fail "Docker network $NETWORK_NAME has immutable drift or an unapproved endpoint"
}

main() {
    local mode="${1:-check}" names
    [[ $# -le 1 && ( "$mode" == check || "$mode" == apply ) ]] || fail 'usage: ensure.sh [check|apply]'
    inspect_parent
    names="$("$DOCKER_BIN" network ls --filter "name=^${NETWORK_NAME}$" --format '{{.Name}}')" || fail "failed to list Docker networks"
    if [[ -n "$names" ]]; then
        [[ "$names" == "$NETWORK_NAME" ]] || fail "Docker returned an ambiguous match for $NETWORK_NAME"
        inspect_network
        printf 'Docker network %s already matches the required configuration\n' "$NETWORK_NAME"
        return
    fi
    if [[ "$mode" == check ]]; then
        printf 'Docker network %s is absent; apply would create it\n' "$NETWORK_NAME"
        return
    fi
    "$DOCKER_BIN" network create --driver ipvlan --scope local --ipv4 --ipv6=false \
        --subnet 10.25.13.0/24 --gateway 10.25.13.1 --ip-range 10.25.13.64/27 \
        --aux-address c1-shim=10.25.13.17 --opt parent="$PARENT" --opt ipvlan_mode=l2 \
        --opt ipvlan_flag=bridge --label "$MANAGED_LABEL" --label "$PURPOSE_LABEL" \
        "$NETWORK_NAME" >/dev/null || fail "failed to create Docker network $NETWORK_NAME"
    inspect_network || fail "newly created Docker network $NETWORK_NAME failed post-create validation"
    printf 'Created Docker network %s with the required configuration\n' "$NETWORK_NAME"
}
main "$@"
