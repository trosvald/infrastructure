#!/usr/bin/env python3
from __future__ import annotations

import importlib.util
import json
from pathlib import Path
from tempfile import TemporaryDirectory
from unittest import mock

root = Path(__file__).resolve().parents[2]
builder_path = root / "talos/scripts/build_topology.py"
spec = importlib.util.spec_from_file_location("build_topology", builder_path)
assert spec is not None and spec.loader is not None
builder = importlib.util.module_from_spec(spec)
spec.loader.exec_module(builder)


def disk(size: int, transport: str, name: str) -> dict[str, object]:
    return {
        "spec": {
            "size": size,
            "transport": transport,
            "model": f"model-{name}",
            "serial": f"serial-{name}",
            "wwid": f"wwid-{name}",
            "bus_path": f"/bus/{name}",
        }
    }


def network(name: str, driver: str, address: str, bus: str = "") -> dict[str, object]:
    return {
        "metadata": {"id": name},
        "spec": {
            "driver": driver,
            "pciID": "8086:1572" if driver == "i40e" else "8086:15BB",
            "permanentAddr": address,
            "busPath": bus,
        },
    }


def inventory(path: Path) -> list[dict[str, object]]:
    if path.name.startswith("disks-"):
        system = disk(500_107_862_016, "sata", "system")
        system["spec"]["bus_path"] = "/pci0000:00/0000:00:17.0/ata1/host1/target1:0:0"
        return [
            system,
            disk(512_110_190_592, "nvme", "localpv"),
            disk(1_000_204_886_016, "nvme", "osd"),
        ]
    return [
        network("eno1", "e1000e", "02:00:00:00:00:01"),
        network("x710-f0", "i40e", "02:00:00:00:00:02", "0000:01:00.0"),
        network("x710-f1", "i40e", "02:00:00:00:00:03", "0000:01:00.1"),
    ]


with mock.patch.object(builder, "load_documents", side_effect=inventory):
    node = builder.build_node(Path("inventory"), 1)
assert node["bootstrap_link"] == "eno1"
assert node["links"]["tor1"]["permanent_mac"] == "02:00:00:00:00:02"
assert node["links"]["tor2"]["permanent_mac"] == "02:00:00:00:00:03"
assert node["install_disk"]["wwid"] == "wwid-system"
assert node["install_disk"]["bus_path_prefix"] == "/pci0000:00/0000:00:17.0/ata1/"
assert "disk.size == 512110190592u" in node["localpv_disk"]["match"]
assert 'disk.wwid == "wwid-localpv"' in node["localpv_disk"]["match"]
assert node["future_osd"]["wwid"] == "wwid-osd"

with TemporaryDirectory() as directory:
    decisions = Path(directory) / "decisions.json"
    decisions.write_text(
        json.dumps(
            {
                "approved_admin_sources": ["10.25.10.0/24"],
                "snapshot_age_recipient": "age1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq",
            }
        ),
        encoding="utf-8",
    )
    assert builder.load_decisions(decisions)["approved_admin_sources"] == ["10.25.10.0/24"]

provision = (root / "scripts/provision-talos-records.sh").read_text(encoding="utf-8")
justfile = (root / ".justfile").read_text(encoding="utf-8")
assert "-cas=0" in provision
assert "talosctl gen secrets --talos-version v1.14.0-rc.2" in provision
assert "openssl rand 32" in provision
assert '"@$secrets"' in provision and '"@$bgp"' in provision and '"@$topology"' in provision
assert "existing Talos topology differs; overwrite requires a separate reviewed change" in provision
assert "password=" not in provision
assert "rm -rf \"$runtime_dir\"" in provision
assert "provision-talos-records:" in justfile
print("Talos record provisioner derives exact hardware identity and fails closed on overwrite")
