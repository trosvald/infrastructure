#!/usr/bin/env python3
"""Stream committed configuration from PyEZ into age without plaintext files."""
from __future__ import annotations

import os
import subprocess
import sys
from typing import Any

from jnpr.junos import Device


def required(name: str) -> str:
    value = os.environ.get(name, "")
    if not value:
        raise RuntimeError(f"missing runtime value: {name}")
    return value


def configuration_text(reply: Any) -> str:
    for node in reply.iter():
        if str(node.tag).rsplit("}", 1)[-1] == "configuration-text" and node.text:
            return node.text
    raise RuntimeError("Junos did not return text configuration")


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
            if "23.4R2" not in str(facts.get("version", "")):
                raise RuntimeError("Junos release is outside the reviewed train")
            reply = device.rpc.get_config(options={"database": "committed", "format": "text"})
            plaintext = configuration_text(reply)

        subprocess.run(
            [
                "age",
                "--encrypt",
                "--recipient",
                required("JUNOS_BACKUP_AGE_RECIPIENT"),
                "--output",
                required("JUNOS_BACKUP_OUTPUT"),
            ],
            input=(plaintext.rstrip("\n") + "\n").encode(),
            check=True,
        )
        del plaintext
    except Exception:
        print("Backup failed; no plaintext backup was retained.", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
