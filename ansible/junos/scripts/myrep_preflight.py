#!/usr/bin/env python3
"""Prove the protected MYREP address is global, stable, and active on the SRX."""

from __future__ import annotations

import ipaddress
import json
import os
import re
import ssl
import sys
import time
import urllib.request
from pathlib import Path

TRACE_URL = "https://1.1.1.1/cdn-cgi/trace"
INTERFACE_COMMAND = "show interfaces terse ge-0/0/1.0 | no-more"


def required(name: str) -> str:
    value = os.environ.get(name, "")
    if not value:
        raise RuntimeError(f"missing required runtime value: {name}")
    return value


def expected_address(topology_path: str) -> ipaddress.IPv4Address:
    topology = json.loads(Path(topology_path).read_text(encoding="utf-8"))
    network = ipaddress.ip_network(topology["wan"]["secondary_public_cidr"], strict=False)
    if not isinstance(network, ipaddress.IPv4Network) or network.prefixlen != 32:
        raise RuntimeError("wan.secondary_public_cidr must be an exact IPv4 /32")
    address = network.network_address
    if not address.is_global or address in ipaddress.ip_network("100.64.0.0/10"):
        raise RuntimeError("wan.secondary_public_cidr must be globally routable and non-CGNAT")
    return address


def observed_egress() -> ipaddress.IPv4Address:
    opener = urllib.request.build_opener(
        urllib.request.ProxyHandler({}),
        urllib.request.HTTPSHandler(context=ssl.create_default_context()),
    )
    request = urllib.request.Request(
        TRACE_URL,
        headers={"User-Agent": "monosense-myrep-preflight/1"},
    )
    with opener.open(request, timeout=10) as response:
        fields = dict(
            line.split("=", 1)
            for line in response.read(4096).decode("ascii").splitlines()
            if "=" in line
        )
    address = ipaddress.ip_address(fields.get("ip", ""))
    if not isinstance(address, ipaddress.IPv4Address):
        raise RuntimeError("external observer did not return IPv4")
    return address


def interface_addresses(output: str) -> set[ipaddress.IPv4Address]:
    addresses: set[ipaddress.IPv4Address] = set()
    pattern = r"(?<![0-9.])(?:[0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}(?![0-9.])"
    for value in re.findall(pattern, output):
        try:
            addresses.add(ipaddress.ip_interface(value).ip)
        except ValueError:
            continue
    return addresses


def main() -> int:
    try:
        expected = expected_address(required("JUNOS_TOPOLOGY_FILE"))
        first = observed_egress()
        time.sleep(2)
        second = observed_egress()
        if first != expected or second != expected:
            raise RuntimeError(
                "observed MYREP egress does not match protected secondary_public_cidr"
            )

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
            output = device.cli(INTERFACE_COMMAND, warning=False)
        if not isinstance(output, str) or expected not in interface_addresses(output):
            raise RuntimeError(
                "protected MYREP address is not directly assigned to ge-0/0/1.0"
            )
        print(f"myrep_preflight=ok address={expected}")
    except Exception as error:
        print(f"MYREP preflight failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
