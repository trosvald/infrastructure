#!/usr/bin/env python3
from __future__ import annotations

import csv
import json
import pathlib
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parents[2]
SWITCH_INVENTORY = ROOT / ".private/storage-network-switch-ports.tsv"
NODES = tuple((f"bsd-k8s-{index:02d}", f"10.25.11.{10 + index}", f"10.25.14.{10 + index}") for index in range(1, 6))


def json_documents(text: str) -> list[dict]:
    decoder = json.JSONDecoder()
    offset = 0
    result: list[dict] = []
    while offset < len(text):
        while offset < len(text) and text[offset].isspace():
            offset += 1
        if offset == len(text):
            break
        item, offset = decoder.raw_decode(text, offset)
        if isinstance(item, dict):
            result.append(item)
    return result


def validate_switch_inventory() -> None:
    if not SWITCH_INVENTORY.is_file() or SWITCH_INVENTORY.is_symlink():
        raise SystemExit(f"reviewed switch-port inventory is unavailable: {SWITCH_INVENTORY}")
    with SWITCH_INVENTORY.open(newline="") as stream:
        rows = list(csv.DictReader(stream, delimiter="\t"))
    expected = {hostname for hostname, _, _ in NODES}
    if set(row.get("hostname", "") for row in rows) != expected:
        raise SystemExit("switch-port inventory must cover exactly the five Talos nodes")
    for hostname in expected:
        node_rows = [row for row in rows if row["hostname"] == hostname]
        if len(node_rows) != 2 or any(row.get("vlan_id") != "2514" for row in node_rows):
            raise SystemExit(f"{hostname}: switch inventory must contain two reviewed VLAN 2514 trunks")
        if len({(row.get("switch"), row.get("port")) for row in node_rows}) != 2:
            raise SystemExit(f"{hostname}: switch-port entries are duplicated")


def validate_addresses() -> None:
    for hostname, management, storage in NODES:
        output = subprocess.check_output(
            ["talosctl", "--nodes", management, "get", "addresses", "--output", "json"],
            text=True,
        )
        records = json_documents(output)
        matched = [
            item
            for item in records
            if item.get("metadata", {}).get("id") == "bond0.2514"
            and storage + "/24" in json.dumps(item.get("spec", {}), separators=(",", ":"))
        ]
        if len(matched) != 1:
            raise SystemExit(f"{hostname}: bond0.2514 does not carry exactly {storage}/24")


def cilium_pods() -> dict[str, str]:
    output = subprocess.check_output(
        ["kubectl", "-n", "kube-system", "get", "pods", "-l", "k8s-app=cilium", "-o", "json"],
        text=True,
    )
    items = json.loads(output).get("items", [])
    mapping = {
        item.get("spec", {}).get("nodeName", ""): item.get("metadata", {}).get("name", "")
        for item in items
        if item.get("status", {}).get("phase") == "Running"
    }
    if set(mapping) != {hostname for hostname, _, _ in NODES}:
        raise SystemExit("one Running Cilium agent per reviewed node is required")
    return mapping


def validate_reachability() -> None:
    pods = cilium_pods()
    for source, _, source_address in NODES:
        for target, _, target_address in NODES:
            if source == target:
                continue
            result = subprocess.run(
                [
                    "kubectl", "-n", "kube-system", "exec", pods[source], "--",
                    "ping", "-c", "2", "-W", "2", target_address,
                ],
                check=False,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )
            if result.returncode != 0:
                rollback = ROOT / ".private/talos-pre-storage" / f"{source}.yaml"
                raise SystemExit(
                    f"storage VLAN hop failed: {source} ({source_address}) -> {target} ({target_address}); "
                    f"restore the affected node from {rollback}"
                )


def main() -> None:
    if sys.argv[1:] not in ([], ["--inventory-only"]):
        raise SystemExit("usage: validate_storage_network.py [--inventory-only]")
    validate_switch_inventory()
    if sys.argv[1:] == ["--inventory-only"]:
        print("reviewed five-node VLAN 2514 switch-port inventory accepted")
        return
    validate_addresses()
    validate_reachability()
    print("five-node tagged storage L2 reachability passed on bond0.2514")


if __name__ == "__main__":
    main()
