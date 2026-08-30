#!/usr/bin/env bash
set -euo pipefail

DOCKER_BIN="${DOCKER_BIN:-docker}"
IP_BIN="${IP_BIN:-ip}"
PYTHON_BIN="${PYTHON_BIN:-python3}"
readonly DOCKER_BIN IP_BIN PYTHON_BIN
readonly EDGE_NETWORK=c1_edge FRONTEND_NETWORK=c1_forgejo_frontend PARENT=bond0.2515
readonly MANAGED_LABEL=io.monosense.infrastructure.managed-by=bootstrap

fail() { printf 'ERROR: %s\n' "$*" >&2; return 1; }

inspect_parent() {
    local bond links addresses
    bond="$("$IP_BIN" -j -d link show dev bond0)" || fail "failed to inspect bond0"
    links="$("$IP_BIN" -j -d link show dev "$PARENT")" || fail "failed to inspect parent $PARENT"
    addresses="$("$IP_BIN" -j address show dev "$PARENT")" || fail "failed to inspect addresses on $PARENT"
    "$PYTHON_BIN" -c '
import json, sys
bond=json.loads(sys.argv[1]); links=json.loads(sys.argv[2]); addresses=json.loads(sys.argv[3])
bond_ok=(len(bond)==1 and bond[0].get("ifname")=="bond0" and bond[0].get("mtu")==1500
 and "UP" in bond[0].get("flags",[]) and bond[0].get("linkinfo",{}).get("info_kind")=="bond"
 and bond[0].get("linkinfo",{}).get("info_data",{}).get("mode")=="active-backup")
parent_ok=(len(links)==1 and links[0].get("ifname")=="bond0.2515"
 and links[0].get("mtu")==1496 and "UP" in links[0].get("flags",[])
 and links[0].get("linkinfo",{}).get("info_kind")=="vlan"
 and links[0].get("linkinfo",{}).get("info_data",{}).get("id")==2515
 and len(addresses)==1 and not addresses[0].get("addr_info",[]))
raise SystemExit(0 if bond_ok and parent_ok else 1)
' "$bond" "$links" "$addresses" || fail "bond0 must be active-backup and $PARENT must be an addressless UP VLAN 2515 at MTU 1496"
}

inspect_network() {
    local name=$1 document
    document="$("$DOCKER_BIN" network inspect "$name")" || fail "failed to inspect Docker network $name"
    "$PYTHON_BIN" -c '
import json, sys
name=sys.argv[1]; n=json.load(sys.stdin)
try:
 x=n[0]
 endpoints=sorted((v.get("Name"),v.get("IPv4Address"),v.get("IPv6Address","")) for v in x.get("Containers",{}).values())
 common=(len(n)==1 and x["Name"]==name and x["Scope"]=="local" and x["EnableIPv4"] is True
  and x["EnableIPv6"] is False and x["Attachable"] is False and x["Ingress"] is False
  and x["ConfigOnly"] is False and x["Labels"]=={"io.monosense.infrastructure.managed-by":"bootstrap","io.monosense.infrastructure.purpose":("c1-edge" if name=="c1_edge" else "c1-forgejo-frontend")})
 if name=="c1_edge":
  valid=(common and x["Driver"]=="ipvlan" and x["Internal"] is False
   and x["IPAM"]["Driver"]=="default" and x["IPAM"].get("Options",{})=={}
   and x["IPAM"]["Config"]==[{"Subnet":"10.25.15.0/24","IPRange":"10.25.15.8/29","Gateway":"10.25.15.1"}]
   and x["Options"]=={"parent":"bond0.2515","ipvlan_mode":"l2","ipvlan_flag":"bridge"}
   and endpoints in ([],[("haproxy-c1","10.25.15.10/24","")]))
 else:
  valid=(common and x["Driver"]=="bridge" and x["Internal"] is True
   and x["IPAM"]["Driver"]=="default" and x["IPAM"].get("Options",{})=={}
   and x["IPAM"]["Config"]==[{"Subnet":"172.30.15.0/28","Gateway":"172.30.15.1"}])
  valid=valid and all(e[0] in {"haproxy-c1","forgejo-c1"} and e[2]=="" for e in endpoints)
  valid=valid and len(endpoints)<=2 and len({e[0] for e in endpoints})==len(endpoints)
except (IndexError, KeyError, TypeError, ValueError): valid=False
raise SystemExit(0 if valid else 1)
' "$name" <<<"$document" || fail "Docker network $name has immutable drift or an unapproved endpoint"
}

ensure_network() {
    local mode=$1 name=$2 names
    names="$("$DOCKER_BIN" network ls --filter "name=^${name}$" --format '{{.Name}}')" || fail "failed to list Docker networks"
    if [[ -n "$names" ]]; then
        [[ "$names" == "$name" ]] || fail "Docker returned an ambiguous match for $name"
        inspect_network "$name"
        return
    fi
    [[ "$mode" == apply ]] || { printf 'Docker network %s is absent; apply would create it\n' "$name"; return; }
    if [[ "$name" == "$EDGE_NETWORK" ]]; then
        "$DOCKER_BIN" network create --driver ipvlan --scope local --ipv4 --ipv6=false \
            --subnet 10.25.15.0/24 --gateway 10.25.15.1 --ip-range 10.25.15.8/29 \
            --opt parent="$PARENT" --opt ipvlan_mode=l2 --opt ipvlan_flag=bridge \
            --label "$MANAGED_LABEL" --label io.monosense.infrastructure.purpose=c1-edge "$name" >/dev/null
    else
        "$DOCKER_BIN" network create --driver bridge --scope local --internal --ipv4 --ipv6=false \
            --subnet 172.30.15.0/28 --gateway 172.30.15.1 \
            --label "$MANAGED_LABEL" --label io.monosense.infrastructure.purpose=c1-forgejo-frontend "$name" >/dev/null
    fi
    inspect_network "$name" || fail "newly created Docker network $name failed validation"
}

main() {
    local mode="${1:-check}"
    [[ $# -le 1 && ( "$mode" == check || "$mode" == apply ) ]] || fail 'usage: ensure.sh [check|apply]'
    inspect_parent
    ensure_network "$mode" "$EDGE_NETWORK"
    ensure_network "$mode" "$FRONTEND_NETWORK"
}
main "$@"
