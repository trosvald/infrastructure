#!/usr/bin/env bash

set -euo pipefail

readonly TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly ENSURE_SCRIPT="${TEST_DIR}/../ensure.sh"
work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT

cat >"$work_dir/network.json" <<'JSON'
[
  {
    "Name": "c0_omada_mgmt",
    "Driver": "ipvlan",
    "Scope": "local",
    "Internal": false,
    "Attachable": false,
    "Ingress": false,
    "ConfigOnly": false,
    "EnableIPv4": true,
    "EnableIPv6": false,
    "IPAM": {
      "Driver": "default",
      "Options": {},
      "Config": [
        {
          "Subnet": "10.25.10.0/24",
          "IPRange": "10.25.10.26/32",
          "Gateway": "10.25.10.1",
          "AuxiliaryAddresses": {"c0": "10.25.10.20"}
        }
      ]
    },
    "Options": {
      "ipvlan_mode": "l2",
      "ipvlan_flag": "bridge",
      "parent": "enp0s31f6"
    },
    "Labels": {
      "io.monosense.infrastructure.managed-by": "bootstrap",
      "io.monosense.infrastructure.purpose": "omada-controller-mgmt"
    }
  }
]
JSON

cat >"$work_dir/docker" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail

state="${FAKE_DOCKER_STATE:?}"
printf '%s\n' "$*" >>"$state/invocations"

[[ "${1:-}" == "network" ]] || exit 90
case "${2:-}" in
    ls)
        [[ "$#" -eq 6 ]]
        [[ "$3" == "--filter" && "$4" == "name=^c0_omada_mgmt$" ]]
        [[ "$5" == "--format" && "$6" == '{{.Name}}' ]]
        [[ "${FAKE_DOCKER_SCENARIO:-}" != "list-failure" ]] || exit 41
        if [[ -f "$state/exists" ]]; then
            printf '%s\n' c0_omada_mgmt
        fi
        ;;
    inspect)
        [[ "$#" -eq 3 && "$3" == "c0_omada_mgmt" ]]
        [[ "${FAKE_DOCKER_SCENARIO:-}" != "inspect-failure" ]] || exit 42
        [[ -f "$state/exists" ]] || exit 43
        cat "$state/network.json"
        ;;
    create)
        shift 2
        : >"$state/create-args"
        for argument in "$@"; do
            printf '%s\n' "$argument" >>"$state/create-args"
        done
        [[ "${FAKE_DOCKER_SCENARIO:-}" != "create-failure" ]] || exit 44
        : >"$state/exists"
        printf '%s\n' fake-network-id
        ;;
    *)
        exit 91
        ;;
esac
FAKE
chmod +x "$work_dir/docker"
cat >"$work_dir/ip" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail

[[ "$#" -eq 5 ]]
[[ "$1" == "-j" && "$2" == "link" && "$3" == "show" ]]
[[ "$4" == "dev" && "$5" == "enp0s31f6" ]]
[[ "${FAKE_IP_SCENARIO:-}" != "ip-failure" ]] || exit 45
mtu=1500
flags='"BROADCAST","MULTICAST","UP","LOWER_UP"'
[[ "${FAKE_IP_SCENARIO:-}" != "wrong-mtu" ]] || mtu=1496
[[ "${FAKE_IP_SCENARIO:-}" != "down-parent" ]] || flags='"BROADCAST","MULTICAST","LOWER_UP"'
printf '[{"ifname":"enp0s31f6","mtu":%s,"flags":[%s]}]\n' "$mtu" "$flags"
FAKE
chmod +x "$work_dir/ip"


cat >"$work_dir/expected-create-args" <<'ARGS'
--driver
ipvlan
--scope
local
--ipv4
--ipv6=false
--subnet
10.25.10.0/24
--gateway
10.25.10.1
--ip-range
10.25.10.26/32
--aux-address
c0=10.25.10.20
--opt
parent=enp0s31f6
--opt
ipvlan_mode=l2
--opt
ipvlan_flag=bridge
--label
io.monosense.infrastructure.managed-by=bootstrap
--label
io.monosense.infrastructure.purpose=omada-controller-mgmt
c0_omada_mgmt
ARGS

reset_state() {
    rm -rf "$work_dir/state"
    mkdir "$work_dir/state"
    cp "$work_dir/network.json" "$work_dir/state/network.json"
}

run_ensure() {
    FAKE_DOCKER_STATE="$work_dir/state" \
        FAKE_DOCKER_SCENARIO="${1:-}" \
        FAKE_IP_SCENARIO="${2:-}" \
        DOCKER_BIN="$work_dir/docker" \
        IP_BIN="$work_dir/ip" \
        "$ENSURE_SCRIPT" >/dev/null 2>&1
}

assert_no_create() {
    if [[ -e "$work_dir/state/create-args" ]]; then
        printf 'unexpected network mutation in scenario %s\n' "${1:-unknown}" >&2
        exit 1
    fi
}

reset_state
: >"$work_dir/state/exists"
run_ensure
assert_no_create exact-network
[[ "$(wc -l <"$work_dir/state/invocations")" -eq 2 ]]

reset_state
run_ensure
cmp "$work_dir/expected-create-args" "$work_dir/state/create-args"
[[ "$(wc -l <"$work_dir/state/invocations")" -eq 3 ]]

reset_state
jq '.[0].Options.parent = "wrong-parent"' "$work_dir/network.json" >"$work_dir/state/network.json"
if run_ensure; then
    printf 'post-create mismatch unexpectedly succeeded\n' >&2
    exit 1
fi
cmp "$work_dir/expected-create-args" "$work_dir/state/create-args"
[[ "$(wc -l <"$work_dir/state/invocations")" -eq 3 ]]

readonly -a mismatch_filters=(
    '.[0].Name = "wrong"'
    '.[0].Driver = "bridge"'
    '.[0].Scope = "swarm"'
    '.[0].Internal = true'
    '.[0].Attachable = true'
    '.[0].Ingress = true'
    '.[0].ConfigOnly = true'
    '.[0].EnableIPv4 = false'
    '.[0].EnableIPv6 = true'
    '.[0].IPAM.Driver = "other"'
    '.[0].IPAM.Options = {"unexpected": "value"}'
    '.[0].IPAM.Config += [.[0].IPAM.Config[0]]'
    '.[0].IPAM.Config[0].Subnet = "10.25.11.0/24"'
    '.[0].IPAM.Config[0].IPRange = "10.25.10.27/32"'
    '.[0].IPAM.Config[0].Gateway = "10.25.10.254"'
    '.[0].IPAM.Config[0].Extra = "unexpected"'
    '.[0].IPAM.Config[0].AuxiliaryAddresses = {"c0": "10.25.10.21"}'
    '.[0].Options.parent = "eth0"'
    '.[0].Options.ipvlan_mode = "l3"'
    '.[0].Options.ipvlan_flag = "private"'
    '.[0].Options.extra = "unexpected"'
    '.[0].Labels["io.monosense.infrastructure.managed-by"] = "manual"'
    '.[0].Labels["io.monosense.infrastructure.purpose"] = "other"'
    '.[0].Labels.extra = "unexpected"'
    '. += [.[0]]'
)

for filter in "${mismatch_filters[@]}"; do
    reset_state
    : >"$work_dir/state/exists"
    jq "$filter" "$work_dir/network.json" >"$work_dir/state/network.json"
    if run_ensure; then
        printf 'mismatched network passed validation: %s\n' "$filter" >&2
        exit 1
    fi
    assert_no_create "$filter"
done

for failure in list-failure inspect-failure; do
    reset_state
    : >"$work_dir/state/exists"
    if run_ensure "$failure"; then
        printf '%s unexpectedly succeeded\n' "$failure" >&2
        exit 1
    fi
    assert_no_create "$failure"
done

for failure in ip-failure wrong-mtu down-parent; do
    reset_state
    if run_ensure "" "$failure"; then
        printf '%s unexpectedly succeeded\n' "$failure" >&2
        exit 1
    fi
    assert_no_create "$failure"
    [[ ! -e "$work_dir/state/invocations" ]]
done

reset_state
if run_ensure create-failure; then
    printf 'create failure unexpectedly succeeded\n' >&2
    exit 1
fi
cmp "$work_dir/expected-create-args" "$work_dir/state/create-args"
[[ ! -e "$work_dir/state/exists" ]]

printf 'Omada network bootstrap behavior tests passed\n'
