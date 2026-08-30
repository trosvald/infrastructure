#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT HUP INT TERM
mkdir "$work/state"
cat >"$work/ip" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
if [[ "$*" == '-j -d link show dev bond0' ]]; then
    [[ "${FAIL:-}" != bond ]] || mode=802.3ad
    printf '[{"ifname":"bond0","mtu":1500,"flags":["UP"],"linkinfo":{"info_kind":"bond","info_data":{"mode":"%s"}}}]\n' "${mode:-active-backup}"
elif [[ "$*" == '-j -d link show dev bond0.2515' ]]; then
    printf '%s\n' '[{"ifname":"bond0.2515","mtu":1496,"flags":["UP"],"linkinfo":{"info_kind":"vlan","info_data":{"id":2515}}}]'
elif [[ "$*" == '-j address show dev bond0.2515' ]]; then
    [[ "${FAIL:-}" != address ]] && value='[]' || value='[{"family":"inet","local":"10.25.15.1"}]'
    printf '[{"ifname":"bond0.2515","addr_info":%s}]\n' "$value"
else exit 90; fi
SH
cat >"$work/docker" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
state="${FAKE_STATE:?}"
case "$1 $2" in
'network ls')
    filter=; while [[ $# -gt 0 ]]; do [[ "$1" == --filter ]] && { shift; filter=$1; }; shift || true; done
    name="${filter#name=^}"; name="${name%\$}"
    if [[ -e "$state/$name" ]]; then printf '%s\n' "$name"; fi
    ;;
'network inspect')
    name=$3
    if [[ "$name" == c1_edge ]]; then
        endpoints='{}'
        [[ "${FAIL:-}" != extra-edge ]] || endpoints='{"bad":{"Name":"bad","IPv4Address":"10.25.15.11/24","IPv6Address":""}}'
        printf '[{"Name":"c1_edge","Driver":"ipvlan","Scope":"local","EnableIPv4":true,"EnableIPv6":false,"Internal":false,"Attachable":false,"Ingress":false,"ConfigOnly":false,"IPAM":{"Driver":"default","Options":{},"Config":[{"Subnet":"10.25.15.0/24","IPRange":"10.25.15.8/29","Gateway":"10.25.15.1"}]},"Options":{"parent":"bond0.2515","ipvlan_mode":"l2","ipvlan_flag":"bridge"},"Labels":{"io.monosense.infrastructure.managed-by":"bootstrap","io.monosense.infrastructure.purpose":"c1-edge"},"Containers":%s}]\n' "$endpoints"
    else
        printf '%s\n' '[{"Name":"c1_forgejo_frontend","Driver":"bridge","Scope":"local","EnableIPv4":true,"EnableIPv6":false,"Internal":true,"Attachable":false,"Ingress":false,"ConfigOnly":false,"IPAM":{"Driver":"default","Options":{},"Config":[{"Subnet":"172.30.15.0/28","Gateway":"172.30.15.1"}]},"Options":{},"Labels":{"io.monosense.infrastructure.managed-by":"bootstrap","io.monosense.infrastructure.purpose":"c1-forgejo-frontend"},"Containers":{}}]'
    fi
    ;;
'network create')
    name="${@: -1}"; touch "$state/$name"; printf '%s\n' "$*" >>"$state/create"
    ;;
*) exit 91;;
esac
SH
chmod +x "$work/ip" "$work/docker"
run() { FAKE_STATE="$work/state" DOCKER_BIN="$work/docker" IP_BIN="$work/ip" PYTHON_BIN=python3 "$root/ensure.sh" "$@"; }
must_fail() { if run check >/dev/null 2>&1; then echo "expected failure: $*" >&2; exit 1; fi; }
run check >/dev/null
run apply >/dev/null
[[ -e "$work/state/c1_edge" && -e "$work/state/c1_forgejo_frontend" ]]
grep -F -- '--driver ipvlan' "$work/state/create" >/dev/null
grep -F -- '--driver bridge --scope local --internal' "$work/state/create" >/dev/null
FAIL=bond must_fail
FAIL=address must_fail
FAIL=extra-edge must_fail
printf 'c1 EDGE network prerequisite tests passed\n'
