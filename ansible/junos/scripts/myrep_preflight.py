#!/usr/bin/env python3
"""Prove the protected MYREP address is global and stable through direct TLS."""

from __future__ import annotations

import ipaddress
import json
import os
import ssl
import sys
import time
import urllib.request
from pathlib import Path

TRACE_URL = "https://1.1.1.1/cdn-cgi/trace"


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

        print(json.dumps({"address": str(expected)}, separators=(",", ":")))
    except Exception as error:
        print(f"MYREP preflight failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
