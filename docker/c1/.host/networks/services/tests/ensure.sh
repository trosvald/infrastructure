#!/usr/bin/env bash
set -euo pipefail
readonly HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT="$HERE/../ensure.sh"
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
mkdir -p "$work/state"
cat >"$work/network.json" <<'JSON'
[{"Name":"c1_services","Driver":"ipvlan","Scope":"local","EnableIPv4":true,"EnableIPv6":false,"Internal":false,"Attachable":false,"Ingress":false,"ConfigOnly":false,"IPAM":{"Driver":"default","Options":{},"Config":[{"Subnet":"10.25.13.0/24","IPRange":"10.25.13.64/27","Gateway":"10.25.13.1","AuxiliaryAddresses":{"c1-shim":"10.25.13.17"}}]},"Options":{"parent":"bond0.2513","ipvlan_mode":"l2","ipvlan_flag":"bridge"},"Labels":{"io.monosense.infrastructure.managed-by":"bootstrap","io.monosense.infrastructure.purpose":"c1-services"},"Containers":{}}]
JSON
cat >"$work/docker" <<'FAKE'
#!/usr/bin/env bash
set -eu
s="$FAKE_STATE"
printf '%s\n' "$*" >>"$s/calls"
[[ "${FAIL:-}" != docker-all ]] || exit 70
if [[ "$1 $2" == 'network ls' ]]; then
    [[ "${FAIL:-}" != list ]] || exit 71
    if [[ -e "$s/exists" ]]; then printf '%s\n' "${LIST_VALUE:-c1_services}"; fi
    exit
fi
if [[ "$1 $2" == 'network inspect' ]]; then
    [[ "${FAIL:-}" != inspect ]] || exit 72
    if [[ "${FAIL:-}" == post-create ]]; then
        jq '.[0].Options.parent="wrong"' "$s/network.json"
    else
        cat "$s/network.json"
    fi
    exit
fi
if [[ "$1 $2" == 'network create' ]]; then
    [[ "${FAIL:-}" != create ]] || exit 73
    printf '%s\n' "${@:3}" >"$s/create-args"
    touch "$s/exists"
    exit
fi
exit 74
FAKE
cat >"$work/ip" <<'FAKE'
#!/usr/bin/env bash
set -eu
[[ "${FAIL:-}" != ip-all ]] || exit 80
if [[ " $* " == *' address '* ]]; then
    [[ "${FAIL:-}" != addr ]] || exit 81
    value="${ADDR_JSON:-}"
    [[ -n "$value" ]] || value='[{"ifname":"bond0.2513","addr_info":[]}]'
else
    [[ "${FAIL:-}" != link ]] || exit 82
    value="${LINK_JSON:-}"
    [[ -n "$value" ]] || value='[{"ifname":"bond0.2513","mtu":1496,"flags":["UP"],"linkinfo":{"info_kind":"vlan","info_data":{"id":2513}}}]'
fi
printf '%s\n' "$value"
FAKE
chmod +x "$work/docker" "$work/ip"
reset() { rm -rf "$work/state"; mkdir "$work/state"; cp "$work/network.json" "$work/state/network.json"; : >"$work/state/calls"; }
run() { FAKE_STATE="$work/state" DOCKER_BIN="$work/docker" IP_BIN="$work/ip" FAIL="${1:-}" LIST_VALUE="${LIST_VALUE:-}" LINK_JSON="${LINK_JSON:-}" ADDR_JSON="${ADDR_JSON:-}" "$SCRIPT" "${MODE:-apply}" >/dev/null; }
must_fail() { if run "$@" 2>/dev/null; then printf 'expected failure: %s\n' "$*" >&2; exit 1; fi; }

reset; touch "$work/state/exists"; run; [[ ! -e "$work/state/create-args" ]]
reset; run; [[ -e "$work/state/create-args" ]]; grep -Fx -- '--driver' "$work/state/create-args" >/dev/null; grep -Fx -- 'c1_services' "$work/state/create-args" >/dev/null
reset; MODE=check; run; [[ ! -e "$work/state/create-args" ]]; unset MODE
reset
touch "$work/state/exists"
jq '.[0].Containers={"endpoint":{"Name":"librefs-c1","IPv4Address":"10.25.13.65/24","IPv6Address":""}}' \
    "$work/network.json" >"$work/state/network.json"
run

readonly -a filters=(
 '.[0].Name="other"' '.[0].Driver="macvlan"' '.[0].Scope="swarm"' '.[0].EnableIPv4=false' '.[0].EnableIPv6=true'
 '.[0].Internal=true' '.[0].Attachable=true' '.[0].Ingress=true' '.[0].ConfigOnly=true' '.[0].IPAM.Driver="other"'
 '.[0].IPAM.Options={"x":"y"}' '.[0].IPAM.Config[0].Subnet="10.0.0.0/8"' '.[0].IPAM.Config[0].IPRange="10.25.13.0/24"'
 '.[0].IPAM.Config[0].Gateway="10.25.13.2"' '.[0].IPAM.Config[0].AuxiliaryAddresses={}' '.[0].Options.parent="wrong"'
 '.[0].Options.ipvlan_mode="l3"' '.[0].Options.ipvlan_flag="private"' '.[0].Labels={}'
 '.[0].Containers={"x":{"Name":"unexpected","IPv4Address":"10.25.13.66/24"}}' '. += [.[0]]'
)
for filter in "${filters[@]}"; do reset; touch "$work/state/exists"; jq "$filter" "$work/network.json" >"$work/state/network.json"; must_fail; [[ ! -e "$work/state/create-args" ]]; done
for failure in list inspect create docker-all ip-all link addr; do reset; [[ "$failure" != create ]] && touch "$work/state/exists"; must_fail "$failure"; done
reset; must_fail post-create; [[ -e "$work/state/create-args" ]]
reset; touch "$work/state/exists"; LIST_VALUE=$'c1_services\nc1_services'; must_fail; unset LIST_VALUE
for value in \
 '[{"ifname":"bond0.2513","mtu":1500,"flags":["UP"],"linkinfo":{"info_kind":"vlan","info_data":{"id":2513}}}]' \
 '[{"ifname":"bond0.2513","mtu":1496,"flags":[],"linkinfo":{"info_kind":"vlan","info_data":{"id":2513}}}]' \
 '[{"ifname":"bond0.2513","mtu":1496,"flags":["UP"],"linkinfo":{"info_kind":"vlan","info_data":{"id":2512}}}]' \
 '[{"ifname":"wrong","mtu":1496,"flags":["UP"],"linkinfo":{"info_kind":"vlan","info_data":{"id":2513}}}]' \
 '[{"ifname":"bond0.2513","mtu":1496,"flags":["UP"],"linkinfo":{"info_kind":"dummy","info_data":{"id":2513}}}]' \
 '[]'; do reset; touch "$work/state/exists"; LINK_JSON="$value"; must_fail; done
unset LINK_JSON
reset; touch "$work/state/exists"; ADDR_JSON='[{"ifname":"bond0.2513","addr_info":[{"family":"inet","local":"10.0.0.1"}]}]'; must_fail
printf 'c1 SERVICES network prerequisite tests passed\n'
