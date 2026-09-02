#!/usr/bin/env python3
"""Build the protected live Talos topology from captured hardware inventory."""

from __future__ import annotations

import argparse
import importlib.util
import ipaddress
import json
from pathlib import Path
import re
import subprocess
from typing import Any


class TopologyError(ValueError):
    pass


def load_documents(path: Path) -> list[dict[str, Any]]:
    result = subprocess.run(
        ["yq", "eval-all", "-o=json", "-I=0", "[.]", str(path)],
        check=False,
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        raise TopologyError(f"cannot parse protected inventory {path.name}")
    try:
        documents = json.loads(result.stdout)
    except json.JSONDecodeError as error:
        raise TopologyError(f"invalid protected inventory {path.name}") from error
    if not isinstance(documents, list) or any(not isinstance(item, dict) for item in documents):
        raise TopologyError(f"protected inventory {path.name} must contain objects")
    return documents


def one(items: list[dict[str, Any]], label: str) -> dict[str, Any]:
    if len(items) != 1:
        raise TopologyError(f"expected exactly one {label}, found {len(items)}")
    return items[0]


def disk_identity(spec: dict[str, Any], fields: tuple[str, ...], label: str) -> dict[str, Any]:
    missing = [field for field in fields if spec.get(field) in (None, "")]
    if missing:
        raise TopologyError(f"{label} lacks exact identity fields: {', '.join(missing)}")
    return {field: spec[field] for field in fields}


def cel_string(value: Any) -> str:
    return json.dumps(str(value), ensure_ascii=True)


def stable_sata_bus_prefix(value: Any, label: str) -> str:
    bus_path = str(value)
    prefix, marker, _ = bus_path.partition("/host")
    if marker != "/host" or "/ata" not in prefix or not prefix.startswith("/pci"):
        raise TopologyError(f"{label} lacks a stable PCI/ATA bus prefix")
    return prefix + "/"



def build_node(inventory_dir: Path, index: int) -> dict[str, Any]:
    suffix = 10 + index
    disks = [document.get("spec", {}) for document in load_documents(inventory_dir / f"disks-{suffix}.yaml")]
    links = load_documents(inventory_dir / f"network-{suffix}.yaml")

    install = one(
        [disk for disk in disks if disk.get("transport") == "sata" and 450_000_000_000 <= disk.get("size", 0) <= 550_000_000_000],
        f"node {index} Talos system disk",
    )
    localpv = one(
        [disk for disk in disks if disk.get("transport") == "nvme" and 450_000_000_000 <= disk.get("size", 0) <= 550_000_000_000],
        f"node {index} LocalPV disk",
    )
    osd = one(
        [disk for disk in disks if disk.get("transport") == "nvme" and 900_000_000_000 <= disk.get("size", 0) <= 1_100_000_000_000],
        f"node {index} future OSD",
    )

    link_specs = [(document.get("metadata", {}).get("id"), document.get("spec", {})) for document in links]
    bootstrap_name, bootstrap = one(
        [{"name": name, "spec": spec} for name, spec in link_specs if spec.get("driver") == "e1000e"],
        f"node {index} bootstrap link",
    ).values()
    x710 = [
        {"name": name, "spec": spec}
        for name, spec in link_specs
        if spec.get("driver") == "i40e" and spec.get("pciID") == "8086:1572"
    ]
    tor1 = one([link for link in x710 if str(link["spec"].get("busPath", "")).endswith(".0")], f"node {index} tor1 X710 link")
    tor2 = one([link for link in x710 if str(link["spec"].get("busPath", "")).endswith(".1")], f"node {index} tor2 X710 link")
    if not bootstrap.get("permanentAddr"):
        raise TopologyError(f"node {index} bootstrap link lacks a permanent address")

    local_identity = disk_identity(
        localpv,
        ("size", "model", "serial", "wwid", "bus_path"),
        f"node {index} LocalPV disk",
    )
    local_match = " && ".join(
        (
            f'disk.size == {local_identity["size"]}u',
            f'disk.model == {cel_string(local_identity["model"])}',
            f'disk.serial == {cel_string(local_identity["serial"])}',
            f'disk.wwid == {cel_string(local_identity["wwid"])}',
            f'disk.bus_path == {cel_string(local_identity["bus_path"])}',
        )
    )

    return {
        "hostname": f"bsd-k8s-{index:02d}",
        "role": "controlplane" if index <= 3 else "worker",
        "address": f"10.25.11.{10 + index}",
        "bootstrap_address": f"10.25.10.{110 + index}",
        "storage_address": f"10.25.14.{10 + index}",
        "bootstrap_link": bootstrap_name,
        "links": {
            "tor1": {
                "permanent_mac": tor1["spec"].get("permanentAddr"),
                "switch": "tor1",
                "port": str(index),
                "native_vlan": 2511,
            },
            "tor2": {
                "permanent_mac": tor2["spec"].get("permanentAddr"),
                "switch": "tor2",
                "port": str(index),
                "native_vlan": 2511,
            },
        },
        "install_disk": {
            "model": install.get("model"),
            "size_bytes": install.get("size"),
            "wwid": install.get("wwid"),
            "bus_path_prefix": stable_sata_bus_prefix(
                install.get("bus_path"), f"node {index} Talos system disk"
            ),
        },
        "localpv_disk": {"match": local_match},
        "future_osd": {
            "model": osd.get("model"),
            "serial": osd.get("serial"),
            "wwid": osd.get("wwid"),
            "bus_path": osd.get("bus_path"),
            "size_bytes": osd.get("size"),
        },
        "labels": {
            "region": "id-banten",
            "zone": "bsd-home-01",
            "site": "bsd",
            "power_domain": "ups-01",
            "network_domain": "srx1500-01",
        },
    }


def load_decisions(path: Path) -> dict[str, Any]:
    try:
        decisions = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise TopologyError("protected provisioning decisions must be valid JSON") from error
    if not isinstance(decisions, dict) or set(decisions) != {"approved_admin_sources", "snapshot_age_recipient"}:
        raise TopologyError("protected decisions must contain exactly administrator sources and snapshot recipient")
    sources = decisions["approved_admin_sources"]
    if not isinstance(sources, list) or not sources:
        raise TopologyError("approved administrator sources must be a nonempty list")
    for source in sources:
        ipaddress.ip_network(str(source), strict=True)
    recipient = decisions["snapshot_age_recipient"]
    if not isinstance(recipient, str) or not re.fullmatch(r"age1[0-9a-z]{20,}", recipient):
        raise TopologyError("snapshot recipient must be one age public recipient")
    return decisions


def validate_topology(
    topology: dict[str, Any], render_script: Path, secrets: dict[str, Any] | None = None
) -> None:
    spec = importlib.util.spec_from_file_location("talos_render", render_script)
    if spec is None or spec.loader is None:
        raise TopologyError("cannot load Talos topology validator")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    if secrets is None:
        secrets = {
            "cluster": {"id": "placeholder", "secret": "placeholder"},
            "secrets": {
                "bootstraptoken": "placeholder",
                "secretboxencryptionsecret": "placeholder",
            },
            "trustdinfo": {"token": "placeholder"},
            "certs": {
                "etcd": {"crt": "placeholder", "key": "placeholder"},
                "k8s": {"crt": "placeholder", "key": "placeholder"},
                "k8saggregator": {"crt": "placeholder", "key": "placeholder"},
                "k8sserviceaccount": {"key": "placeholder"},
                "os": {"crt": "placeholder", "key": "placeholder"},
            },
        }
    module.validate_context({"topology": topology, "secrets": secrets}, allow_synthetic=False)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--inventory-dir", required=True, type=Path)
    parser.add_argument("--decisions", required=True, type=Path)
    parser.add_argument("--validator", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--secrets", type=Path)
    args = parser.parse_args()

    decisions = load_decisions(args.decisions)
    network_suffixes = {
        int(match.group(1))
        for path in args.inventory_dir.glob("network-*.yaml")
        if (match := re.fullmatch(r"network-([0-9]+)[.]yaml", path.name))
    }
    disk_suffixes = {
        int(match.group(1))
        for path in args.inventory_dir.glob("disks-*.yaml")
        if (match := re.fullmatch(r"disks-([0-9]+)[.]yaml", path.name))
    }
    if not network_suffixes or network_suffixes != disk_suffixes:
        raise TopologyError("protected network and disk inventories must cover the same nodes")
    indexes = [suffix - 10 for suffix in sorted(network_suffixes)]
    if indexes != list(range(1, len(indexes) + 1)):
        raise TopologyError("protected inventory node suffixes must be contiguous from 11")
    nodes = [build_node(args.inventory_dir, index) for index in indexes]
    api_sans = [
        "k8s.monosense.io",
        "10.25.20.10",
        *(node["address"] for node in nodes if node["role"] == "controlplane"),
    ]
    topology = {
        "cluster": {
            "name": "bsd-k8s",
            "endpoint": "https://k8s.monosense.io:6443",
            "api_sans": api_sans,
            "snapshot_age_recipient": decisions["snapshot_age_recipient"],
        },
        "network": {"subnet": "10.25.11.0/24", "gateway": "10.25.11.1"},
        "management_network": {"subnet": "10.25.10.0/24", "gateway": "10.25.10.1"},
        "storage_network": {"subnet": "10.25.14.0/24", "vlan_id": 2514, "mtu": 1496},
        "versions": {
            "schematic": "bd0e9976660939539a20d0c88516154f1cd97d95c2bed48b26314e830023f1b3",
            "talos": "v1.14.0-rc.2",
            "kubernetes": "v1.36.2",
        },
        "approved_admin_sources": decisions["approved_admin_sources"],
        "nodes": nodes,
        "private_dns": ["10.25.13.35", "10.25.10.100"],
        "ntp_servers": ["time.cloudflare.com", "time.google.com", "0.id.pool.ntp.org"],
    }
    secrets = None
    if args.secrets is not None:
        try:
            secrets = json.loads(args.secrets.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError) as error:
            raise TopologyError("Talos secret bundle must be valid JSON") from error
    validate_topology(topology, args.validator, secrets)
    args.output.write_text(json.dumps(topology, separators=(",", ":")) + "\n", encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
