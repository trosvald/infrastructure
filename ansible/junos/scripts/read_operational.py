#!/usr/bin/env python3
"""Read fixed Junos operational evidence through the literal CLI."""

from __future__ import annotations

import json
import os
import re
import sys
if __package__:
    from .read_managed import canonical_group
else:
    from read_managed import canonical_group

POSTCOMMIT_COMMANDS = (
    "show system commit",
    "show configuration groups ANSIBLE_SRX1500 | display set | no-more",
    "show configuration apply-groups | display set | no-more",
    "show interfaces terse | match 'irb[.]251[02]'",
    "show vlans VLAN-MGMT | no-more",
    "show route 0.0.0.0/0 exact | no-more",
    "show route table VR-XLSATU.inet.0 0.0.0.0/0 exact | no-more",
    "show security nat source rule all | no-more",
    "show configuration security policies | display inheritance no-comments | display set | no-more",
    "show bgp summary group CILIUM | no-more",
    "show route 10.25.20.0/24 exact | no-more",
    "show interfaces terse ge-0/0/0.0 | no-more",
)

SYSLOG_VERIFY_COMMANDS = (
    "show configuration system syslog | display inheritance no-comments | display set | no-more",
    "show system connections | match 6514",
    "show security log | last 20",
    "show security policies from-zone MGMT to-zone EDGE detail | no-more",
    "show security policies hit-count from-zone MGMT to-zone EDGE | no-more",
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
    "syslog-verify": SYSLOG_VERIFY_COMMANDS,
}


def newest_commit_record(output: str) -> str:
    lines = output.splitlines()
    start = next(
        (index for index, line in enumerate(lines) if re.match(r"^\s*0\s+", line)),
        None,
    )
    if start is None:
        raise RuntimeError("Junos commit output has no newest record")
    record = []
    for line in lines[start:]:
        if record and re.match(r"^\s*[1-9][0-9]*\s+", line):
            break
        record.append(line)
    normalized = "\n".join(record).strip()
    if not normalized:
        raise RuntimeError("Junos newest commit record is empty")
    return normalized


def required(name: str) -> str:
    value = os.environ.get(name, "")
    if not value:
        raise RuntimeError(f"missing required runtime value: {name}")
    return value


def main() -> int:
    if len(sys.argv) != 2 or sys.argv[1] not in MODES:
        print(
            "usage: read_operational.py postcommit|bgp-verify|syslog-verify",
            file=sys.stderr,
        )
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
            output = []
            for index, command in enumerate(MODES[sys.argv[1]], start=1):
                try:
                    output.append(device.cli(command, warning=False))
                except Exception as error:
                    raise RuntimeError(
                        f"fixed operational command {index} failed: {type(error).__name__}"
                    ) from error
        if any(not isinstance(value, str) for value in output):
            raise RuntimeError("Junos did not return text operational evidence")
        if sys.argv[1] == "postcommit":
            output[0] = newest_commit_record(output[0])
            output[1] = canonical_group(output[1])
        elif sys.argv[1] == "syslog-verify":
            output[4] = "\n".join(
                line
                for line in output[4].splitlines()
                if re.search(
                    r"MGMT-EDGE|hit|session.*log|log.*session",
                    line,
                    re.IGNORECASE,
                )
            )
        json.dump({"stdout": output}, sys.stdout, separators=(",", ":"))
        sys.stdout.write("\n")
    except Exception as error:
        print(f"operational evidence read failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
