#!/usr/bin/env python3
"""Read managed Junos group, application, and exclusions over pinned NETCONF."""

from __future__ import annotations

import json
import os
import re
import sys
import xml.etree.ElementTree as ET


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

APPLY_GROUPS_EXCEPTION_RE = re.compile(
    r"^set .+ apply-groups-except ANSIBLE_SRX1500$"
)
DIRECT_RESERVATION_COMMANDS = (
    "show configuration access address-assignment pool MGMT | display set | no-more",
    "show configuration access address-assignment pool PROD | display set | no-more",
    "show configuration access address-assignment pool DEV | display set | no-more",
    "show configuration routing-instances VR-XLSATU access address-assignment "
    "pool HOME | display set | no-more",
)
DIRECT_MASTER_RESERVATION_RE = re.compile(
    r"^set access address-assignment pool (MGMT|PROD|DEV) family inet host "
    r"(\S+)(?:\s+.*)?$"
)
DIRECT_HOME_RESERVATION_RE = re.compile(
    r"^set routing-instances VR-XLSATU access address-assignment pool HOME "
    r"family inet host (\S+)(?:\s+.*)?$"
)


def normalize_apply_groups_exceptions(output: str) -> list[str]:
    lines = [line.strip() for line in output.splitlines() if line.strip()]
    if any(not APPLY_GROUPS_EXCEPTION_RE.fullmatch(line) for line in lines):
        raise RuntimeError("unexpected apply-groups-except output")
    return sorted(set(lines))


def normalize_apply_groups_exceptions_xml(output: str) -> list[str]:
    root = ET.fromstring(output)
    parents = {child: parent for parent in root.iter() for child in parent}
    lines: list[str] = []
    for element in root.iter():
        if (
            element.tag.rsplit("}", 1)[-1] != "apply-groups-except"
            or (element.text or "").strip() != "ANSIBLE_SRX1500"
        ):
            continue
        ancestors = []
        parent = parents.get(element)
        while parent is not None:
            ancestors.append(parent)
            parent = parents.get(parent)
        tokens: list[str] = []
        for ancestor in reversed(ancestors):
            tag = ancestor.tag.rsplit("}", 1)[-1]
            if tag in {"rpc-reply", "data", "configuration"}:
                continue
            tokens.append(tag)
            name = next(
                (
                    child
                    for child in ancestor
                    if child.tag.rsplit("}", 1)[-1] == "name"
                ),
                None,
            )
            if name is not None and name.text:
                tokens.append(name.text.strip())
        tokens.extend(["apply-groups-except", "ANSIBLE_SRX1500"])
        lines.append("set " + " ".join(tokens))
    return normalize_apply_groups_exceptions("\n".join(lines))
def normalize_direct_reservation_paths(output: str) -> list[str]:
    paths: set[str] = set()
    for line in (value.strip() for value in output.splitlines() if value.strip()):
        if " family inet host " not in line:
            continue
        master = DIRECT_MASTER_RESERVATION_RE.fullmatch(line)
        if master:
            pool_name, host_name = master.groups()
            paths.add(
                f"access/address-assignment/pool/{pool_name}/family/inet/host/"
                f"{host_name}"
            )
            continue
        home = DIRECT_HOME_RESERVATION_RE.fullmatch(line)
        if home:
            paths.add(
                "routing-instances/VR-XLSATU/access/address-assignment/pool/"
                f"HOME/family/inet/host/{home.group(1)}"
            )
            continue
        raise RuntimeError("direct reservation has an unexpected hierarchy")
    return sorted(paths)




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
            apply_groups_exceptions = normalize_apply_groups_exceptions_xml(
                device._conn.get_config(
                    source="running",
                    filter=(
                        "xpath",
                        "//*[local-name()='apply-groups-except' and "
                        "normalize-space(.)='ANSIBLE_SRX1500']",
                    ),
                ).data_xml
            )
            direct_reservation_output = [
                device.cli(command, warning=False)
                for command in DIRECT_RESERVATION_COMMANDS
            ]
            if any(not isinstance(value, str) for value in direct_reservation_output):
                raise RuntimeError("Junos did not return text direct reservation configuration")
            direct_reservation_paths = normalize_direct_reservation_paths(
                "\n".join(direct_reservation_output)
            )
        if not isinstance(group, str) or not isinstance(apply_groups, str):
            raise RuntimeError("Junos did not return text managed configuration")
        json.dump(
            {
                "group": canonical_group(group),
                "apply_groups": apply_groups,
                "apply_groups_exceptions": apply_groups_exceptions,
                "direct_reservation_paths": direct_reservation_paths,
            },
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
