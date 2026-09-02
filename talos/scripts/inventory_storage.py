#!/usr/bin/env python3
from __future__ import annotations

import json
import re
import subprocess

NODES = tuple((f"bsd-k8s-{index:02d}", f"10.25.11.{10 + index}") for index in range(1, 6))


def documents(text: str) -> list[dict]:
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


def candidate(hostname: str, address: str) -> dict:
    output = subprocess.check_output(
        ["talosctl", "--nodes", address, "get", "disks", "--output", "json"],
        text=True,
    )
    disks = [item.get("spec", {}) for item in documents(output)]
    candidates = [
        disk
        for disk in disks
        if disk.get("transport") == "nvme"
        and 900_000_000_000 <= int(disk.get("size", 0)) <= 1_100_000_000_000
    ]
    if len(candidates) != 1:
        raise SystemExit(f"{hostname}: expected exactly one approximately-1-TB NVMe OSD candidate, found {len(candidates)}")
    disk = candidates[0]
    for field in ("model", "serial", "wwid", "bus_path"):
        if not isinstance(disk.get(field), str) or not disk[field].strip():
            raise SystemExit(f"{hostname}: OSD candidate lacks stable {field}")
    if not re.fullmatch(r"(?:eui|naa|nvme)[.A-Za-z0-9_-]+", disk["wwid"]):
        raise SystemExit(f"{hostname}: OSD candidate WWID is not stable")
    if disk.get("transport") == "usb" or int(disk["size"]) < 900_000_000_000:
        raise SystemExit(f"{hostname}: protected system, LocalPV, or USB media selected as OSD")
    return disk


def main() -> None:
    seen: set[str] = set()
    print("HOSTNAME\tMODEL\tSERIAL\tWWID\tBUS_PATH\tSIZE_BYTES")
    for hostname, address in NODES:
        disk = candidate(hostname, address)
        identities = {disk["serial"], disk["wwid"], disk["bus_path"]}
        if seen & identities:
            raise SystemExit(f"{hostname}: OSD identity duplicates another node")
        seen |= identities
        print(
            "\t".join(
                (
                    hostname,
                    disk["model"],
                    disk["serial"],
                    disk["wwid"],
                    disk["bus_path"],
                    str(disk["size"]),
                )
            )
        )


if __name__ == "__main__":
    main()
