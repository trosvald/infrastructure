#!/usr/bin/env python3
"""Validate structured SRX intent and render a deterministic Junos set candidate."""
from __future__ import annotations

import argparse
import hashlib
import ipaddress
import json
import re
import subprocess
import sys
from pathlib import Path
from typing import Any

DOMAINS = ("system", "interfaces", "vlans", "dhcp", "routing", "nat", "security")
GROUP = "ANSIBLE_SRX1500"


class IntentError(ValueError):
    pass


def load_yaml(path: Path) -> dict[str, Any]:
    result = subprocess.run(
        ["yq", "--output-format=json", ".", str(path)],
        text=True,
        capture_output=True,
        check=False,
    )
    if result.returncode:
        raise IntentError(f"{path}: yq failed: {result.stderr.strip()}")
    value = json.loads(result.stdout) if result.stdout.strip() else {}
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


def resolve(value: Any, topology: dict[str, Any], used: set[str]) -> Any:
    if isinstance(value, dict) and set(value) == {"topology"}:
        key = str(value["topology"])
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
    if re.fullmatch(r"[A-Za-z0-9_.*:/@+-]+", text):
        return text
    return json.dumps(text, ensure_ascii=True)


def cmd(*tokens: Any) -> str:
    return " ".join(q(token) for token in tokens if token is not None)


def unique(items: list[Any], key: str, label: str) -> None:
    values = [item[key] for item in items]
    repeated = sorted({v for v in values if values.count(v) > 1})
    if repeated:
        raise IntentError(f"duplicate {label}: {', '.join(map(str, repeated))}")


def render_system(data: dict[str, Any]) -> list[str]:
    system = data["system"]
    out = [
        cmd("system", "host-name", system["hostname"]),
        cmd("system", "time-zone", system["timezone"]),
    ]
    out += [cmd("system", "services", *row) for row in system.get("services", [])]
    out += [cmd("system", "name-server", address) for address in system.get("name_servers", [])]
    for server in system.get("ntp_servers", []):
        out.append(
            cmd(
                "system",
                "ntp",
                "server",
                server["address"],
                "prefer" if server.get("prefer") else None,
            )
        )
    out += [cmd("system", "syslog", *row) for row in system.get("syslog", [])]
    out += [cmd("system", *row) for row in system.get("options", [])]
    return out


def render_vlans(data: dict[str, Any]) -> list[str]:
    out: list[str] = []
    for vlan in sorted(data["vlans"], key=lambda x: x["id"]):
        base = ("vlans", vlan["name"])
        out.extend(
            [
                cmd(*base, "description", vlan["description"]),
                cmd(*base, "vlan-id", vlan["id"]),
                cmd(*base, "l3-interface", f"irb.{vlan['irb_unit']}"),
            ]
        )
    return out


def render_interfaces(data: dict[str, Any]) -> list[str]:
    out: list[str] = []
    for interface in sorted(data["interfaces"], key=lambda x: x["name"]):
        base = ("interfaces", interface["name"])
        if interface.get("description"):
            out.append(cmd(*base, "description", interface["description"]))
        if interface.get("mac"):
            out.append(cmd(*base, "mac", interface["mac"]))
        if interface.get("native_vlan"):
            out.append(cmd(*base, "native-vlan-id", interface["native_vlan"]))
        for unit in sorted(interface["units"], key=lambda x: x["unit"]):
            ub = (*base, "unit", unit["unit"], "family", unit["family"])
            if unit.get("dhcp"):
                out.append(cmd(*ub, "dhcp"))
                out.append(cmd(*ub, "dhcp", "retransmission-interval", 60))
                out.append(cmd(*ub, "dhcp", "force-discover"))
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
    for pool in sorted(data["dhcp"]["pools"], key=lambda x: x["name"]):
        base = (
            "access",
            "address-assignment",
            "pool",
            pool["name"],
            "family",
            "inet",
        )
        out.extend(
            [
                cmd(*base, "network", pool["network"]),
                cmd(*base, "range", "DYNAMIC", "low", pool["range"]["low"]),
                cmd(*base, "range", "DYNAMIC", "high", pool["range"]["high"]),
                cmd(*base, "dhcp-attributes", "router", pool["router"]),
            ]
        )
        out += [cmd(*base, "dhcp-attributes", "name-server", dns) for dns in pool.get("dns", [])]
        for reservation in sorted(pool.get("reservations", []), key=lambda x: x["name"]):
            rb = (*base, "host", reservation["name"])
            out.extend(
                [
                    cmd(*rb, "hardware-address", reservation["mac"]),
                    cmd(*rb, "ip-address", reservation["ip"]),
                ]
            )
    for group in data["dhcp"].get("groups", []):
        out.append(
            cmd(
                "system",
                "services",
                "dhcp-local-server",
                "group",
                group["name"],
                "interface",
                group["interface"],
            )
        )
    return out


def render_routing(data: dict[str, Any]) -> list[str]:
    routing = data["routing"]
    out: list[str] = []
    for instance in routing.get("instances", []):
        base = ("routing-instances", instance["name"])
        out.append(cmd(*base, "instance-type", instance["type"]))
        out += [cmd(*base, "interface", interface) for interface in instance.get("interfaces", [])]
    for policy in routing.get("policies", []):
        for term in policy["terms"]:
            base = ("policy-options", "policy-statement", policy["name"], "term", term["name"])
            if term.get("from_instance"):
                out.append(cmd(*base, "from", "instance", term["from_instance"]))
            if term.get("route_filter"):
                out.append(cmd(*base, "from", "route-filter", term["route_filter"], "exact"))
            out.append(cmd(*base, "then", term["action"]))
    out += [
        cmd("routing-options", "instance-import", policy)
        for policy in routing.get("instance_imports", [])
    ]
    out += [
        cmd("protocols", "rstp", "interface", interface)
        for interface in routing.get("rstp_interfaces", [])
    ]
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
            out.extend(
                [
                    cmd(*rb, "match", "source-address", rule["source"]),
                    cmd(*rb, "match", "destination-address", rule["destination"]),
                    cmd(*rb, "then", "source-nat", rule["action"]),
                ]
            )
    return out


def render_security(data: dict[str, Any]) -> list[str]:
    security = data["security"]
    out: list[str] = []
    for address in sorted(security.get("address_books", []), key=lambda x: x["name"]):
        out.append(cmd("security", "address-book", "global", "address", address["name"], address["value"]))
    for screen in security.get("screens", []):
        out += [
            cmd("security", "screen", "ids-option", screen["name"], *option)
            for option in screen["options"]
        ]
    for zone in security["zones"]:
        base = ("security", "zones", "security-zone", zone["name"])
        if zone.get("screen"):
            out.append(cmd(*base, "screen", zone["screen"]))
        out += [
            cmd(*base, "host-inbound-traffic", "system-services", service)
            for service in zone.get("services", [])
        ]
        out += [cmd(*base, "interfaces", interface) for interface in zone["interfaces"]]
    for policy in security["policies"]:
        base = (
            "security",
            "policies",
            "from-zone",
            policy["from"],
            "to-zone",
            policy["to"],
            "policy",
            policy["name"],
        )
        out += [cmd(*base, "match", "source-address", item) for item in policy["source"]]
        out += [cmd(*base, "match", "destination-address", item) for item in policy["destination"]]
        out += [cmd(*base, "match", "application", item) for item in policy["applications"]]
        out.append(cmd(*base, "then", policy["action"]))
    out.append(cmd("security", "policies", "default-policy", security["default_policy"]))
    return out


RENDERERS = {
    "system": render_system,
    "interfaces": render_interfaces,
    "vlans": render_vlans,
    "dhcp": render_dhcp,
    "routing": render_routing,
    "nat": render_nat,
    "security": render_security,
}


def validate(intent: dict[str, Any], topology: dict[str, Any], used: set[str]) -> None:
    vlans = intent["vlans"]["vlans"]
    unique(vlans, "name", "VLAN name")
    unique(vlans, "id", "VLAN ID")
    unique(vlans, "irb_unit", "IRB unit")
    vlan_names = {vlan["name"] for vlan in vlans}
    interfaces = intent["interfaces"]["interfaces"]
    unique(interfaces, "name", "interface")
    interface_units: set[str] = set()
    for interface in interfaces:
        units = interface["units"]
        unique(units, "unit", f"unit on {interface['name']}")
        for unit in units:
            interface_units.add(f"{interface['name']}.{unit['unit']}")
            missing = set(unit.get("vlans", [])) - vlan_names
            if missing:
                raise IntentError(
                    f"{interface['name']}: undefined VLANs: {sorted(missing)}"
                )
    pools = intent["dhcp"]["dhcp"]["pools"]
    unique(pools, "name", "DHCP pool")
    reservations: list[dict[str, Any]] = []
    for pool in pools:
        network = ipaddress.ip_network(pool["network"], strict=False)
        for reservation in pool.get("reservations", []):
            if ipaddress.ip_address(reservation["ip"]) not in network:
                raise IntentError(
                    f"reservation {reservation['name']} is outside {network}"
                )
            reservations.append(reservation)
    unique(reservations, "name", "reservation name")
    unique(reservations, "mac", "reservation MAC")
    unique(reservations, "ip", "reservation IP")
    zones = intent["security"]["security"]["zones"]
    unique(zones, "name", "zone")
    zone_names = {zone["name"] for zone in zones}
    for zone in zones:
        missing = set(zone["interfaces"]) - interface_units
        if missing:
            raise IntentError(
                f"zone {zone['name']}: undefined interfaces: {sorted(missing)}"
            )
    policies = intent["security"]["security"]["policies"]
    unique(policies, "name", "security policy")
    for policy in policies:
        if policy["from"] not in zone_names or policy["to"] not in zone_names:
            raise IntentError(f"policy {policy['name']}: undefined zone")
        if policy.get("action") not in {"permit", "deny", "reject"}:
            raise IntentError(f"policy {policy['name']}: terminal action required")
    instances = {
        instance["name"]
        for instance in intent["routing"]["routing"].get("instances", [])
    }
    for policy in intent["routing"]["routing"].get("policies", []):
        for term in policy["terms"]:
            if term.get("from_instance") and term["from_instance"] not in instances:
                raise IntentError(f"policy {policy['name']}: undefined instance")
    for ruleset in intent["nat"]["nat"].get("source_rules", []):
        sources = (
            ruleset["from_zone"]
            if isinstance(ruleset["from_zone"], list)
            else [ruleset["from_zone"]]
        )
        if set(sources + [ruleset["to_zone"]]) - zone_names:
            raise IntentError(f"NAT rule-set {ruleset['name']}: undefined zone")
    unused = leaves(topology) - used
    allowed_unused = {"management_address"}
    unexpected = sorted(unused - allowed_unused)
    if unexpected:
        raise IntentError(f"unused topology keys: {', '.join(unexpected)}")


def build(intent_dir: Path, topology_path: Path, group: str = GROUP) -> tuple[list[str], set[str]]:
    raw = {domain: load_yaml(intent_dir / f"{domain}.yml") for domain in DOMAINS}
    topology = load_yaml(topology_path)
    used: set[str] = set()
    intent = resolve(raw, topology, used)
    validate(intent, topology, used)
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
    parser.add_argument("--intent-dir", type=Path, required=True)
    parser.add_argument("--topology", type=Path, required=True)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--group", default=GROUP)
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    try:
        candidate, _ = build(args.intent_dir, args.topology, args.group)
    except (IntentError, KeyError, TypeError, ipaddress.AddressValueError) as error:
        print(f"intent validation failed: {error}", file=sys.stderr)
        return 2
    payload = "\n".join(candidate) + "\n"
    digest = hashlib.sha256(payload.encode()).hexdigest()
    if args.output:
        args.output.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        args.output.write_text(payload, encoding="utf-8")
        args.output.chmod(0o600)
    if not args.check:
        sys.stdout.write(payload)
    print(f"sha256:{digest}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
