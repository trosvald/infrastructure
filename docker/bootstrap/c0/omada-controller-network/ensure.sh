#!/usr/bin/env bash

set -euo pipefail

DOCKER_BIN="${DOCKER_BIN:-docker}"
readonly DOCKER_BIN
IP_BIN="${IP_BIN:-ip}"
readonly IP_BIN
PYTHON_BIN="${PYTHON_BIN:-python3}"
readonly PYTHON_BIN
readonly NETWORK_NAME="c0_omada_mgmt"
readonly MANAGED_BY_LABEL="io.monosense.infrastructure.managed-by=bootstrap"
readonly PURPOSE_LABEL="io.monosense.infrastructure.purpose=omada-controller-mgmt"

inspect_parent() {
    local parent_json

    if ! parent_json="$("$IP_BIN" -j link show dev enp0s31f6)"; then
        printf 'ERROR: failed to inspect parent interface enp0s31f6\n' >&2
        return 1
    fi
    if ! "$PYTHON_BIN" -c '
import json
import sys

try:
    links = json.load(sys.stdin)
    valid = (
        len(links) == 1
        and links[0]["ifname"] == "enp0s31f6"
        and links[0]["mtu"] == 1500
        and "UP" in links[0]["flags"]
    )
except (KeyError, TypeError, ValueError):
    valid = False
raise SystemExit(0 if valid else 1)
' <<<"$parent_json"; then
        printf 'ERROR: parent interface enp0s31f6 is absent, down, or not MTU 1500\n' >&2
        return 1
    fi
}

inspect_network() {
    local network_json

    if ! network_json="$("$DOCKER_BIN" network inspect "$NETWORK_NAME")"; then
        printf 'ERROR: failed to inspect Docker network %s\n' "$NETWORK_NAME" >&2
        return 1
    fi
    if ! "$PYTHON_BIN" -c '
import json
import sys

name = sys.argv[1]
expected_ipam = [{
    "Subnet": "10.25.10.0/24",
    "IPRange": "10.25.10.26/32",
    "Gateway": "10.25.10.1",
    "AuxiliaryAddresses": {"c0": "10.25.10.20"},
}]
expected_options = {
    "ipvlan_mode": "l2",
    "ipvlan_flag": "bridge",
    "parent": "enp0s31f6",
}
expected_labels = {
    "io.monosense.infrastructure.managed-by": "bootstrap",
    "io.monosense.infrastructure.purpose": "omada-controller-mgmt",
}
try:
    networks = json.load(sys.stdin)
    network = networks[0]
    valid = (
        len(networks) == 1
        and network["Name"] == name
        and network["Driver"] == "ipvlan"
        and network["Scope"] == "local"
        and network["Internal"] is False
        and network["Attachable"] is False
        and network["Ingress"] is False
        and network["ConfigOnly"] is False
        and network["EnableIPv4"] is True
        and network["EnableIPv6"] is False
        and network["IPAM"]["Driver"] == "default"
        and network["IPAM"]["Options"] == {}
        and network["IPAM"]["Config"] == expected_ipam
        and network["Options"] == expected_options
        and network["Labels"] == expected_labels
    )
except (IndexError, KeyError, TypeError, ValueError):
    valid = False
raise SystemExit(0 if valid else 1)
' "$NETWORK_NAME" <<<"$network_json"; then
        printf 'ERROR: Docker network %s does not match the required immutable configuration\n' "$NETWORK_NAME" >&2
        return 1
    fi
}

main() {
    local network_names

    inspect_parent

    if ! network_names="$("$DOCKER_BIN" network ls --filter "name=^${NETWORK_NAME}$" --format '{{.Name}}')"; then
        printf 'ERROR: failed to list Docker networks\n' >&2
        return 1
    fi

    if [[ -n "$network_names" ]]; then
        if [[ "$network_names" != "$NETWORK_NAME" ]]; then
            printf 'ERROR: Docker returned an ambiguous match for network %s\n' "$NETWORK_NAME" >&2
            return 1
        fi
        inspect_network
        printf 'Docker network %s already matches the required configuration\n' "$NETWORK_NAME"
        return 0
    fi

    if ! "$DOCKER_BIN" network create \
        --driver ipvlan \
        --scope local \
        --ipv4 \
        --ipv6=false \
        --subnet 10.25.10.0/24 \
        --gateway 10.25.10.1 \
        --ip-range 10.25.10.26/32 \
        --aux-address c0=10.25.10.20 \
        --opt parent=enp0s31f6 \
        --opt ipvlan_mode=l2 \
        --opt ipvlan_flag=bridge \
        --label "$MANAGED_BY_LABEL" \
        --label "$PURPOSE_LABEL" \
        "$NETWORK_NAME" >/dev/null; then
        printf 'ERROR: failed to create Docker network %s\n' "$NETWORK_NAME" >&2
        return 1
    fi

    if ! inspect_network; then
        printf 'ERROR: newly created Docker network %s failed post-create validation\n' "$NETWORK_NAME" >&2
        return 1
    fi
    printf 'Created Docker network %s with the required configuration\n' "$NETWORK_NAME"
}

main "$@"
