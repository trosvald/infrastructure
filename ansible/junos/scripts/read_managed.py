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
DIRECT_RESERVATION_XPATH = (
    "/*[local-name()='configuration']/*[local-name()='access']"
    "/*[local-name()='address-assignment']/*[local-name()='pool']"
    "[*[local-name()='name' and (.='MGMT' or .='PROD' or .='DEV')]]"
    "/*[local-name()='family']/*[local-name()='inet']/*[local-name()='host']"
    " | "
    "/*[local-name()='configuration']/*[local-name()='routing-instances']"
    "/*[local-name()='instance'][*[local-name()='name']='VR-XLSATU']"
    "/*[local-name()='access']/*[local-name()='address-assignment']"
    "/*[local-name()='pool'][*[local-name()='name']='HOME']"
    "/*[local-name()='family']/*[local-name()='inet']/*[local-name()='host']"
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
def _local_name(element: ET.Element) -> str:
    return element.tag.rsplit("}", 1)[-1]


def _single_name(element: ET.Element, kind: str) -> str:
    names = [
        (child.text or "").strip()
        for child in element
        if _local_name(child) == "name"
    ]
    if len(names) != 1 or not names[0]:
        raise RuntimeError(f"direct reservation {kind} must have exactly one nonempty name")
    return names[0]


def normalize_direct_reservation_paths_xml(output: str) -> list[str]:
    root = ET.fromstring(output)
    parents = {child: parent for parent in root.iter() for child in parent}
    paths: list[str] = []
    for host in (element for element in root.iter() if _local_name(element) == "host"):
        ancestors: list[ET.Element] = []
        parent = parents.get(host)
        while parent is not None:
            ancestors.append(parent)
            parent = parents.get(parent)
        ancestors.reverse()
        ancestor_tags = [_local_name(element) for element in ancestors]
        if "groups" in ancestor_tags:
            raise RuntimeError("direct reservation response unexpectedly contains groups")
        try:
            configuration_index = ancestor_tags.index("configuration")
        except ValueError as error:
            raise RuntimeError(
                "direct reservation host is outside configuration"
            ) from error
        hierarchy = ancestors[configuration_index + 1 :] + [host]
        tags = [_local_name(element) for element in hierarchy]
        host_name = _single_name(host, "host")
        if tags == [
            "access",
            "address-assignment",
            "pool",
            "family",
            "inet",
            "host",
        ]:
            pool_name = _single_name(hierarchy[2], "pool")
            if pool_name not in {"MGMT", "PROD", "DEV"}:
                raise RuntimeError("direct reservation has an unexpected master pool")
            path = (
                f"access/address-assignment/pool/{pool_name}/family/inet/host/"
                f"{host_name}"
            )
        elif tags == [
            "routing-instances",
            "instance",
            "access",
            "address-assignment",
            "pool",
            "family",
            "inet",
            "host",
        ]:
            instance_name = _single_name(hierarchy[1], "routing instance")
            pool_name = _single_name(hierarchy[4], "pool")
            if instance_name != "VR-XLSATU" or pool_name != "HOME":
                raise RuntimeError(
                    "direct reservation has an unexpected routing instance or pool"
                )
            path = (
                "routing-instances/VR-XLSATU/access/address-assignment/pool/"
                f"HOME/family/inet/host/{host_name}"
            )
        else:
            raise RuntimeError("direct reservation has an unexpected hierarchy")
        if path in paths:
            raise RuntimeError("duplicate direct reservation path")
        paths.append(path)
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
            direct_reservation_paths = normalize_direct_reservation_paths_xml(
                device._conn.get_config(
                    source="running",
                    filter=("xpath", DIRECT_RESERVATION_XPATH),
                ).data_xml
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
