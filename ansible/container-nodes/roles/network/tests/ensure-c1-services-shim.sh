#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; SCRIPT="$HERE/../files/ensure-c1-services-shim"; work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT; mkdir "$work/state"
cat >"$work/ip" <<'SH'
#!/usr/bin/env bash
set -eu; s=$FAKE_STATE; printf '%s\n' "$*" >>"$s/calls"
case "$*" in
 '-j -d link show dev bond0.2513') [[ ${FAIL:-} != parent-command ]] || exit 70; [[ ${FAIL:-} != parent-drift ]] && printf '%s\n' '[{"ifname":"bond0.2513","mtu":1496,"flags":["UP"],"linkinfo":{"info_kind":"vlan","info_data":{"id":2513}}}]' || printf '%s\n' '[{"ifname":"bond0.2513","mtu":1500,"flags":["UP"],"linkinfo":{"info_kind":"vlan","info_data":{"id":2513}}}]';;
 '-j address show dev bond0.2513') [[ ${FAIL:-} != parent-address ]] || exit 71; [[ ${FAIL:-} != parent-address-drift ]] && printf '%s\n' '[{"ifname":"bond0.2513","addr_info":[]}]' || printf '%s\n' '[{"ifname":"bond0.2513","addr_info":[{"family":"inet","local":"10.0.0.1"}]}]';;
 'link show dev c1-svc-shim') [[ -e $s/exists ]];;
 '-j -d link show dev c1-svc-shim') [[ ${FAIL:-} != link-inspect ]] || exit 72; link=bond0.2513; [[ ${FAIL:-} != link-drift ]] || link=wrong; printf '[{"ifname":"c1-svc-shim","link":"%s","mtu":1496,"flags":["UP"],"linkinfo":{"info_kind":"ipvlan","info_data":{"mode":"l2"}}}]\n' "$link";;
 'link add c1-svc-shim link bond0.2513 type ipvlan mode l2') [[ ${FAIL:-} != create ]] || exit 73; touch "$s/exists";;
 'link set dev c1-svc-shim mtu 1496') [[ ${FAIL:-} != mtu ]] || exit 74;;
 'link set dev c1-svc-shim up') [[ ${FAIL:-} != up ]] || exit 75;;
 '-j address show dev c1-svc-shim') [[ ${FAIL:-} != address-inspect ]] || exit 76; if [[ ${FAIL:-} == address-drift ]]; then printf '%s\n' '[{"ifname":"c1-svc-shim","addr_info":[{"family":"inet","local":"10.25.13.18","prefixlen":32}]}]'; elif [[ -e $s/address ]]; then printf '%s\n' '[{"ifname":"c1-svc-shim","addr_info":[{"family":"inet","local":"10.25.13.17","prefixlen":32}]}]'; else printf '%s\n' '[{"ifname":"c1-svc-shim","addr_info":[]}]'; fi;;
 'address add 10.25.13.17/32 dev c1-svc-shim') [[ ${FAIL:-} != address-add ]] || exit 77; touch "$s/address";;
 '-j route show 10.25.13.64/27') [[ ${FAIL:-} != route-inspect ]] || exit 78; if [[ ${FAIL:-} == route-drift ]]; then printf '%s\n' '[{"dst":"10.25.13.0/24","dev":"c1-svc-shim","scope":"link"}]'; elif [[ -e $s/route ]]; then if [[ -e $s/legacy-route ]]; then printf '%s\n' '[{"dst":"10.25.13.64/27","dev":"c1-svc-shim","scope":"link"}]'; else printf '%s\n' '[{"dst":"10.25.13.64/27","dev":"c1-svc-shim","scope":"link","prefsrc":"10.25.13.17"}]'; fi; else printf '[]\n'; fi;;
 'route add 10.25.13.64/27 dev c1-svc-shim src 10.25.13.17') [[ ${FAIL:-} != route-add ]] || exit 79; touch "$s/route";;
 'route replace 10.25.13.64/27 dev c1-svc-shim src 10.25.13.17') rm -f "$s/legacy-route"; touch "$s/route";;
 *) exit 80;; esac
SH
chmod +x "$work/ip"
reset(){ rm -rf "$work/state"; mkdir "$work/state"; : >"$work/state/calls"; }
run(){ FAKE_STATE="$work/state" IP_BIN="$work/ip" FAIL="${1:-}" "$SCRIPT" "${MODE:-apply}" >/dev/null; }
fail(){ if run "$1" 2>/dev/null; then printf 'expected failure %s\n' "$1" >&2; exit 1; fi; }
reset; MODE=check run; unset MODE; [[ ! -e $work/state/exists ]]
reset; touch "$work/state/exists" "$work/state/address" "$work/state/route"; MODE=check run; unset MODE
reset; run; [[ -e $work/state/exists && -e $work/state/address && -e $work/state/route ]]; grep -F 'link add c1-svc-shim link bond0.2513 type ipvlan mode l2' "$work/state/calls" >/dev/null; ! grep -Eq 'replace|delete|flush' "$work/state/calls"
reset; touch "$work/state/exists" "$work/state/address" "$work/state/route" "$work/state/legacy-route"; run; grep -F 'route replace 10.25.13.64/27 dev c1-svc-shim src 10.25.13.17' "$work/state/calls" >/dev/null
for scenario in parent-command parent-drift parent-address parent-address-drift link-inspect link-drift create mtu up address-inspect address-drift address-add route-inspect route-drift route-add; do reset; [[ $scenario =~ ^(create|mtu)$ ]] || touch "$work/state/exists"; [[ $scenario =~ ^(address-drift|address-add)$ ]] || touch "$work/state/address"; [[ $scenario =~ ^(route-drift|route-add)$ ]] || touch "$work/state/route"; fail "$scenario"; done
printf 'c1 SERVICES shim prerequisite tests passed\n'
