#!/usr/bin/env python3
"""Validate the installed Junos controller runtime and XML parser."""
from __future__ import annotations

from importlib import import_module
from importlib.metadata import version


EXPECTED_DISTRIBUTIONS = {
    "junos-eznc": "2.8.2",
    "ncclient": "0.7.0",
    "jxmlease": "1.0.3",
    "PyYAML": "6.0.3",
    "xmltodict": "1.0.4",
    "JSNAPy": "1.3.8",
    "packaging": "26.3",
}


def main() -> int:
    for distribution, expected in EXPECTED_DISTRIBUTIONS.items():
        installed = version(distribution)
        if installed != expected:
            raise RuntimeError(
                f"{distribution} version mismatch: expected {expected}, found {installed}"
            )

    pyez = import_module("jnpr.junos")
    import_module("jnpr.jsnapy")
    import_module("ncclient")
    ncclient_xml = import_module("ncclient.xml_")
    jxmlease = import_module("jxmlease")
    import_module("yaml")
    import_module("xmltodict")
    import_module("packaging")
    parsed = jxmlease.parse(
        "<rpc-reply><system><host-name>fixture</host-name></system></rpc-reply>"
    )
    if str(parsed["rpc-reply"]["system"]["host-name"]) != "fixture":
        raise RuntimeError("jxmlease regression fixture parsed incorrectly")

    rpc = ncclient_xml.to_ele(
        '<get-system-information xmlns="urn:ietf:params:xml:ns:netconf:base:1.0"/>'
    )
    if str(rpc.tag).rsplit("}", 1)[-1] != "get-system-information":
        raise RuntimeError("ncclient NETCONF XML fixture parsed incorrectly")

    device = pyez.Device(host="192.0.2.1", user="fixture", gather_facts=False)
    if device.hostname != "192.0.2.1":
        raise RuntimeError("PyEZ controller fixture initialized incorrectly")
    print("controller runtime imports and XML parsing passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
