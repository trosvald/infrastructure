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
            bgp_auth_ref = (
                path == "intent.routing.routing.bgp"
                and key == "authentication_key"
                and child == {"topology": "bgp.authentication_key"}
            )
            if _FORBIDDEN_KEY_RE.search(str(key)) and not bgp_auth_ref:
                raise IntentError(f"{path}: authentication and credential ownership is device-local")
            if not bgp_auth_ref:
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
        "authentication-key",
        "autoupdate",
        "bridge-priority",
        "client-alive-count-max",
        "client-alive-interval",
        "connection-limit",
        "default-policy",
        "description",
        "destination-address",
        "destination-nat",
        "destination-port",
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
        "port",
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

def ordered_policy_paths(lines: list[str]) -> dict[str, list[str]]:
    """Return policy/term order grouped by the hierarchy where order is meaningful."""
    result: dict[str, list[str]] = {}
    for line in lines:
        try:
            tokens = shlex.split(line)
        except ValueError as error:
            raise ValueError("unparseable ordered policy line") from error
        if len(tokens) < 8 or tokens[:3] != ["set", "groups", GROUP]:
            raise ValueError("ordered policy line is outside the managed group")
        body = tokens[3:]
        if body[:2] == ["policy-options", "policy-statement"] and "term" in body:
            term_index = body.index("term")
            parent = "/".join(body[:2] + [body[2]])
            child = body[term_index + 1]
        elif body[:2] == ["security", "policies"] and body[2] == "from-zone":
            if len(body) < 8 or body[4] != "to-zone" or body[6] != "policy":
                raise ValueError("managed security policy hierarchy is invalid")
            parent = f"security/policies/{body[3]}/{body[5]}"
            child = body[7]
        else:
            raise ValueError("line is not an ordered managed policy")
        children = result.setdefault(parent, [])
        if child not in children:
            children.append(child)
    return result

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
    for profile in system.get("ssl_initiation_profiles", []):
        base = ("services", "ssl", "initiation", "profile", profile["name"])
        out.append(cmd(*base, "protocol-version", profile["protocol_version"]))
        out.append(cmd(*base, "trusted-ca", profile["trusted_ca"]))
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
    out: list[str] = [
        cmd("routing-options", "router-id", routing["router_id"]),
        cmd("routing-options", "autonomous-system", routing["autonomous_system"]),
    ]
    for route in routing.get("static_routes", []):
        out.append(cmd("routing-options", "static", "route", route["route"], route["action"]))
    for instance in sorted(routing.get("instances", []), key=lambda x: x["name"]):
        base = ("routing-instances", instance["name"])
        out.append(cmd(*base, "instance-type", instance["type"]))
        out += [
            cmd(*base, "interface", interface)
            for interface in sorted(instance.get("interfaces", []))
        ]
    for policy in routing.get("policies", []):
        for term in policy["terms"]:
            base = (
                "policy-options",
                "policy-statement",
                policy["name"],
                "term",
                term["name"],
            )
            if term.get("from_instance"):
                out.append(cmd(*base, "from", "instance", term["from_instance"]))
            if term.get("from_protocol"):
                out.append(cmd(*base, "from", "protocol", term["from_protocol"]))
            route_filter = term.get("route_filter")
            if isinstance(route_filter, dict):
                out.append(
                    cmd(
                        *base,
                        "from",
                        "route-filter",
                        route_filter["prefix"],
                        "prefix-length-range",
                        route_filter["prefix_length_range"],
                    )
                )
            elif route_filter:
                out.append(cmd(*base, "from", "route-filter", route_filter, "exact"))
            out.append(cmd(*base, "then", term["action"]))
    for binding in routing.get("instance_imports", []):
        instance = (
            binding.get("routing_instance", "master")
            if isinstance(binding, dict)
            else "master"
        )
        policy = binding["policy"] if isinstance(binding, dict) else binding
        base = (
            ("routing-options",)
            if instance == "master"
            else ("routing-instances", instance, "routing-options")
        )
        out.append(cmd(*base, "instance-import", policy))
    bgp = routing["bgp"]
    bgp_base = ("protocols", "bgp", "group", bgp["name"])
    out.extend(
        [
            cmd(*bgp_base, "type", bgp["type"]),
            cmd(*bgp_base, "local-address", bgp["local_address"]),
            cmd(*bgp_base, "peer-as", bgp["peer_as"]),
            cmd(*bgp_base, "authentication-key", bgp["authentication_key"]),
            cmd(*bgp_base, "hold-time", bgp["hold_time"]),
            cmd(*bgp_base, "multipath"),
            cmd(*bgp_base, "import", bgp["import_policy"]),
            cmd(*bgp_base, "export", bgp["export_policy"]),
        ]
    )
    prefix_limit = bgp["unicast"]["prefix_limit"]
    out.append(
        cmd(
            *bgp_base,
            "family",
            bgp["family"],
            "unicast",
            "prefix-limit",
            "maximum",
            prefix_limit["maximum"],
            "teardown",
            prefix_limit["teardown"],
            "idle-timeout",
            prefix_limit["idle_timeout"],
        )
    )
    out += [cmd(*bgp_base, "neighbor", peer) for peer in bgp["neighbors"]]
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
    nat = data["nat"]
    for ruleset in nat.get("source_rules", []):
        base = ("security", "nat", "source", "rule-set", ruleset["name"])
        zones = ruleset["from_zone"] if isinstance(ruleset["from_zone"], list) else [ruleset["from_zone"]]
        out += [cmd(*base, "from", "zone", zone) for zone in zones]
        out.append(cmd(*base, "to", "zone", ruleset["to_zone"]))
        for rule in ruleset["rules"]:
            rb = (*base, "rule", rule["name"])
            out.extend([
                cmd(*rb, "match", "source-address", rule["source"]),
                cmd(*rb, "match", "destination-address", rule["destination"]),
                cmd(*rb, "then", "source-nat", rule["action"]),
            ])
    if any(ruleset.get("enabled", True) for ruleset in nat.get("destination_rules", [])):
        for pool in nat.get("destination_pools", []):
            base = ("security", "nat", "destination", "pool", pool["name"])
            out.extend([
                cmd(*base, "address", pool["address"]),
                cmd(*base, "port", pool["port"]),
            ])
    for ruleset in nat.get("destination_rules", []):
        if not ruleset.get("enabled", True):
            continue
        base = ("security", "nat", "destination", "rule-set", ruleset["name"])
        out.append(cmd(*base, "from", "zone", ruleset["from_zone"]))
        for rule in ruleset["rules"]:
            rb = (*base, "rule", rule["name"])
            out.extend([
                cmd(*rb, "match", "destination-address", rule["destination"]),
                cmd(*rb, "match", "destination-port", rule["destination_port"]),
                cmd(*rb, "match", "protocol", rule["protocol"]),
                cmd(*rb, "then", "destination-nat", "pool", rule["pool"]),
            ])
    return out


def render_security(data: dict[str, Any]) -> list[str]:
    security = data["security"]
    out: list[str] = []
    for address in sorted(security.get("address_books", []), key=lambda x: x["name"]):
        out.append(cmd("security", "address-book", "global", "address", address["name"], address["value"]))
    for screen in security.get("screens", []):
        out += [cmd("security", "screen", "ids-option", screen["name"], *option) for option in screen["options"]]
    log = security.get("log", {})
    if log.get("mode"):
        out.append(cmd("security", "log", "mode", log["mode"]))
    if log.get("cache"):
        out.append(cmd("security", "log", "cache"))
    if log.get("format"):
        out.append(cmd("security", "log", "format", log["format"]))
    if log.get("source_address"):
        out.append(cmd("security", "log", "source-address", log["source_address"]))
    for stream in log.get("streams", []):
        base = ("security", "log", "stream", stream["name"])
        out.append(cmd(*base, "host", stream["host"]))
        out.append(cmd(*base, "host", "port", stream["port"]))
        out.append(cmd(*base, "transport", "protocol", stream["protocol"]))
        out.append(cmd(*base, "transport", "tls-profile", stream["tls_profile"]))
    flow = security.get("flow", {})
    if flow.get("tcp_mss"):
        mss = flow["tcp_mss"]
        out.append(cmd("security", "flow", "tcp-mss", mss.get("scope", "all-tcp"), "mss", mss["value"]))
    for profile in security.get("pki_ca_profiles", []):
        out.append(
            cmd(
                "security", "pki", "ca-profile", profile["name"],
                "ca-identity", profile["ca_identity"],
            )
        )
    for zone in security["zones"]:
        base = ("security", "zones", "security-zone", zone["name"])
        if zone.get("screen"):
            out.append(cmd(*base, "screen", zone["screen"]))
        for interface in zone["interfaces"]:
            interface_base = (*base, "interfaces", interface)
            if not zone.get("services") and not zone.get("protocols"):
                out.append(cmd(*interface_base))
            out += [
                cmd(*interface_base, "host-inbound-traffic", "system-services", service)
                for service in zone.get("services", [])
            ]
            out += [
                cmd(*interface_base, "host-inbound-traffic", "protocols", protocol)
                for protocol in zone.get("protocols", [])
            ]
    for policy in security["policies"]:
        if not policy.get("enabled", True):
            continue
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
    synthetic_topology = parse_address(
        topology["management_address"], "management_address"
    ) in ipaddress.ip_network("203.0.113.0/24")
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
    edge_vlan = next((vlan for vlan in vlans if vlan["name"] == "VLAN-EDGE"), None)
    if edge_vlan != {
        "name": "VLAN-EDGE",
        "id": 2515,
        "irb_unit": 2515,
        "description": "Edge DMZ VLAN",
    }:
        raise IntentError("VLAN-EDGE must retain ID and IRB unit 2515")
    for tor_name in ("xe-0/0/18", "xe-0/0/19"):
        tor = next((item for item in interfaces if item["name"] == tor_name), None)
        if not tor or tor.get("native_vlan") != 2510:
            raise IntentError(f"{tor_name}: TOR trunk and native VLAN 2510 are required")
        tor_units = tor.get("units", [])
        expected_tor_vlans = {"VLAN-MGMT", "VLAN-PROD", "VLAN-HOME", "VLAN-DEV", "VLAN-EDGE"}
        if (
            len(tor_units) != 1
            or tor_units[0].get("mode") != "trunk"
            or set(tor_units[0].get("vlans", [])) != expected_tor_vlans
        ):
            raise IntentError(f"{tor_name}: must carry the four internal VLANs and VLAN-EDGE")
    edge_irb = next(
        (
            unit
            for interface in interfaces
            if interface["name"] == "irb"
            for unit in interface["units"]
            if unit["unit"] == 2515
        ),
        None,
    )
    expected_edge_gateway = "198.18.1.1/24" if synthetic_topology else "10.25.15.1/24"
    if (
        edge_irb is None
        or edge_irb.get("family") != "inet"
        or edge_irb.get("mtu") != 1496
        or edge_irb.get("address") != expected_edge_gateway
    ):
        raise IntentError("irb.2515 must be the reviewed EDGE gateway with MTU 1496")
    expected_edge_network = parse_network(
        "198.18.1.0/24" if synthetic_topology else "10.25.15.0/24",
        "approved EDGE subnet",
    )
    edge_network = parse_network(dotted(topology, "networks.edge.subnet"), "EDGE subnet")
    edge_gateway = parse_address(dotted(topology, "networks.edge.gateway"), "EDGE gateway")
    edge_haproxy = parse_address(dotted(topology, "networks.edge.haproxy"), "EDGE HAProxy")
    if (
        edge_network != expected_edge_network
        or edge_gateway != parse_address(expected_edge_gateway, "approved EDGE gateway")
        or edge_haproxy != parse_address(
            "198.18.1.10" if synthetic_topology else "10.25.15.10",
            "approved EDGE HAProxy",
        )
        or edge_haproxy not in edge_network
    ):
        raise IntentError("EDGE topology must retain the reviewed subnet, gateway, and HAProxy")

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
    bgp_host_zones = {
        zone["name"] for zone in zones if "bgp" in zone.get("protocols", [])
    }
    if bgp_host_zones != {"PROD"}:
        raise IntentError("BGP host-inbound protocol must be present only on PROD")
    prod_zone = next(zone for zone in zones if zone["name"] == "PROD")
    if prod_zone["interfaces"] != ["irb.2511"]:
        raise IntentError("PROD BGP host-inbound must terminate only on irb.2511")
    edge_zone = next((zone for zone in zones if zone["name"] == "EDGE"), None)
    if edge_zone != {"name": "EDGE", "interfaces": ["irb.2515"]}:
        raise IntentError("EDGE must contain only irb.2515 with no host-inbound services")
    screens = intent["security"]["security"].get("screens", [])
    unique(screens, "name", "screen")
    screen_names = {screen["name"] for screen in screens}
    for zone in zones:
        if zone.get("screen") and zone["screen"] not in screen_names:
            raise IntentError(f"zone {zone['name']}: undefined screen")
    expected_vector_address = "198.18.2.37" if synthetic_topology else "10.25.13.37"
    expected_vector_host = (
        "logs-ingest.example.invalid" if synthetic_topology else "logs-ingest.monosense.io"
    )
    expected_ca_profile = "SYNTHETIC-ISRG-ROOT-X1" if synthetic_topology else "LE-ISRG-ROOT-X1"
    if (
        dotted(topology, "monitoring.vector_address") != expected_vector_address
        or dotted(topology, "monitoring.vector_host") != expected_vector_host
        or dotted(topology, "monitoring.syslog_ca_profile") != expected_ca_profile
    ):
        raise IntentError("Vector syslog target and exact CA profile must retain the reviewed contract")
    if intent["security"]["security"].get("pki_ca_profiles") != [
        {"name": expected_ca_profile, "ca_identity": expected_ca_profile}
    ]:
        raise IntentError("SRX system syslog CA profile must retain the reviewed identity")
    if intent["security"]["security"].get("direct_pki_ca_profiles") != [
        {
            "name": "VECTOR-SRX-ROOT",
            "ca_identity": "VECTOR-SRX-ROOT",
            "revocation_check": "disable",
        }
    ]:
        raise IntentError("SRX Vector CA profile must retain the exact direct trust exception")
    expected_stream_log = {
        "mode": "stream",
        "format": "sd-syslog",
        "source_address": dotted(topology, "networks.dev.gateway"),
        "streams": [
            {
                "name": "VECTOR",
                "host": expected_vector_address,
                "port": 6514,
                "protocol": "tls",
                "tls_profile": "VECTOR-SRX-TLS",
            }
        ],
    }
    if intent["security"]["security"].get("log") != expected_stream_log:
        raise IntentError("SRX flow logging must retain the exact verified TLS stream")
    if intent["system"]["system"].get("ssl_initiation_profiles") != [
        {
            "name": "VECTOR-SRX-TLS",
            "protocol_version": "tls12",
            "trusted_ca": "VECTOR-SRX-ROOT",
        }
    ]:
        raise IntentError("SRX flow stream must trust only the dedicated Vector CA")
    expected_remote_syslog = [
        ["host", expected_vector_host, "any", "any"],
        ["host", expected_vector_host, "port", 6514],
        ["host", expected_vector_host, "transport", "tls"],
        ["host", expected_vector_host, "source-address", dotted(topology, "networks.dev.gateway")],
        [
            "host",
            expected_vector_host,
            "tlsdetails",
            "trusted-ca-group",
            "EDGE-SYSLOG-CA",
            "ca-profiles",
            expected_ca_profile,
        ],
    ]
    syslog_rows = intent["system"]["system"].get("syslog", [])
    if any(row not in syslog_rows for row in expected_remote_syslog):
        raise IntentError("SRX syslog must use exact TLS target, source, port, and CA profile")
    if any("trusted-ca" in str(token) and token == "all" for row in syslog_rows for token in row):
        raise IntentError("SRX syslog cannot trust every CA")
    addresses = intent["security"]["security"].get("address_books", [])
    unique(addresses, "name", "global address-book entry")
    address_names = {address["name"] for address in addresses}
    dns_entries = [address for address in addresses if address["name"] == "INTERNAL-DNS"]
    expected_dns_cidr = parse_network(f"{dns_internal}/32", "dns.internal")
    if len(dns_entries) != 1 or parse_network(dns_entries[0]["value"], "INTERNAL-DNS") != expected_dns_cidr:
        raise IntentError("global INTERNAL-DNS address must match dns.internal as an exact /32")
    expected_addresses = {
        "EDGE-HAPROXY": "198.18.1.10/32" if synthetic_topology else "10.25.15.10/32",
        "C0-GATUS": "198.18.2.36/32" if synthetic_topology else "10.25.13.36/32",
        "C0-VECTOR": "198.18.2.37/32" if synthetic_topology else "10.25.13.37/32",
    }
    for name, expected in expected_addresses.items():
        entries = [address for address in addresses if address["name"] == name]
        if len(entries) != 1 or parse_network(entries[0]["value"], name) != parse_network(expected, name):
            raise IntentError(f"global {name} address must remain the reviewed exact /32")

    policies = intent["security"]["security"]["policies"]
    unique(policies, "name", "security policy")
    public_enabled = dotted(topology, "edge.public_enabled")
    if not isinstance(public_enabled, bool):
        raise IntentError("edge.public_enabled must be a boolean deployment gate")
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
        if "enabled" in policy and not isinstance(policy["enabled"], bool):
            raise IntentError(f"policy {policy['name']}: enabled must resolve to a boolean")
    public_policy = next((policy for policy in policies if policy["name"] == "WAN-EDGE-PUBLIC"), None)
    if (
        public_policy is None
        or public_policy.get("enabled") is not public_enabled
        or public_policy["from"] != "WAN-MYREP"
        or public_policy["to"] != "EDGE"
        or public_policy["source"] != ["any"]
        or public_policy["destination"] != ["EDGE-HAPROXY"]
        or public_policy["applications"] != ["junos-ssh", "junos-http", "junos-https"]
        or public_policy["action"] != "permit"
        or public_policy["log"] != ["session-init", "session-close"]
    ):
        raise IntentError("WAN to EDGE policy must retain the exact gated public contract")
    expected_internal_edge = {"MGMT-EDGE", "PROD-EDGE", "HOME-EDGE", "DEV-EDGE"}
    actual_internal_edge = {
        policy["name"]
        for policy in policies
        if policy["to"] == "EDGE" and policy["from"] in {"MGMT", "PROD", "HOME", "DEV"}
    }
    if actual_internal_edge != expected_internal_edge:
        raise IntentError("all four internal zones require one exact HAProxy-only EDGE policy")
    for policy in policies:
        if policy["name"] in expected_internal_edge and (
            policy["source"] != ["any"]
            or policy["destination"] != ["EDGE-HAPROXY"]
            or policy["applications"] != ["junos-ssh", "junos-http", "junos-https"]
            or policy["action"] != "permit"
        ):
            raise IntentError(f"policy {policy['name']}: EDGE access must be HAProxy 22/80/443 only")
    home_dns_policy = next((policy for policy in policies if policy["name"] == "HOME-TO-DNS"), None)
    home_dev_block = next((policy for policy in policies if policy["name"] == "HOME-BLOCK-DEV"), None)
    if (
        home_dns_policy is None
        or home_dev_block is None
        or home_dns_policy["from"] != "HOME"
        or home_dns_policy["to"] != "DEV"
        or home_dns_policy["source"] != ["any"]
        or home_dns_policy["destination"] != ["INTERNAL-DNS"]
        or home_dns_policy["applications"] != ["junos-dns-udp", "junos-dns-tcp"]
        or home_dns_policy["action"] != "permit"
        or policies.index(home_dns_policy) > policies.index(home_dev_block)
    ):
        raise IntentError("HOME DNS access must precede the DEV deny and target only INTERNAL-DNS")
    if any(policy["from"] == "EDGE" and policy["action"] == "permit" for policy in policies):
        raise IntentError("EDGE must not have an internal permit policy")
    gatus_policy = next((policy for policy in policies if policy["name"] == "HOME-TO-GATUS"), None)
    if (
        gatus_policy is None
        or gatus_policy["from"] != "HOME"
        or gatus_policy["to"] != "DEV"
        or gatus_policy["destination"] != ["C0-GATUS"]
        or gatus_policy["applications"] != ["junos-https"]
        or gatus_policy["action"] != "permit"
    ):
        raise IntentError("HOME to Gatus must remain exact HTTPS-only access")
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
    routing = intent["routing"]["routing"]
    policy_by_name = {policy["name"]: policy for policy in routing_policies}
    bgp = routing.get("bgp", {})
    expected_bgp_keys = {
        "name",
        "type",
        "local_address",
        "local_as",
        "peer_as",
        "authentication_key",
        "hold_time",
        "multipath",
        "import_policy",
        "export_policy",
        "family",
        "unicast",
        "neighbors",
    }
    if set(bgp) != expected_bgp_keys:
        raise IntentError("CILIUM BGP group has missing or unsupported fields")
    management_address = parse_address(topology["management_address"], "management_address")
    synthetic = management_address in ipaddress.ip_network("203.0.113.0/24")
    expected_prod = ipaddress.ip_network(
        "198.51.100.0/24" if synthetic else "10.25.11.0/24"
    )
    expected_edge = ipaddress.ip_network(
        "198.18.1.0/24" if synthetic else "10.25.15.0/24"
    )
    expected_gateway = parse_address(
        "198.51.100.1" if synthetic else "10.25.11.1",
        "approved PROD gateway",
    )
    expected_peers = [
        parse_address(
            f"{'198.51.100' if synthetic else '10.25.11'}.{suffix}",
            "approved Cilium peer",
        )
        for suffix in range(11, 16)
    ]
    expected_pool = ipaddress.ip_network("198.18.0.0/24" if synthetic else "10.25.20.0/24")
    prod_network = parse_network(topology["networks"]["prod"]["subnet"], "PROD subnet")
    peers = [parse_address(peer, "CILIUM peer") for peer in bgp["neighbors"]]
    if prod_network != expected_prod or peers != expected_peers:
        raise IntentError("CILIUM peers must be the five approved PROD node addresses")
    if len(peers) != 5 or len(set(peers)) != 5:
        raise IntentError("CILIUM requires exactly five unique peers")
    if any(
        peer not in prod_network
        or peer in {prod_network.network_address, prod_network.broadcast_address, expected_gateway}
        for peer in peers
    ):
        raise IntentError("CILIUM peer is outside PROD or uses its gateway/network/broadcast")
    if (
        routing.get("router_id") != str(expected_gateway)
        or bgp["local_address"] != str(expected_gateway)
        or topology["networks"]["prod"]["gateway"] != str(expected_gateway)
    ):
        raise IntentError("BGP router ID and local address must equal the approved PROD gateway")
    if (
        routing.get("autonomous_system") != 64512
        or bgp["local_as"] != 64512
        or bgp["peer_as"] != 64513
        or bgp["local_as"] == bgp["peer_as"]
    ):
        raise IntentError("CILIUM BGP ASNs must be unique and exactly 64512/64513")
    if not re.fullmatch(r"[A-Za-z0-9_-]{43}", str(bgp["authentication_key"])):
        raise IntentError("CILIUM BGP authentication key must be 43-character base64url")
    if routing.get("static_routes") != [
        {"route": str(expected_pool), "action": "discard"}
    ]:
        raise IntentError("CILIUM LB pool requires one exact static discard fallback")
    expected_import_terms = [
        {
            "name": "CILIUM-LB-HOSTS",
            "from_protocol": "bgp",
            "route_filter": {
                "prefix": str(expected_pool),
                "prefix_length_range": "/32-/32",
            },
            "action": "accept",
        },
        {"name": "REJECT-REST", "action": "reject"},
    ]
    if policy_by_name.get("IMPORT-CILIUM-LB", {}).get("terms") != expected_import_terms:
        raise IntentError("CILIUM import must permit only LB-pool /32 BGP routes then reject")
    expected_home_import_terms = [
        {
            "name": name,
            "from_instance": "master",
            "route_filter": str(network),
            "action": "accept",
        }
        for name, network in (
            ("MGMT", parse_network(topology["networks"]["mgmt"]["subnet"], "MGMT subnet")),
            ("PROD", expected_prod),
            ("DEV", parse_network(topology["networks"]["dev"]["subnet"], "DEV subnet")),
            ("EDGE", expected_edge),
        )
    ]
    expected_home_import_terms.append({"name": "REJECT-REST", "action": "reject"})
    if (
        policy_by_name.get("IMPORT-MASTER-INTERNAL-INTO-HOME", {}).get("terms")
        != expected_home_import_terms
    ):
        raise IntentError("HOME route import must include MGMT, PROD, DEV, and EDGE then reject")
    if policy_by_name.get("EXPORT-CILIUM-NONE", {}).get("terms") != [
        {"name": "REJECT-ALL", "action": "reject"}
    ]:
        raise IntentError("CILIUM export policy must contain only terminal reject")
    if (
        bgp["name"] != "CILIUM"
        or bgp["type"] != "external"
        or bgp["hold_time"] != 9
        or bgp["multipath"] is not True
        or bgp["import_policy"] != "IMPORT-CILIUM-LB"
        or bgp["export_policy"] != "EXPORT-CILIUM-NONE"
        or bgp["family"] != "inet"
        or bgp["unicast"] != {
            "prefix_limit": {"maximum": 128, "teardown": 100, "idle_timeout": 5}
        }
    ):
        raise IntentError("CILIUM BGP group safety settings differ from the approved contract")
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
    nat = intent["nat"]["nat"]
    rulesets = nat.get("source_rules", [])
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

    if set(nat) != {"source_rules", "destination_pools", "destination_rules"}:
        raise IntentError("only reviewed source and destination NAT resources are managed")
    destination_pools = nat["destination_pools"]
    destination_rulesets = nat["destination_rules"]
    unique(destination_pools, "name", "destination NAT pool")
    unique(destination_pools, "port", "destination NAT pool port")
    unique(destination_rulesets, "name", "destination NAT rule-set")
    expected_ports = {22, 80, 443}
    expected_haproxy = parse_network(
        "198.18.1.10/32" if synthetic_topology else "10.25.15.10/32",
        "EDGE HAProxy",
    )
    if (
        {pool["name"] for pool in destination_pools}
        != {"EDGE-SSH", "EDGE-HTTP", "EDGE-HTTPS"}
        or {int(pool["port"]) for pool in destination_pools} != expected_ports
        or any(parse_network(pool["address"], pool["name"]) != expected_haproxy for pool in destination_pools)
    ):
        raise IntentError("destination NAT pools must map exactly TCP 22/80/443 to EDGE HAProxy")
    if len(destination_rulesets) != 1:
        raise IntentError("exactly one WAN-MYREP destination NAT rule-set is required")
    destination_ruleset = destination_rulesets[0]
    if (
        destination_ruleset["name"] != "WAN-MYREP-TO-EDGE"
        or destination_ruleset["from_zone"] != "WAN-MYREP"
        or destination_ruleset.get("enabled") is not public_enabled
    ):
        raise IntentError("destination NAT rule-set must use the protected public deployment gate")
    destination_rules = destination_ruleset["rules"]
    unique(destination_rules, "name", "destination NAT rule")
    unique(destination_rules, "destination_port", "destination NAT public port")
    public_network = parse_network(
        dotted(topology, "wan.secondary_public_cidr"), "wan.secondary_public_cidr"
    )
    if public_network.prefixlen != 32:
        raise IntentError("wan.secondary_public_cidr must be an exact IPv4 /32")
    if public_enabled and not synthetic_topology and not public_network.network_address.is_global:
        raise IntentError("wan.secondary_public_cidr must be globally routable before public EDGE is enabled")
    pools_by_port = {int(pool["port"]): pool["name"] for pool in destination_pools}
    if (
        {int(rule["destination_port"]) for rule in destination_rules} != expected_ports
        or any(rule.get("protocol") != "tcp" for rule in destination_rules)
        or any(parse_network(rule["destination"], rule["name"]) != public_network for rule in destination_rules)
        or any(rule.get("pool") != pools_by_port[int(rule["destination_port"])] for rule in destination_rules)
    ):
        raise IntentError("destination NAT rules must match the exact public /32 and TCP 22/80/443")

    assignments = interface_ips + reservation_ips
    seen: dict[str, str] = {}
    for label, address in assignments:
        key = str(address)
        if key in seen:
            raise IntentError(f"duplicate IP assignment {key}: {seen[key]} and {label}")
        seen[key] = label

    unused = leaves(topology) - used
    allowed_unused = {
        "management_address",
        "networks.edge.subnet",
        "networks.edge.gateway",
        "networks.edge.haproxy",
    }
    unexpected = sorted(unused - allowed_unused)
    if unexpected:
        raise IntentError(f"unused topology keys: {', '.join(unexpected)}")


def build(intent_dir: Path, topology_path: Path, group: str = GROUP) -> tuple[list[str], set[str]]:
    raw = {domain: load_yaml(intent_dir / f"{domain}.yml") for domain in DOMAINS}
    topology = load_yaml(topology_path)
    if dotted(topology, "edge.public_enabled") is False:
        wan = topology.setdefault("wan", {})
        if not isinstance(wan, dict):
            raise IntentError("wan topology must be a mapping")
        wan.setdefault("secondary_public_cidr", "192.0.2.200/32")
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
    parser.add_argument("--order-ids", action="store_true")
    args = parser.parse_args()
    if args.path_ids or args.order_ids:
        try:
            lines = json.load(sys.stdin)
            if not isinstance(lines, list) or not all(isinstance(line, str) for line in lines):
                raise ValueError("expected a JSON list of command lines")
            value = ordered_policy_paths(lines) if args.order_ids else value_free_paths(lines)
            print(json.dumps(value, separators=(",", ":")))
            return 0
        except (json.JSONDecodeError, ValueError) as error:
            print(f"identifier input failed: {error}", file=sys.stderr)
            return 2
    if args.intent_dir is None or args.topology is None:
        parser.error("--intent-dir and --topology are required unless an identifier mode is used")
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
