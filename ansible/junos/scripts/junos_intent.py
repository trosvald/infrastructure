#!/usr/bin/env python3
"""Validate structured SRX intent and render a deterministic Junos set candidate."""
from __future__ import annotations

import argparse
import hashlib
import ipaddress
import json
import os
import re
import shlex
import stat
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Any

DOMAINS = ("system", "interfaces", "vlans", "dhcp", "routing", "nat", "security")
GROUP = "ANSIBLE_SRX1500"
_FORBIDDEN_KEY_RE = re.compile(
    r"(?:^|[-_])(login|root[-_]?authentication|authentication|private[-_]?key|password|secret)(?:$|[-_])",
    re.IGNORECASE,
)


class IntentError(ValueError):
    """Raised when intent is incomplete, unsafe, or cross-domain inconsistent."""


def load_yaml(path: Path) -> dict[str, Any]:
    result = subprocess.run(
        ["yq", "--output-format=json", ".", str(path)],
        text=True,
        capture_output=True,
        check=False,
    )
    if result.returncode:
        raise IntentError(f"{path}: yq failed: {result.stderr.strip()}")
    try:
        value = json.loads(result.stdout) if result.stdout.strip() else {}
    except json.JSONDecodeError as error:
        raise IntentError(f"{path}: invalid YAML/JSON: {error}") from error
    if not isinstance(value, dict):
        raise IntentError(f"{path}: root must be a mapping")
    return value


def dotted(value: dict[str, Any], key: str) -> Any:
    current: Any = value
    for part in key.split("."):
        if not isinstance(current, dict) or part not in current:
            raise IntentError(f"undefined topology key: {key}")
        current = current[part]
    return current


def collect_refs(value: Any, refs: set[str]) -> None:
    if isinstance(value, dict):
        if set(value) == {"topology"}:
            refs.add(str(value["topology"]))
            return
        for child in value.values():
            collect_refs(child, refs)
    elif isinstance(value, list):
        for child in value:
            collect_refs(child, refs)


def reject_unsafe_keys(value: Any, path: str = "intent") -> None:
    if isinstance(value, dict):
        for key, child in value.items():
            if _FORBIDDEN_KEY_RE.search(str(key)):
                raise IntentError(f"{path}: authentication and credential ownership is device-local")
            reject_unsafe_keys(child, f"{path}.{key}")
    elif isinstance(value, list):
        for index, child in enumerate(value):
            reject_unsafe_keys(child, f"{path}[{index}]")
    elif isinstance(value, str) and re.search(
        r"(^|[\s_-])(login|root[-_]?authentication|authentication|private[-_]?key|password|secret)(?:$|[\s_-])",
        value,
        re.IGNORECASE,
    ):
        raise IntentError(f"{path}: authentication and credential ownership is device-local")


def resolve(value: Any, topology: dict[str, Any], used: set[str]) -> Any:
    if isinstance(value, dict) and set(value) == {"topology"}:
        key = str(value["topology"])
        if "blocky" in key.lower():
            raise IntentError("DNS topology must use the managed resolver field, not Blocky")
        used.add(key)
        return dotted(topology, key)
    if isinstance(value, dict):
        return {k: resolve(v, topology, used) for k, v in value.items()}
    if isinstance(value, list):
        return [resolve(v, topology, used) for v in value]
    return value


def leaves(value: Any, prefix: str = "") -> set[str]:
    if isinstance(value, dict):
        result: set[str] = set()
        for key, child in value.items():
            result |= leaves(child, f"{prefix}.{key}" if prefix else str(key))
        return result
    return {prefix}


def q(value: Any) -> str:
    text = str(value).lower() if isinstance(value, bool) else str(value)
    if re.fullmatch(r"[A-Za-z0-9_.*:/@+,-]+", text):
        return text
    return json.dumps(text, ensure_ascii=True)


def cmd(*tokens: Any) -> str:
    return " ".join(q(token) for token in tokens if token is not None)

_PATH_LEAVES = frozenset(
    {
        "address",
        "address-assignment",
        "alarm-threshold",
        "application",
        "archive",
        "attack-threshold",
        "autoupdate",
        "bridge-priority",
        "client-alive-count-max",
        "client-alive-interval",
        "connection-limit",
        "default-policy",
        "description",
        "destination-address",
        "dhcp",
        "dhcp-attributes",
        "domain-name",
        "drop-all-tcp",
        "exact",
        "family",
        "files",
        "force-discover",
        "from",
        "hardware-address",
        "host",
        "host-inbound-traffic",
        "host-name",
        "ids-option",
        "instance-import",
        "instance-type",
        "interface",
        "interfaces",
        "interface-mode",
        "ip-address",
        "l3-interface",
        "license",
        "log",
        "low",
        "mac",
        "macs",
        "max-configurations-on-flash",
        "max-sessions-per-connection",
        "maximum-lease-time",
        "members",
        "mode",
        "mss",
        "name-server",
        "native-vlan-id",
        "network",
        "option",
        "pool",
        "prefer",
        "policy-statement",
        "protocol",
        "protocol-version",
        "range",
        "rate-limit",
        "retransmission-interval",
        "route-filter",
        "router",
        "screen",
        "security-log",
        "server",
        "service",
        "services",
        "size",
        "source",
        "source-address",
        "source-nat",
        "source-threshold",
        "system-services",
        "tcp-drop-synfin-set",
        "tcp-mss",
        "term",
        "then",
        "time-zone",
        "timeout",
        "to",
        "url",
        "user",
        "value",
        "vlan-id",
        "web-management",
    }
)
_PATH_ROOTS = frozenset(
    {
        "access",
        "interfaces",
        "policy-options",
        "protocols",
        "routing-instances",
        "routing-options",
        "security",
        "system",
        "vlans",
    }
)


def secure_write(path: Path, payload: str) -> None:
    """Atomically write a private artifact without following output symlinks."""
    parent = path.parent
    try:
        parent_info = parent.stat()
        parent_link = parent.is_symlink()
    except OSError as error:
        raise IntentError(f"artifact directory is unavailable: {parent}") from error
    if parent_link or not stat.S_ISDIR(parent_info.st_mode) or parent_info.st_uid != os.getuid() or stat.S_IMODE(parent_info.st_mode) != 0o700:
        raise IntentError(f"artifact directory must be an owner-only 0700 directory: {parent}")
    temporary_name: str | None = None
    try:
        fd, temporary_name = tempfile.mkstemp(prefix=f".{path.name}.", dir=parent)
        with os.fdopen(fd, "w", encoding="utf-8") as output:
            os.fchmod(output.fileno(), 0o600)
            output.write(payload)
            output.flush()
            os.fsync(output.fileno())
        os.replace(temporary_name, path)
        temporary_name = None
    except OSError as error:
        raise IntentError(f"unable to write protected artifact: {path}") from error
    finally:
        if temporary_name is not None:
            try:
                os.unlink(temporary_name)
            except FileNotFoundError:
                pass


def value_free_path(line: str) -> str:
    """Return an allowlisted Junos hierarchy identifier with leaf values removed."""
    try:
        tokens = shlex.split(line)
    except ValueError:
        return "unparseable"
    if len(tokens) < 4 or tokens[:2] != ["set", "groups"] or tokens[2] != GROUP:
        return "unparseable"
    body = tokens[3:]
    if not body or body[0] not in _PATH_ROOTS:
        return "unrecognized"
    positions = [index for index, token in enumerate(body) if token in _PATH_LEAVES]
    if not positions:
        return "/".join(body) if body[0] in {"system", "protocols"} else f"{body[0]}/unclassified"
    if "route-filter" in body:
        position = body.index("route-filter")
    elif body[:2] == ["system", "ntp"] and "server" in body:
        position = body.index("server")
    else:
        position = positions[-1]
    if body[position] == "route-filter":
        body = body[:position] + ["route-filter"]
    else:
        body = body[: position + 1]
    return "/".join(body)


def value_free_paths(lines: list[str]) -> list[str]:
    return [value_free_path(line) for line in lines]

def unique(items: list[Any], key: str, label: str) -> None:
    values = [item[key] for item in items]
    repeated = sorted({v for v in values if values.count(v) > 1}, key=str)
    if repeated:
        raise IntentError(f"duplicate {label}: {', '.join(map(str, repeated))}")


def render_system(data: dict[str, Any]) -> list[str]:
    system = data["system"]
    out = [cmd("system", "host-name", system["hostname"]), cmd("system", "time-zone", system["timezone"])]
    if system.get("domain"):
        out.append(cmd("system", "domain-name", system["domain"]))
    out += [cmd("system", "services", *row) for row in system.get("services", [])]
    out += [cmd("system", "name-server", address) for address in system.get("name_servers", [])]
    for server in system.get("ntp_servers", []):
        out.append(cmd("system", "ntp", "server", server["address"], "prefer" if server.get("prefer") else None))
    out += [cmd("system", "syslog", *row) for row in system.get("syslog", [])]
    out += [cmd("system", *row) for row in system.get("options", [])]
    return out


def render_vlans(data: dict[str, Any]) -> list[str]:
    out: list[str] = []
    for vlan in sorted(data["vlans"], key=lambda x: x["id"]):
        base = ("vlans", vlan["name"])
        out.extend([cmd(*base, "description", vlan["description"]), cmd(*base, "vlan-id", vlan["id"]), cmd(*base, "l3-interface", f"irb.{vlan['irb_unit']}")])
    return out


def render_interfaces(data: dict[str, Any]) -> list[str]:
    out: list[str] = []
    for interface in sorted(data["interfaces"], key=lambda x: x["name"]):
        base = ("interfaces", interface["name"])
        if interface.get("description"):
            out.append(cmd(*base, "description", interface["description"]))
        if interface.get("mac"):
            out.append(cmd(*base, "mac", interface["mac"]))
        if interface.get("native_vlan") is not None:
            out.append(cmd(*base, "native-vlan-id", interface["native_vlan"]))
        for unit in sorted(interface["units"], key=lambda x: x["unit"]):
            ub = (*base, "unit", unit["unit"], "family", unit["family"])
            if unit.get("dhcp"):
                out.extend([cmd(*ub, "dhcp", "retransmission-interval", 60), cmd(*ub, "dhcp", "force-discover")])
            if unit.get("mtu"):
                out.append(cmd(*ub, "mtu", unit["mtu"]))
            if unit.get("address"):
                out.append(cmd(*ub, "address", unit["address"]))
            if unit.get("mode"):
                out.append(cmd(*ub, "interface-mode", unit["mode"]))
            for vlan in unit.get("vlans", []):
                out.append(cmd(*ub, "vlan", "members", vlan))
    return out


def render_dhcp(data: dict[str, Any]) -> list[str]:
    out: list[str] = []
    for pool in sorted(data["dhcp"]["pools"], key=lambda x: (x.get("routing_instance", "master"), x["name"])):
        instance = pool.get("routing_instance", "master")
        prefix = ("routing-instances", instance) if instance != "master" else ()
        base = (*prefix, "access", "address-assignment", "pool", pool["name"], "family", "inet")
        out.extend([cmd(*base, "network", pool["network"]), cmd(*base, "range", pool["range"]["name"], "low", pool["range"]["low"]), cmd(*base, "range", pool["range"]["name"], "high", pool["range"]["high"]), cmd(*base, "dhcp-attributes", "router", pool["router"]), cmd(*base, "dhcp-attributes", "maximum-lease-time", pool.get("maximum_lease_time", 86400))])
        out += [cmd(*base, "dhcp-attributes", "name-server", dns) for dns in pool.get("dns", [])]
        for option in pool.get("options", []):
            out.append(cmd(*base, "dhcp-attributes", "option", option["code"], option.get("format"), option["value"]))
        for reservation in sorted(pool.get("reservations", []), key=lambda x: x["name"]):
            rb = (*base, "host", reservation["name"])
            out.extend([cmd(*rb, "hardware-address", reservation["mac"]), cmd(*rb, "ip-address", reservation["ip"])])
    for group in sorted(data["dhcp"].get("groups", []), key=lambda x: (x.get("routing_instance", "master"), x["name"])):
        instance = group.get("routing_instance", "master")
        if instance == "master":
            base = ("system", "services", "dhcp-local-server", "group", group["name"])
        else:
            base = ("routing-instances", instance, "system", "services", "dhcp-local-server", "group", group["name"])
        out.append(cmd(*base, "interface", group["interface"]))
        out.extend(cmd(*base, "overrides", option) for option in group.get("overrides", []))
    service = data["dhcp"].get("service", {})
    for option in service.get("options", []):
        out.append(cmd("system", "services", "dhcp-local-server", *option))
    instances = sorted(
        {
            group.get("routing_instance", "master")
            for group in data["dhcp"].get("groups", [])
            if group.get("routing_instance", "master") != "master"
        }
    )
    for instance in instances:
        for option in service.get("options", []):
            out.append(
                cmd(
                    "routing-instances",
                    instance,
                    "system",
                    "services",
                    "dhcp-local-server",
                    *option,
                )
            )
    return out


def render_routing(data: dict[str, Any]) -> list[str]:
    routing = data["routing"]
    out: list[str] = []
    for instance in sorted(routing.get("instances", []), key=lambda x: x["name"]):
        base = ("routing-instances", instance["name"])
        out.append(cmd(*base, "instance-type", instance["type"]))
        out += [cmd(*base, "interface", interface) for interface in sorted(instance.get("interfaces", []))]
    for policy in routing.get("policies", []):
        for term in policy["terms"]:
            base = ("policy-options", "policy-statement", policy["name"], "term", term["name"])
            if term.get("from_instance"):
                out.append(cmd(*base, "from", "instance", term["from_instance"]))
            if term.get("from_protocol"):
                out.append(cmd(*base, "from", "protocol", term["from_protocol"]))
            if term.get("route_filter"):
                out.append(cmd(*base, "from", "route-filter", term["route_filter"], "exact"))
            out.append(cmd(*base, "then", term["action"]))
    for binding in routing.get("instance_imports", []):
        instance = binding.get("routing_instance", "master") if isinstance(binding, dict) else "master"
        policy = binding["policy"] if isinstance(binding, dict) else binding
        base = ("routing-options",) if instance == "master" else ("routing-instances", instance, "routing-options")
        out.append(cmd(*base, "instance-import", policy))
    rstp = routing.get("rstp", {})
    if rstp.get("bridge_priority") is not None:
        out.append(cmd("protocols", "rstp", "bridge-priority", rstp["bridge_priority"]))
    for interface in rstp.get("interfaces", []):
        if isinstance(interface, str):
            name, mode = interface, None
        else:
            name, mode = interface["name"], interface.get("mode")
        out.append(cmd("protocols", "rstp", "interface", name, "mode", mode))
    for protocol in routing.get("protocols", []):
        out.append(cmd("protocols", *protocol))
    return out


def render_nat(data: dict[str, Any]) -> list[str]:
    out: list[str] = []
    for ruleset in data["nat"].get("source_rules", []):
        base = ("security", "nat", "source", "rule-set", ruleset["name"])
        zones = ruleset["from_zone"] if isinstance(ruleset["from_zone"], list) else [ruleset["from_zone"]]
        out += [cmd(*base, "from", "zone", zone) for zone in zones]
        out.append(cmd(*base, "to", "zone", ruleset["to_zone"]))
        for rule in ruleset["rules"]:
            rb = (*base, "rule", rule["name"])
            out.extend([cmd(*rb, "match", "source-address", rule["source"]), cmd(*rb, "match", "destination-address", rule["destination"]), cmd(*rb, "then", "source-nat", rule["action"])])
    return out


def render_security(data: dict[str, Any]) -> list[str]:
    security = data["security"]
    out: list[str] = []
    for address in sorted(security.get("address_books", []), key=lambda x: x["name"]):
        out.append(cmd("security", "address-book", "global", "address", address["name"], address["value"]))
    for screen in security.get("screens", []):
        out += [cmd("security", "screen", "ids-option", screen["name"], *option) for option in screen["options"]]
    if security.get("log", {}).get("mode"):
        out.append(cmd("security", "log", "mode", security["log"]["mode"]))
    flow = security.get("flow", {})
    if flow.get("tcp_mss"):
        mss = flow["tcp_mss"]
        out.append(cmd("security", "flow", "tcp-mss", mss.get("scope", "all-tcp"), "mss", mss["value"]))
    for zone in security["zones"]:
        base = ("security", "zones", "security-zone", zone["name"])
        if zone.get("screen"):
            out.append(cmd(*base, "screen", zone["screen"]))
        for interface in zone["interfaces"]:
            interface_base = (*base, "interfaces", interface)
            out += [
                cmd(*interface_base, "host-inbound-traffic", "system-services", service)
                for service in zone.get("services", [])
            ]
    for policy in security["policies"]:
        base = ("security", "policies", "from-zone", policy["from"], "to-zone", policy["to"], "policy", policy["name"])
        out += [cmd(*base, "match", "source-address", item) for item in policy["source"]]
        out += [cmd(*base, "match", "destination-address", item) for item in policy["destination"]]
        out += [cmd(*base, "match", "application", item) for item in policy["applications"]]
        for event in policy.get("log", []):
            out.append(cmd(*base, "then", "log", event))
        out.append(cmd(*base, "then", policy["action"]))
    out.append(cmd("security", "policies", "default-policy", security["default_policy"]))
    if security.get("pre_id_default_policy"):
        out.append(cmd("security", "policies", "pre-id-default-policy", *security["pre_id_default_policy"]))
    return out


RENDERERS = {"system": render_system, "interfaces": render_interfaces, "vlans": render_vlans, "dhcp": render_dhcp, "routing": render_routing, "nat": render_nat, "security": render_security}


def parse_network(value: Any, label: str) -> ipaddress._BaseNetwork:
    try:
        return ipaddress.ip_network(str(value), strict=False)
    except ValueError as error:
        raise IntentError(f"{label}: invalid network {value}") from error


def parse_address(value: Any, label: str) -> ipaddress._BaseAddress:
    try:
        return ipaddress.ip_address(str(value).split("/", 1)[0])
    except ValueError as error:
        raise IntentError(f"{label}: invalid address {value}") from error


def validate(intent: dict[str, Any], topology: dict[str, Any], used: set[str], refs: set[str] | None = None) -> None:
    refs = refs or set()
    unsafe_refs = sorted(ref for ref in refs if "blocky" in ref.lower())
    if unsafe_refs:
        raise IntentError(f"DNS topology must use the managed resolver field, not Blocky: {', '.join(unsafe_refs)}")
    if not {"dns.internal", "dns.internal_cidr"}.issubset(refs):
        raise IntentError("production DNS must be represented by dns.internal and dns.internal_cidr topology references")
    if not {"dns.primary", "dns.secondary"}.issubset(refs):
        raise IntentError("system DNS topology references are incomplete")
    vlans = intent["vlans"]["vlans"]
    unique(vlans, "name", "VLAN name")
    unique(vlans, "id", "VLAN ID")
    unique(vlans, "irb_unit", "IRB unit")
    vlan_names = {vlan["name"] for vlan in vlans}
    vlan_by_irb = {vlan["irb_unit"]: vlan["name"] for vlan in vlans}
    expected_irb_units = set(vlan_by_irb)

    interfaces = intent["interfaces"]["interfaces"]
    unique(interfaces, "name", "interface")
    interface_names = {interface["name"] for interface in interfaces}
    interface_units: set[str] = set()
    interface_ips: list[tuple[str, ipaddress._BaseAddress]] = []
    interface_addresses: dict[str, ipaddress._BaseAddress] = {}
    interface_networks: dict[str, ipaddress._BaseNetwork] = {}
    for interface in interfaces:
        units = interface["units"]
        unique(units, "unit", f"unit on {interface['name']}")
        if interface.get("mac") and not re.fullmatch(r"[0-9A-Fa-f]{2}(?::[0-9A-Fa-f]{2}){5}", str(interface["mac"])):
            raise IntentError(f"{interface['name']}: invalid MAC address")
        for unit in units:
            unit_name = f"{interface['name']}.{unit['unit']}"
            interface_units.add(unit_name)
            missing = set(unit.get("vlans", [])) - vlan_names
            if missing:
                raise IntentError(f"{unit_name}: undefined VLANs: {sorted(missing)}")
            mode = unit.get("mode")
            if mode == "trunk" and interface.get("native_vlan") != 2510:
                raise IntentError(f"{unit_name}: live trunks must retain native VLAN 2510")
            if mode == "access" and interface.get("native_vlan") is not None:
                raise IntentError(f"{unit_name}: access interfaces cannot define a native VLAN")
            if unit.get("address"):
                address = parse_address(unit["address"], unit_name)
                interface_ips.append((unit_name, address))
                interface_addresses[unit_name] = address
                interface_networks[unit_name] = parse_network(unit["address"], unit_name)
            if interface["name"] == "irb" and unit["unit"] in vlan_by_irb and unit.get("family") != "inet":
                raise IntentError(f"{unit_name}: VLAN IRB must use family inet")
    actual_irb_units = {unit["unit"] for interface in interfaces if interface["name"] == "irb" for unit in interface["units"]}
    if actual_irb_units != expected_irb_units:
        raise IntentError(f"IRB units must match VLAN IRB references: expected {sorted(expected_irb_units)}")

    c0 = next((interface for interface in interfaces if interface["name"] == "ge-0/0/2"), None)
    if not c0 or c0.get("description") != "TO-C0-TRUNK" or c0.get("native_vlan") != 2510:
        raise IntentError("ge-0/0/2 must remain TO-C0-TRUNK with native VLAN 2510")
    c0_units = c0.get("units", [])
    if len(c0_units) != 1 or c0_units[0].get("mode") != "trunk" or set(c0_units[0].get("vlans", [])) != {"VLAN-MGMT", "VLAN-DEV"}:
        raise IntentError("ge-0/0/2 trunk must carry exactly VLAN-MGMT and VLAN-DEV")

    pools = intent["dhcp"]["dhcp"]["pools"]
    unique(pools, "name", "DHCP pool")
    pool_names = {pool["name"] for pool in pools}
    reservations: list[dict[str, Any]] = []
    reservation_ips: list[tuple[str, ipaddress._BaseAddress]] = []
    instance_names = {i["name"] for i in intent["routing"]["routing"].get("instances", [])}
    dns_internal = parse_address(dotted(topology, "dns.internal"), "dns.internal")
    for pool in pools:
        network = parse_network(pool["network"], f"DHCP pool {pool['name']}")
        router = parse_address(pool["router"], f"DHCP pool {pool['name']} router")
        if router not in network:
            raise IntentError(f"DHCP pool {pool['name']} router is outside {network}")
        resolved_dns = [parse_address(value, f"DHCP pool {pool['name']} DNS") for value in pool.get("dns", [])]
        if resolved_dns != [dns_internal]:
            raise IntentError(f"DHCP pool {pool['name']} must use only dns.internal")
        low = parse_address(pool["range"]["low"], f"DHCP pool {pool['name']} low")
        high = parse_address(pool["range"]["high"], f"DHCP pool {pool['name']} high")
        if low not in network or high not in network or int(low) > int(high):
            raise IntentError(f"DHCP pool {pool['name']} range is outside {network} or reversed")
        if pool.get("routing_instance", "master") != "master" and pool["routing_instance"] not in instance_names:
            raise IntentError(f"DHCP pool {pool['name']}: undefined routing instance")
        for reservation in pool.get("reservations", []):
            ip = parse_address(reservation["ip"], f"reservation {reservation['name']}")
            if ip not in network:
                raise IntentError(f"reservation {reservation['name']} is outside {network}")
            reservations.append(reservation)
            reservation_ips.append((f"reservation {reservation['name']}", ip))
        for option in pool.get("options", []):
            if int(option["code"]) != 138 or option.get("format") != "ip-address":
                raise IntentError(f"DHCP pool {pool['name']}: option 138 must use ip-address format")
    unique(reservations, "name", "reservation name")
    unique(reservations, "mac", "reservation MAC")
    unique(reservations, "ip", "reservation IP")
    for group in intent["dhcp"]["dhcp"].get("groups", []):
        if group.get("pool") not in pool_names:
            raise IntentError(f"DHCP group {group['name']}: undefined pool")
        if group["interface"] not in interface_units:
            raise IntentError(f"DHCP group {group['name']}: undefined interface")
        pool = next(pool for pool in pools if pool["name"] == group["pool"])
        if group.get("routing_instance", "master") != pool.get("routing_instance", "master"):
            raise IntentError(f"DHCP group {group['name']}: routing instance does not match pool")
        if group["interface"] not in interface_networks:
            raise IntentError(f"DHCP group {group['name']}: bound interface has no address")
        if parse_network(pool["network"], pool["name"]) != interface_networks[group["interface"]]:
            raise IntentError(f"DHCP group {group['name']}: pool network does not match interface network")
        if parse_address(pool["router"], pool["name"]) != interface_addresses[group["interface"]]:
            raise IntentError(f"DHCP group {group['name']}: pool router must equal bound interface address")

    zones = intent["security"]["security"]["zones"]
    unique(zones, "name", "zone")
    zone_names = {zone["name"] for zone in zones}
    for zone in zones:
        missing = set(zone["interfaces"]) - interface_units
        if missing:
            raise IntentError(f"zone {zone['name']}: undefined interfaces: {sorted(missing)}")
    screens = intent["security"]["security"].get("screens", [])
    unique(screens, "name", "screen")
    screen_names = {screen["name"] for screen in screens}
    for zone in zones:
        if zone.get("screen") and zone["screen"] not in screen_names:
            raise IntentError(f"zone {zone['name']}: undefined screen")
    addresses = intent["security"]["security"].get("address_books", [])
    unique(addresses, "name", "global address-book entry")
    address_names = {address["name"] for address in addresses}
    dns_entries = [address for address in addresses if address["name"] == "MGMT-DNS"]
    expected_dns_cidr = parse_network(f"{dns_internal}/32", "dns.internal")
    if len(dns_entries) != 1 or parse_network(dns_entries[0]["value"], "MGMT-DNS") != expected_dns_cidr:
        raise IntentError("global MGMT-DNS address must match dns.internal as an exact /32")

    policies = intent["security"]["security"]["policies"]
    unique(policies, "name", "security policy")
    for policy in policies:
        if policy["from"] not in zone_names or policy["to"] not in zone_names:
            raise IntentError(f"policy {policy['name']}: undefined zone")
        if policy.get("action") not in {"permit", "deny", "reject"}:
            raise IntentError(f"policy {policy['name']}: terminal action required")
        if not policy.get("source") or not policy.get("destination") or not policy.get("applications"):
            raise IntentError(f"policy {policy['name']}: match criteria are required")
        if any(item not in address_names and item != "any" for item in policy["destination"]):
            raise IntentError(f"policy {policy['name']}: undefined address-book reference")
        if any(event not in {"session-init", "session-close"} for event in policy.get("log", [])):
            raise IntentError(f"policy {policy['name']}: unsupported log event")
    if intent["security"]["security"].get("default_policy") != "deny-all":
        raise IntentError("security default policy must remain deny-all")

    instances_list = intent["routing"]["routing"].get("instances", [])
    unique(instances_list, "name", "routing instance")
    instances = {instance["name"] for instance in instances_list}
    provider_instances = [instance for instance in instances_list if instance["name"] == "VR-XLSATU"]
    if len(provider_instances) != 1 or set(provider_instances[0].get("interfaces", [])) != {"ge-0/0/0.0", "irb.2512"}:
        raise IntentError("VR-XLSATU must contain exactly the primary WAN and HOME IRB")
    expected_wan_zones = {"WAN-XLSATU": {"ge-0/0/0.0"}, "WAN-MYREP": {"ge-0/0/1.0"}}
    actual_wan_zones = {zone["name"]: set(zone["interfaces"]) for zone in zones if zone["name"] in expected_wan_zones}
    if actual_wan_zones != expected_wan_zones:
        raise IntentError("WAN zones must retain their reviewed interfaces")
    for instance in instances_list:
        for interface in instance.get("interfaces", []):
            if interface not in interface_units:
                raise IntentError(f"routing instance {instance['name']}: undefined interface {interface}")
    routing_policies = intent["routing"]["routing"].get("policies", [])
    unique(routing_policies, "name", "routing policy")
    routing_policy_names = {policy["name"] for policy in routing_policies}
    for policy in routing_policies:
        unique(policy["terms"], "name", f"routing policy term in {policy['name']}")
        for index, term in enumerate(policy["terms"]):
            if term.get("from_instance") and term["from_instance"] not in instances | {"master"}:
                raise IntentError(f"policy {policy['name']}: undefined instance")
            if term.get("action") not in {"accept", "reject"}:
                raise IntentError(f"policy {policy['name']} term {term['name']}: terminal action required")
            if term["action"] == "reject" and index != len(policy["terms"]) - 1:
                raise IntentError(f"policy {policy['name']}: reject term must remain last")
    for binding in intent["routing"]["routing"].get("instance_imports", []):
        instance = binding.get("routing_instance", "master") if isinstance(binding, dict) else "master"
        policy = binding["policy"] if isinstance(binding, dict) else binding
        if instance != "master" and instance not in instances:
            raise IntentError(f"instance import: undefined routing instance {instance}")
        if policy not in routing_policy_names:
            raise IntentError(f"instance import: undefined policy {policy}")
    rstp = intent["routing"]["routing"].get("rstp", {})
    for rstp_interface in rstp.get("interfaces", []):
        name = rstp_interface if isinstance(rstp_interface, str) else rstp_interface["name"]
        if name not in interface_names:
            raise IntentError(f"RSTP: undefined interface {name}")
    rulesets = intent["nat"]["nat"].get("source_rules", [])
    unique(rulesets, "name", "NAT rule-set")
    expected_nat = {
        "HOME-TO-XLSATU": ({"HOME"}, "WAN-XLSATU"),
        "MGMT-TO-MYREP": ({"MGMT"}, "WAN-MYREP"),
        "PROD-TO-MYREP": ({"PROD"}, "WAN-MYREP"),
        "DEV-TO-MYREP": ({"DEV"}, "WAN-MYREP"),
    }
    actual_nat = {}
    for ruleset in rulesets:
        sources = ruleset["from_zone"] if isinstance(ruleset["from_zone"], list) else [ruleset["from_zone"]]
        if set(sources + [ruleset["to_zone"]]) - zone_names:
            raise IntentError(f"NAT rule-set {ruleset['name']}: undefined zone")
        actual_nat[ruleset["name"]] = (set(sources), ruleset["to_zone"])
        unique(ruleset["rules"], "name", f"NAT rule in {ruleset['name']}")
        for rule in ruleset["rules"]:
            if rule.get("action") != "interface":
                raise IntentError(f"NAT rule {rule['name']}: only interface source NAT is managed")
    if actual_nat != expected_nat:
        raise IntentError("WAN source NAT rule-sets must retain their reviewed zone coupling")
    forbidden_nat = sorted(set(intent["nat"]["nat"]) - {"source_rules"})
    if forbidden_nat:
        raise IntentError(f"destination/static NAT and proxy ARP are not managed: {', '.join(forbidden_nat)}")

    assignments = interface_ips + reservation_ips
    seen: dict[str, str] = {}
    for label, address in assignments:
        key = str(address)
        if key in seen:
            raise IntentError(f"duplicate IP assignment {key}: {seen[key]} and {label}")
        seen[key] = label

    unused = leaves(topology) - used
    allowed_unused = {"management_address"}
    unexpected = sorted(unused - allowed_unused)
    if unexpected:
        raise IntentError(f"unused topology keys: {', '.join(unexpected)}")


def build(intent_dir: Path, topology_path: Path, group: str = GROUP) -> tuple[list[str], set[str]]:
    raw = {domain: load_yaml(intent_dir / f"{domain}.yml") for domain in DOMAINS}
    topology = load_yaml(topology_path)
    reject_unsafe_keys(raw)
    refs: set[str] = set()
    collect_refs(raw, refs)
    used: set[str] = set()
    intent = resolve(raw, topology, used)
    validate(intent, topology, used, refs)
    body: list[str] = []
    for domain in DOMAINS:
        body.extend(RENDERERS[domain](intent[domain]))
    if len(body) != len(set(body)):
        duplicates = sorted({line for line in body if body.count(line) > 1})
        raise IntentError(f"duplicate rendered commands: {duplicates}")
    candidate = [f"delete groups {q(group)}"]
    candidate += [f"set groups {q(group)} {line}" for line in body]
    candidate.append(f"set apply-groups {q(group)}")
    return candidate, used


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--intent-dir", type=Path)
    parser.add_argument("--topology", type=Path)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--group", default=GROUP)
    parser.add_argument("--check", action="store_true")
    parser.add_argument("--path-ids", action="store_true")
    args = parser.parse_args()
    if args.path_ids:
        try:
            lines = json.load(sys.stdin)
            if not isinstance(lines, list) or not all(isinstance(line, str) for line in lines):
                raise ValueError("expected a JSON list of command lines")
            print(json.dumps(value_free_paths(lines), separators=(",", ":")))
            return 0
        except (json.JSONDecodeError, ValueError) as error:
            print(f"path identifier input failed: {error}", file=sys.stderr)
            return 2
    if args.intent_dir is None or args.topology is None:
        parser.error("--intent-dir and --topology are required unless --path-ids is used")
    try:
        candidate, _ = build(args.intent_dir, args.topology, args.group)
    except (IntentError, KeyError, TypeError, ipaddress.AddressValueError) as error:
        print(f"intent validation failed: {error}", file=sys.stderr)
        return 2
    payload = "\n".join(candidate) + "\n"
    digest = hashlib.sha256(payload.encode()).hexdigest()
    if args.output:
        secure_write(args.output, payload)
    if not args.check:
        sys.stdout.write(payload)
    print(f"sha256:{digest}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
