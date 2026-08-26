#!/usr/bin/env bash
set -euo pipefail

readonly HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT="$HERE/../ensure-shim.sh"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/state"

cat >"$work/ip" <<'FAKE'
#!/usr/bin/env bash
set -eu
state="$FAKE_STATE"
printf '%s\n' "$*" >>"$state/calls"

if [[ "$*" == '-j -d link show dev bond0.2513' ]]; then
    [[ "${FAIL:-}" != parent-command ]] || exit 70
    if [[ "${FAIL:-}" == parent-drift ]]; then
        printf '%s\n' '[{"ifname":"bond0.2513","mtu":1500,"flags":["UP"],"linkinfo":{"info_kind":"vlan","info_data":{"id":2513}}}]'
    else
        printf '%s\n' '[{"ifname":"bond0.2513","mtu":1496,"flags":["UP"],"linkinfo":{"info_kind":"vlan","info_data":{"id":2513}}}]'
    fi
    exit
fi
if [[ "$*" == '-j address show dev bond0.2513' ]]; then
    [[ "${FAIL:-}" != parent-address-command ]] || exit 80
    if [[ "${FAIL:-}" == parent-address-drift ]]; then
        printf '%s\n' '[{"ifname":"bond0.2513","addr_info":[{"family":"inet","local":"10.25.13.17","prefixlen":32}]}]'
    else
        printf '%s\n' '[{"ifname":"bond0.2513","addr_info":[]}]'
    fi
    exit
fi
if [[ "$*" == 'link show dev c1-svc-shim' ]]; then
    [[ -e "$state/exists" ]] || exit 1
    exit
fi
if [[ "$*" == '-j -d link show dev c1-svc-shim' ]]; then
    [[ "${FAIL:-}" != link-inspect ]] || exit 71
    if [[ "${FAIL:-}" == link-drift || "${FAIL:-}" == post-link ]]; then
        printf '%s\n' '[{"ifname":"c1-svc-shim","link":"wrong","mtu":1496,"flags":["UP"],"linkinfo":{"info_kind":"ipvlan","info_data":{"mode":"l2"}}}]'
    else
        printf '%s\n' '[{"ifname":"c1-svc-shim","link":"bond0.2513","mtu":1496,"flags":["UP"],"linkinfo":{"info_kind":"ipvlan","info_data":{"mode":"l2"}}}]'
    fi
    exit
fi
if [[ "$1 $2" == 'link add' ]]; then
    [[ "${FAIL:-}" != create ]] || exit 72
    touch "$state/exists"
    exit
fi
if [[ "$*" == 'link set dev c1-svc-shim mtu 1496' ]]; then
    [[ "${FAIL:-}" != set-mtu ]] || exit 73
    exit
fi
if [[ "$*" == 'link set dev c1-svc-shim up' ]]; then
    [[ "${FAIL:-}" != set-up ]] || exit 74
    exit
fi
if [[ "$*" == '-j address show dev c1-svc-shim' ]]; then
    [[ "${FAIL:-}" != address-inspect ]] || exit 75
    if [[ "${FAIL:-}" == address-drift ]]; then
        printf '%s\n' '[{"ifname":"c1-svc-shim","addr_info":[{"family":"inet","local":"10.25.13.18","prefixlen":32}]}]'
    elif [[ "${FAIL:-}" == address-ifname ]]; then
        printf '%s\n' '[{"ifname":"wrong","addr_info":[{"family":"inet","local":"10.25.13.17","prefixlen":32}]}]'
    elif [[ -e "$state/address" ]]; then
        printf '%s\n' '[{"ifname":"c1-svc-shim","addr_info":[{"family":"inet","local":"10.25.13.17","prefixlen":32}]}]'
    else
        printf '%s\n' '[{"ifname":"c1-svc-shim","addr_info":[]}]'
    fi
    exit
fi
if [[ "$1 $2" == 'address add' ]]; then
    [[ "${FAIL:-}" != address-add ]] || exit 76
    touch "$state/address"
    exit
fi
if [[ "$*" == '-j route show 10.25.13.64/27' ]]; then
    [[ "${FAIL:-}" != route-inspect ]] || exit 77
    if [[ "${FAIL:-}" == route-drift ]]; then
        printf '%s\n' '[{"dst":"10.25.13.0/24","dev":"c1-svc-shim","scope":"link"}]'
    elif [[ "${FAIL:-}" == route-nodev ]]; then
        printf '%s\n' '[{"dst":"10.25.13.64/27","scope":"link"}]'
    elif [[ -e "$state/route" ]]; then
        printf '%s\n' '[{"dst":"10.25.13.64/27","dev":"c1-svc-shim","scope":"link"}]'
    else
        printf '%s\n' '[]'
    fi
    exit
fi
if [[ "$1 $2" == 'route add' ]]; then
    [[ "${FAIL:-}" != route-add ]] || exit 78
    touch "$state/route"
    exit
fi
exit 79
FAKE
chmod +x "$work/ip"

reset() {
    rm -rf "$work/state"
    mkdir "$work/state"
    : >"$work/state/calls"
}
run() {
    FAKE_STATE="$work/state" IP_BIN="$work/ip" FAIL="${1:-}" \
        "$SCRIPT" "${MODE:-apply}" >/dev/null
}
must_fail() {
    if run "$@" 2>/dev/null; then
        printf 'expected shim failure: %s\n' "$*" >&2
        exit 1
    fi
}

reset
MODE=check run
[[ ! -e "$work/state/exists" ]]
unset MODE

reset
touch "$work/state/exists" "$work/state/address" "$work/state/route"
MODE=check run
unset MODE

reset
run
[[ -e "$work/state/exists" && -e "$work/state/address" && -e "$work/state/route" ]]
grep -F 'link add c1-svc-shim link bond0.2513 type ipvlan mode l2' "$work/state/calls" >/dev/null
grep -F 'address add 10.25.13.17/32 dev c1-svc-shim' "$work/state/calls" >/dev/null
grep -F 'route add 10.25.13.64/27 dev c1-svc-shim' "$work/state/calls" >/dev/null
! grep -Eq ' route replace | link delete | address flush ' "$work/state/calls"

for failure in parent-command parent-drift parent-address-command parent-address-drift \
    link-inspect link-drift create set-mtu set-up address-inspect address-add address-drift \
    address-ifname route-inspect route-add route-drift route-nodev post-link; do
    reset
    if [[ "$failure" != create && "$failure" != set-mtu && "$failure" != post-link ]]; then
        touch "$work/state/exists"
    fi
    if [[ "$failure" != address-add && "$failure" != address-drift ]]; then
        touch "$work/state/address"
    fi
    if [[ "$failure" != route-add && "$failure" != route-drift ]]; then
        touch "$work/state/route"
    fi
    must_fail "$failure"
done

printf 'c1 SERVICES shim prerequisite tests passed\n'
