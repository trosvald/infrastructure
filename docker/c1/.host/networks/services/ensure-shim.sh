#!/usr/bin/env bash
set -euo pipefail

IP_BIN="${IP_BIN:-ip}"
PYTHON_BIN="${PYTHON_BIN:-python3}"
readonly IP_BIN PYTHON_BIN
readonly PARENT=bond0.2513 SHIM=c1-svc-shim

fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

inspect_parent() {
    local links addresses
    links="$("$IP_BIN" -j -d link show dev "$PARENT")" || fail "missing parent $PARENT"
    addresses="$("$IP_BIN" -j address show dev "$PARENT")" \
        || fail "failed to inspect addresses on $PARENT"
    "$PYTHON_BIN" -c '
import json,sys
x=json.loads(sys.argv[1])
a=json.loads(sys.argv[2])
valid=(len(x)==1 and x[0].get("ifname")=="bond0.2513"
 and x[0].get("mtu")==1496 and "UP" in x[0].get("flags",[])
 and x[0].get("linkinfo",{}).get("info_kind")=="vlan"
 and x[0].get("linkinfo",{}).get("info_data",{}).get("id")==2513
 and len(a)==1 and not a[0].get("addr_info",[]))
raise SystemExit(0 if valid else 1)
' "$links" "$addresses" \
        || fail "parent $PARENT must be UP, VLAN 2513, MTU 1496, and have no L3 address"
}

inspect_link() {
    local document
    document="$("$IP_BIN" -j -d link show dev "$SHIM")" || fail "failed to inspect shim $SHIM"
    "$PYTHON_BIN" -c '
import json,sys
x=json.load(sys.stdin)
if len(x)!=1:
 raise SystemExit(1)
i=x[0]
valid=(i.get("ifname")=="c1-svc-shim" and i.get("mtu")==1496
 and "UP" in i.get("flags",[]) and i.get("link")=="bond0.2513"
 and i.get("linkinfo",{}).get("info_kind")=="ipvlan"
 and i.get("linkinfo",{}).get("info_data",{}).get("mode")=="l2")
raise SystemExit(0 if valid else 1)
' <<<"$document" || fail "existing shim has immutable drift"
}

inspect_address() {
    local document
    document="$("$IP_BIN" -j address show dev "$SHIM")" || fail "failed to inspect shim address"
    "$PYTHON_BIN" -c '
import json,sys
x=json.load(sys.stdin)
if len(x)!=1:
 raise SystemExit(2)
a=[(v.get("local"),v.get("prefixlen")) for v in x[0].get("addr_info",[]) if v.get("family")=="inet"]
valid=(x[0].get("ifname")=="c1-svc-shim" and a==[("10.25.13.17",32)])
raise SystemExit(0 if valid else 3 if a else 4)
' <<<"$document"
}

inspect_route() {
    local document
    document="$("$IP_BIN" -j route show 10.25.13.64/27)" || fail "failed to inspect shim route"
    "$PYTHON_BIN" -c '
import json,sys
x=json.load(sys.stdin)
if not x:
 raise SystemExit(4)
valid=(len(x)==1 and x[0].get("dst")=="10.25.13.64/27"
 and x[0].get("dev")=="c1-svc-shim"
 and x[0].get("scope")=="link")
raise SystemExit(0 if valid else 3)
' <<<"$document"
}

main() {
    local mode="${1:-check}" status
    [[ $# -le 1 && ( "$mode" == check || "$mode" == apply ) ]] \
        || fail 'usage: ensure-shim.sh [check|apply]'
    inspect_parent

    if ! "$IP_BIN" link show dev "$SHIM" >/dev/null 2>&1; then
        if [[ "$mode" == check ]]; then
            printf 'c1 SERVICES shim is absent; apply would create it\n'
            return
        fi
        "$IP_BIN" link add "$SHIM" link "$PARENT" type ipvlan mode l2 \
            || fail "failed to create shim $SHIM"
        "$IP_BIN" link set dev "$SHIM" mtu 1496 || fail "failed to set shim MTU"
    fi
    if [[ "$mode" == apply ]]; then
        "$IP_BIN" link set dev "$SHIM" up || fail "failed to bring shim up"
    fi
    inspect_link

    set +e
    inspect_address
    status=$?
    set -e
    case "$status" in
        0) ;;
        4)
            [[ "$mode" == apply ]] || fail 'shim address is absent'
            "$IP_BIN" address add 10.25.13.17/32 dev "$SHIM" \
                || fail 'failed to add shim address'
            inspect_address
            ;;
        *) fail 'existing shim address has drift' ;;
    esac

    set +e
    inspect_route
    status=$?
    set -e
    case "$status" in
        0) ;;
        4)
            [[ "$mode" == apply ]] || fail 'shim route is absent'
            "$IP_BIN" route add 10.25.13.64/27 dev "$SHIM" \
                || fail 'failed to add shim route'
            inspect_route
            ;;
        *) fail 'existing shim route has drift' ;;
    esac
    printf 'c1 SERVICES shim matches required state\n'
}

main "$@"
