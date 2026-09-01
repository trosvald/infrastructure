#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; SCRIPT="$HERE/../files/ensure-c1-edge-networks"; work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT; mkdir "$work/state"
cat >"$work/docker" <<'SH'
#!/usr/bin/env bash
set -eu; s=$FAKE_STATE; name=${3:-}; printf '%s\n' "$*" >>"$s/calls"
case "$1 $2" in
 'network inspect') [[ ${FAIL:-} != inspect-$name ]] || exit 70; if [[ ! -e $s/$name ]]; then printf 'Error response from daemon: network %s not found\n' "$name" >&2; exit 1; fi; if [[ $name == c1_edge ]]; then endpoints='{}'; [[ ${FAIL:-} != edge-endpoint ]] || endpoints='{"bad":{"Name":"bad","IPv4Address":"10.25.15.11/24","IPv6Address":""}}'; printf '[{"Name":"c1_edge","Driver":"ipvlan","Scope":"local","EnableIPv4":true,"EnableIPv6":false,"Internal":false,"Attachable":false,"Ingress":false,"ConfigOnly":false,"IPAM":{"Driver":"default","Options":{},"Config":[{"Subnet":"10.25.15.0/24","IPRange":"10.25.15.8/29","Gateway":"10.25.15.1"}]},"Options":{"parent":"%s","ipvlan_mode":"l2","ipvlan_flag":"bridge"},"Labels":{"io.monosense.infrastructure.managed-by":"bootstrap","io.monosense.infrastructure.purpose":"c1-edge"},"Containers":%s}]\n' "${EDGE_PARENT:-bond0.2515}" "$endpoints"; else endpoints='{}'; [[ ${FAIL:-} != frontend-endpoint ]] || endpoints='{"bad":{"Name":"postgres-c1","IPv4Address":"172.30.15.4/28","IPv6Address":""}}'; printf '[{"Name":"c1_forgejo_frontend","Driver":"bridge","Scope":"local","EnableIPv4":true,"EnableIPv6":false,"Internal":true,"Attachable":false,"Ingress":false,"ConfigOnly":false,"IPAM":{"Driver":"default","Options":{},"Config":[{"Subnet":"172.30.15.0/28","Gateway":"172.30.15.1"}]},"Options":{},"Labels":{"io.monosense.infrastructure.managed-by":"bootstrap","io.monosense.infrastructure.purpose":"c1-forgejo-frontend"},"Containers":%s}]\n' "$endpoints"; fi;;
 'network ls') :;;
 'network create') name=${*: -1}; [[ ${FAIL:-} != create-$name ]] || exit 71; printf '%s\n' "$*" >"$s/create-$name"; touch "$s/$name";;
 *) exit 72;; esac
SH
cat >"$work/ip" <<'SH'
#!/usr/bin/env bash
case "$*" in
 '-j -d link show dev bond0') mode=active-backup; [[ ${FAIL:-} != bond ]] || mode=802.3ad; printf '[{"ifname":"bond0","mtu":1500,"flags":["UP"],"linkinfo":{"info_kind":"bond","info_data":{"mode":"%s"}}}]\n' "$mode";;
 '-j -d link show dev bond0.2515') mtu=1496; [[ ${FAIL:-} != parent ]] || mtu=1500; printf '[{"ifname":"bond0.2515","mtu":%s,"flags":["UP"],"linkinfo":{"info_kind":"vlan","info_data":{"id":2515}}}]\n' "$mtu";;
 '-j address show dev bond0.2515') if [[ ${FAIL:-} == address ]]; then printf '[{"ifname":"bond0.2515","addr_info":[{"family":"inet","local":"10.25.15.2"}]}]\n'; else printf '[{"ifname":"bond0.2515","addr_info":[]}]\n'; fi;; *) exit 80;; esac
SH
chmod +x "$work/docker" "$work/ip"
reset(){ rm -rf "$work/state"; mkdir "$work/state"; : >"$work/state/calls"; }
run(){ FAKE_STATE="$work/state" DOCKER_BIN="$work/docker" IP_BIN="$work/ip" FAIL="${1:-}" EDGE_PARENT="${EDGE_PARENT:-}" "$SCRIPT" "${MODE:-apply}" >/dev/null; }
must_fail(){ if run "$1" 2>/dev/null; then printf 'expected failure %s\n' "$1" >&2; exit 1; fi; }
reset; touch "$work/state/c1_edge" "$work/state/c1_forgejo_frontend"; run; [[ ! -e $work/state/create-c1_edge ]]
reset; MODE=check run; unset MODE; [[ ! -e $work/state/create-c1_edge ]]
reset; run; [[ -e $work/state/create-c1_edge && -e $work/state/create-c1_forgejo_frontend ]]; grep -F -- '--ip-range 10.25.15.8/29' "$work/state/create-c1_edge" >/dev/null; grep -F -- '--internal' "$work/state/create-c1_forgejo_frontend" >/dev/null
for scenario in bond parent address edge-endpoint frontend-endpoint inspect-c1_edge inspect-c1_forgejo_frontend; do reset; touch "$work/state/c1_edge" "$work/state/c1_forgejo_frontend"; must_fail "$scenario"; [[ ! -e $work/state/create-c1_edge ]]; done
reset; touch "$work/state/c1_edge" "$work/state/c1_forgejo_frontend"; EDGE_PARENT=wrong; export EDGE_PARENT; must_fail ''; unset EDGE_PARENT
for scenario in create-c1_edge create-c1_forgejo_frontend; do reset; must_fail "$scenario"; done
printf 'c1 EDGE network behavior tests passed\n'
