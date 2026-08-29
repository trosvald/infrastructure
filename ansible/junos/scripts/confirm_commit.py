#!/usr/bin/env python3
"""Confirm the already-verified pending Junos commit through an exclusive configuration session."""

from __future__ import annotations

import os
import sys


def required(name: str) -> str:
    value = os.environ.get(name, "")
    if not value:
        raise RuntimeError(f"missing required runtime value: {name}")
    return value


def main() -> int:
    try:
        from jnpr.junos import Device
        from jnpr.junos.utils.config import Config

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
            configuration = Config(device)
            configuration.commit()
    except Exception as error:
        print(f"pending commit confirmation failed: {type(error).__name__}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
