#!/usr/bin/env python3
"""Read only the managed Junos group and apply-groups reference over pinned NETCONF."""

from __future__ import annotations

import json
import os
import re
import sys

from jnpr.junos import Device

REVIEWED_RELEASE = re.compile(r"^23[.]4R2(?:[.-]|$)")
AUTHENTICATION_RE = re.compile(
    r"^(set groups ANSIBLE_SRX1500 protocols bgp group CILIUM authentication-key)\s+.+$"
)
FAMILY_PREFIX = "set groups ANSIBLE_SRX1500 protocols bgp group CILIUM family "
FAMILY_LINES = {
    f"{FAMILY_PREFIX}inet unicast prefix-limit maximum 128",
    f"{FAMILY_PREFIX}inet unicast prefix-limit teardown 100",
    f"{FAMILY_PREFIX}inet unicast prefix-limit teardown idle-timeout 5",
}
CANONICAL_FAMILY = (
    f"{FAMILY_PREFIX}inet unicast prefix-limit maximum 128 teardown 100 idle-timeout 5"
)


def canonical_group(value: str) -> str:
    lines = value.splitlines()
    actual_family = {line for line in lines if line.startswith(FAMILY_PREFIX)}
    if actual_family != FAMILY_LINES:
        raise RuntimeError("managed Cilium family configuration is not exact")
    result: list[str] = []
    family_written = False
    for line in lines:
        if line.startswith(FAMILY_PREFIX):
            if not family_written:
                result.append(CANONICAL_FAMILY)
                family_written = True
            continue
        result.append(AUTHENTICATION_RE.sub(r"\1 <AUTHENTICATION>", line))
    return "\n".join(result) + "\n"


def required(name: str) -> str:
    value = os.environ.get(name, "")
    if not value:
        raise RuntimeError(f"missing required runtime value: {name}")
    return value


def main() -> int:
    try:
        with Device(
            host=required("JUNOS_MANAGEMENT_ADDRESS"),
            user=required("JUNOS_NETCONF_USERNAME"),
            port=830,
            ssh_private_key_file=required("JUNOS_NETCONF_PRIVATE_KEY_FILE"),
            ssh_config=required("JUNOS_NETCONF_SSH_CONFIG"),
            hostkey_verify=True,
            look_for_keys=False,
            allow_agent=False,
            gather_facts=True,
        ) as device:
            facts = device.facts
            if str(facts.get("model", "")).upper() != "SRX1500":
                raise RuntimeError("unexpected device model")
            if str(facts.get("hostname", "")) != "srx1500":
                raise RuntimeError("unexpected device hostname")
            if not REVIEWED_RELEASE.match(str(facts.get("version", ""))):
                raise RuntimeError("Junos release is outside the reviewed train")
            group = device.cli(
                "show configuration groups ANSIBLE_SRX1500 | display set | no-more",
                warning=False,
            )
            apply_groups = device.cli(
                "show configuration apply-groups | display set | no-more",
                warning=False,
            )
        if not isinstance(group, str) or not isinstance(apply_groups, str):
            raise RuntimeError("Junos did not return text managed configuration")
        json.dump(
            {"group": canonical_group(group), "apply_groups": apply_groups},
            sys.stdout,
            separators=(",", ":"),
        )
        sys.stdout.write("\n")
    except Exception as error:
        print(f"managed configuration read failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
