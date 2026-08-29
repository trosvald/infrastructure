#!/usr/bin/env python3
"""Read fixed Junos operational evidence through the literal CLI."""

from __future__ import annotations

import json
import os
import sys

POSTCOMMIT_COMMANDS = (
    "show system commit | no-more",
    "show configuration groups ANSIBLE_SRX1500 | display set | no-more",
    "show configuration apply-groups | display set | no-more",
    "show interfaces terse | match 'irb[.]2510|irb[.]2512' | no-more",
    "show vlans VLAN-MGMT | no-more",
    "show route 0.0.0.0/0 exact | no-more",
    "show route table VR-XLSATU.inet.0 0.0.0.0/0 exact | no-more",
    "show security nat source rule all | no-more",
    "show configuration security policies | display inheritance no-comments | display set | no-more",
    "show bgp summary group CILIUM | no-more",
    "show route 10.25.20.0/24 exact | no-more",
)

CILIUM_PEERS = tuple(f"10.25.11.{index}" for index in range(11, 16))
BGP_VERIFY_COMMANDS = (
    "show configuration groups ANSIBLE_SRX1500 protocols bgp group CILIUM | display set | no-more",
    "show bgp summary group CILIUM | no-more",
    *(f"show bgp neighbor {peer} | no-more" for peer in CILIUM_PEERS),
    "show route protocol bgp | no-more",
    *(f"show route receive-protocol bgp {peer} | no-more" for peer in CILIUM_PEERS),
    *(f"show route advertising-protocol bgp {peer} | no-more" for peer in CILIUM_PEERS),
    "show route 10.25.20.0/24 exact | no-more",
)

MODES = {
    "postcommit": POSTCOMMIT_COMMANDS,
    "bgp-verify": BGP_VERIFY_COMMANDS,
}


def required(name: str) -> str:
    value = os.environ.get(name, "")
    if not value:
        raise RuntimeError(f"missing required runtime value: {name}")
    return value


def main() -> int:
    if len(sys.argv) != 2 or sys.argv[1] not in MODES:
        print("usage: read_operational.py postcommit|bgp-verify", file=sys.stderr)
        return 2
    try:
        from jnpr.junos import Device

        with Device(
            host=required("JUNOS_MANAGEMENT_ADDRESS"),
            user=required("JUNOS_NETCONF_USERNAME"),
            port=830,
            ssh_private_key_file=required("JUNOS_NETCONF_PRIVATE_KEY_FILE"),
            ssh_config=required("JUNOS_NETCONF_SSH_CONFIG"),
            hostkey_verify=True,
            look_for_keys=False,
            allow_agent=False,
            gather_facts=False,
        ) as device:
            output = [device.cli(command, warning=False) for command in MODES[sys.argv[1]]]
        if any(not isinstance(value, str) for value in output):
            raise RuntimeError("Junos did not return text operational evidence")
        json.dump({"stdout": output}, sys.stdout, separators=(",", ":"))
        sys.stdout.write("\n")
    except Exception as error:
        print(f"operational evidence read failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
