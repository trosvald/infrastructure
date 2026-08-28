#!/usr/bin/env python3
"""Validate protected Talos inventory and render one private machine configuration."""

from __future__ import annotations

import argparse
import hashlib
import ipaddress
import json
import os
from pathlib import Path
import re
import subprocess
from typing import Any


class RenderError(ValueError):
    pass


def require_exact_keys(value: dict[str, Any], expected: set[str], label: str) -> None:
    if set(value) != expected:
        raise RenderError(f"{label} keys must be exactly {sorted(expected)}")


def validate_context(context: dict[str, Any], allow_synthetic: bool) -> dict[str, Any]:
    require_exact_keys(context, {"topology", "secrets"}, "context")
    topology = context["topology"]
    secrets = context["secrets"]
    if not isinstance(topology, dict) or not isinstance(secrets, dict):
        raise RenderError("topology and secrets must be objects")

    expected_topology_keys = {
        "cluster",
        "network",
        "versions",
        "approved_admin_sources",
        "nodes",
        "private_dns",
        "ntp_servers",
    }
    synthetic = topology.get("synthetic") is True
    if synthetic:
        expected_topology_keys.add("synthetic")
    require_exact_keys(topology, expected_topology_keys, "topology")
    if synthetic and not allow_synthetic:
        raise RenderError("synthetic topology is accepted only by offline tests")
    if not synthetic and allow_synthetic:
        raise RenderError("offline fixture must declare synthetic: true")

    cluster = topology["cluster"]
    network = topology["network"]
    versions = topology["versions"]
    require_exact_keys(
        cluster,
        {"name", "endpoint", "api_sans", "snapshot_age_recipient"},
        "cluster",
    )
    require_exact_keys(network, {"subnet", "gateway"}, "network")
    require_exact_keys(versions, {"schematic", "talos", "kubernetes"}, "versions")
    if (
        versions["schematic"]
        != "bd0e9976660939539a20d0c88516154f1cd97d95c2bed48b26314e830023f1b3"
    ):
        raise RenderError("schematic must be the reviewed Talos 1.14 factory ID")
    if versions["talos"] != "v1.14.0-rc.2":
        raise RenderError("Talos version must be exactly v1.14.0-rc.2")
    if versions["kubernetes"] != "v1.36.2":
        raise RenderError("Kubernetes version must be exactly v1.36.2")
    if not re.fullmatch(r"age1[0-9a-z]{20,}", str(cluster["snapshot_age_recipient"])):
        raise RenderError("snapshot age recipient is invalid")
    private_dns = topology["private_dns"]
    if not isinstance(private_dns, list) or len(private_dns) != 2:
        raise RenderError("private_dns must contain exactly two approved addresses")
    for value in private_dns:
        ipaddress.ip_address(str(value))
    ntp_servers = topology["ntp_servers"]
    if (
        not isinstance(ntp_servers, list)
        or len(ntp_servers) != 3
        or any(
            not re.fullmatch(r"[A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?", str(value))
            for value in ntp_servers
        )
    ):
        raise RenderError("ntp_servers must contain exactly three valid hostnames")

    live_sans = [
        "k8s.monosense.io",
        "10.25.20.10",
        "10.25.11.11",
        "10.25.11.12",
        "10.25.11.13",
    ]
    if not synthetic:
        if cluster["name"] != "bsd-k8s":
            raise RenderError("live cluster name must be bsd-k8s")
        if (
            cluster["snapshot_age_recipient"]
            != "age14a89rfvvdrf62v0xe8hlp6hdvgwfnxcku9sjrxc2f47ujkqf5qqqz0c7wk"
        ):
            raise RenderError("live snapshot recipient differs from reviewed recovery custody")
        if cluster["endpoint"] != "https://k8s.monosense.io:6443":
            raise RenderError("live control-plane endpoint must be https://k8s.monosense.io:6443")
        if cluster["api_sans"] != live_sans:
            raise RenderError("live API SANs differ from the approved hostname, VIP, and nodes")
        if network != {"subnet": "10.25.11.0/24", "gateway": "10.25.11.1"}:
            raise RenderError("live Talos network must be VLAN 2511 at 10.25.11.0/24")
        if topology["private_dns"] != ["10.25.13.35", "10.25.10.100"]:
            raise RenderError("live private DNS must be Blocky then AdGuard")
        if topology["ntp_servers"] != [
            "time.cloudflare.com",
            "time.google.com",
            "0.id.pool.ntp.org",
        ]:
            raise RenderError("live NTP servers differ from the approved three providers")
    subnet = ipaddress.ip_network(str(network["subnet"]), strict=True)
    gateway = ipaddress.ip_address(str(network["gateway"]))
    if gateway not in subnet:
        raise RenderError("network gateway is outside the node subnet")

    expected_hosts = [f"bsd-k8s-{index:02d}" for index in range(1, 6)]
    nodes = topology["nodes"]
    if not isinstance(nodes, list) or [node.get("hostname") for node in nodes] != expected_hosts:
        raise RenderError("topology must contain exactly bsd-k8s-01 through bsd-k8s-05 in order")
    expected_roles = ["controlplane", "controlplane", "controlplane", "worker", "worker"]
    expected_live_addresses = [f"10.25.11.{index}" for index in range(11, 16)]
    expected_bootstrap_addresses = [
        str(ipaddress.ip_address(int(subnet.network_address) + 101 + index))
        if synthetic
        else f"10.25.11.{101 + index}"
        for index in range(5)
    ]
    seen_macs: set[str] = set()
    seen_bootstrap_addresses: set[ipaddress._BaseAddress] = set()
    seen_disk_ids: set[str] = set()
    for index, (node, role) in enumerate(zip(nodes, expected_roles, strict=True)):
        require_exact_keys(
            node,
            {
                "hostname",
                "role",
                "address",
                "bootstrap_address",
                "bootstrap_link",
                "links",
                "install_disk",
                "localpv_disk",
                "future_osd",
                "labels",
            },
            f"node {node.get('hostname', index)}",
        )
        if node["role"] != role:
            raise RenderError(f"{node['hostname']}: role must be {role}")
        address = ipaddress.ip_address(str(node["address"]))
        if address not in subnet or address in {gateway, subnet.network_address, subnet.broadcast_address}:
            raise RenderError(f"{node['hostname']}: invalid VLAN 2511 address")
        if not synthetic and str(address) != expected_live_addresses[index]:
            raise RenderError(f"{node['hostname']}: live address is not approved")
        bootstrap_address = ipaddress.ip_address(str(node["bootstrap_address"]))
        if (
            bootstrap_address not in subnet
            or str(bootstrap_address) != expected_bootstrap_addresses[index]
            or bootstrap_address in {
                address,
                gateway,
                subnet.network_address,
                subnet.broadcast_address,
            }
            or bootstrap_address in seen_bootstrap_addresses
            or not str(node["bootstrap_link"])
        ):
            raise RenderError(f"{node['hostname']}: bootstrap path is invalid or duplicated")
        seen_bootstrap_addresses.add(bootstrap_address)
        require_exact_keys(node["links"], {"tor1", "tor2"}, f"{node['hostname']} links")
        for link_name in ("tor1", "tor2"):
            link = node["links"][link_name]
            require_exact_keys(
                link,
                {"permanent_mac", "switch", "port", "native_vlan"},
                f"{node['hostname']} {link_name}",
            )
            mac = str(link["permanent_mac"]).lower()
            if not re.fullmatch(r"[0-9a-f]{2}(?::[0-9a-f]{2}){5}", mac) or mac in seen_macs:
                raise RenderError(f"{node['hostname']}: permanent MAC is invalid or duplicated")
            seen_macs.add(mac)
            if (
                not str(link["switch"])
                or not str(link["port"])
                or link["native_vlan"] != 2511
            ):
                raise RenderError(f"{node['hostname']}: ToR link must declare native VLAN 2511")
        if not synthetic and (
            node["bootstrap_link"] != "eno1"
            or node["links"]["tor1"]["switch"] != "tor1"
            or node["links"]["tor2"]["switch"] != "tor2"
            or node["links"]["tor1"]["port"] != str(index + 1)
            or node["links"]["tor2"]["port"] != str(index + 1)
        ):
            raise RenderError(f"{node['hostname']}: live bootstrap or ToR port mapping differs")
        if node["links"]["tor1"]["switch"] == node["links"]["tor2"]["switch"]:
            raise RenderError(f"{node['hostname']}: bond members must terminate on different ToRs")
        install_disk = node["install_disk"]
        require_exact_keys(
            install_disk,
            {"model", "size_bytes", "wwid", "bus_path"},
            f"{node['hostname']} install disk",
        )
        require_exact_keys(node["localpv_disk"], {"match"}, f"{node['hostname']} LocalPV disk")
        future_osd = node["future_osd"]
        require_exact_keys(
            future_osd,
            {"model", "serial", "wwid", "bus_path", "size_bytes"},
            f"{node['hostname']} future OSD",
        )
        install_size = install_disk["size_bytes"]
        if (
            not isinstance(install_size, int)
            or not 450_000_000_000 <= install_size <= 550_000_000_000
            or any(not str(install_disk[field]) for field in ("model", "wwid", "bus_path"))
        ):
            raise RenderError(f"{node['hostname']}: system disk selector must bind exact 500GB identity")
        local_match = str(node["localpv_disk"]["match"])
        for required in (
            "disk.size ==",
            "disk.model ==",
            "disk.serial ==",
            "disk.wwid ==",
            "disk.bus_path ==",
        ):
            if required not in local_match:
                raise RenderError(
                    f"{node['hostname']}: LocalPV selector lacks exact size/model/serial/WWID/bus identity"
                )
        osd_size = future_osd["size_bytes"]
        if (
            not isinstance(osd_size, int)
            or not 900_000_000_000 <= osd_size <= 1_100_000_000_000
            or any(
                not str(future_osd[field])
                for field in ("model", "serial", "wwid", "bus_path")
            )
        ):
            raise RenderError(f"{node['hostname']}: future OSD identity is not an exact 1TB device")
        identities = {
            str(install_disk["wwid"]),
            local_match,
            str(future_osd["wwid"]),
        }
        if (
            any(not identity for identity in identities)
            or seen_disk_ids & identities
            or str(future_osd["wwid"]) in local_match
        ):
            raise RenderError(f"{node['hostname']}: disk identities are empty, duplicated, or overlap")
        seen_disk_ids |= identities
        require_exact_keys(
            node["labels"],
            {"region", "zone", "site", "power_domain", "network_domain"},
            f"{node['hostname']} labels",
        )
        if any(not str(value) for value in node["labels"].values()):
            raise RenderError(f"{node['hostname']}: topology labels must be nonempty")
        if not synthetic and node["labels"] != {
            "region": "id-banten",
            "zone": "bsd-home-01",
            "site": "bsd",
            "power_domain": "ups-01",
            "network_domain": "srx1500-01",
        }:
            raise RenderError(f"{node['hostname']}: labels differ from the approved baseline")

    admin_sources = topology["approved_admin_sources"]
    if not isinstance(admin_sources, list) or not admin_sources:
        raise RenderError("approved Talos administrator source list must be nonempty")
    for source in admin_sources:
        ipaddress.ip_network(str(source), strict=True)
    if not synthetic and admin_sources != ["10.25.10.0/24"]:
        raise RenderError("live Talos administrator sources differ from the reviewed MGMT subnet")

    require_exact_keys(secrets, {"cluster", "secrets", "trustdinfo", "certs"}, "secrets")
    require_exact_keys(secrets["cluster"], {"id", "secret"}, "secrets.cluster")
    require_exact_keys(
        secrets["secrets"], {"bootstraptoken", "secretboxencryptionsecret"}, "secrets.secrets"
    )
    require_exact_keys(secrets["trustdinfo"], {"token"}, "secrets.trustdinfo")
    require_exact_keys(
        secrets["certs"], {"etcd", "k8s", "k8saggregator", "k8sserviceaccount", "os"}, "secrets.certs"
    )
    for name in ("etcd", "k8s", "k8saggregator", "os"):
        require_exact_keys(secrets["certs"][name], {"crt", "key"}, f"secrets.certs.{name}")
    require_exact_keys(secrets["certs"]["k8sserviceaccount"], {"key"}, "service account")
    if any(not str(value) for value in scalar_values(secrets)):
        raise RenderError("Talos secret bundle contains an empty scalar")
    return topology


def scalar_values(value: Any) -> list[Any]:
    if isinstance(value, dict):
        return [scalar for child in value.values() for scalar in scalar_values(child)]
    if isinstance(value, list):
        return [scalar for child in value for scalar in scalar_values(child)]
    return [value]


def private_write(path: Path, content: str) -> None:
    flags = os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_NOFOLLOW
    descriptor = os.open(path, flags, 0o600)
    try:
        os.write(descriptor, content.encode())
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def run(command: list[str], **kwargs: Any) -> subprocess.CompletedProcess[str]:
    try:
        return subprocess.run(
            command,
            check=True,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            **kwargs,
        )
    except subprocess.CalledProcessError as error:
        diagnostic = error.stderr or "command failed without diagnostics"
        diagnostic = re.sub(
            r"-----BEGIN [^-]+-----.*?-----END [^-]+-----",
            "<redacted-pem>",
            diagnostic,
            flags=re.DOTALL,
        )
        diagnostic = re.sub(r"\\b[A-Za-z0-9_+/=-]{40,}\\b", "<redacted>", diagnostic)
        raise RenderError(
            f"{' '.join(command[:3])} failed: {diagnostic.strip()}"
        ) from None


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--context", type=Path, required=True)
    parser.add_argument("--hostname", required=True)
    parser.add_argument("--output-dir", type=Path, required=True)
    parser.add_argument("--template-dir", type=Path, required=True)
    parser.add_argument("--allow-synthetic", action="store_true")
    parser.add_argument("--skip-talosconfig", action="store_true")
    args = parser.parse_args()

    context = json.loads(args.context.read_text(encoding="utf-8"))
    topology = validate_context(context, args.allow_synthetic)
    node = next((item for item in topology["nodes"] if item["hostname"] == args.hostname), None)
    if node is None:
        raise RenderError("hostname is not one of the five protected inventory nodes")
    output_dir = args.output_dir.resolve()
    if output_dir.is_symlink() or not output_dir.is_dir():
        raise RenderError("output directory must be an existing real directory")
    os.chmod(output_dir, 0o700)

    selected = {**context, "node": node}
    selected_path = output_dir / "context.json"
    private_write(selected_path, json.dumps(selected, sort_keys=True, separators=(",", ":")))
    rendered: dict[str, Path] = {}
    for name in ("machineconfig", "networking", "node"):
        destination = output_dir / f"{name}.yaml"
        run(
            [
                "minijinja-cli",
                "--strict",
                "--autoescape",
                "none",
                "--no-include",
                "--output",
                str(destination),
                str(args.template_dir / f"{name}.yaml.j2"),
                str(selected_path),
            ]
        )
        os.chmod(destination, 0o600)
        rendered[name] = destination
        try:
            run(["yq", "-e", ".", str(destination)])
        except RenderError as error:
            if args.allow_synthetic and name == "networking":
                numbered = "\n".join(
                    f"{index}: {line}"
                    for index, line in enumerate(
                        destination.read_text(encoding="utf-8").splitlines(), start=1
                    )
                )
                raise RenderError(
                    f"{name} template is invalid YAML: {error}\n{numbered}"
                ) from None
            raise RenderError(f"{name} template is invalid YAML: {error}") from None

    machine_path = output_dir / f"{args.hostname}.yaml"
    patched = run(
        [
            "talosctl",
            "machineconfig",
            "patch",
            str(rendered["machineconfig"]),
            "-p",
            f"@{rendered['networking']}",
            "-p",
            f"@{rendered['node']}",
        ]
    )
    private_write(machine_path, patched.stdout)
    try:
        run(["talosctl", "validate", "--config", str(machine_path), "--mode", "metal"])
    except RenderError as error:
        if args.allow_synthetic:
            safe_documents = run(
                [
                    "yq",
                    "eval",
                    'select(.kind == "BondConfig" or .kind == "UserVolumeConfig")',
                    str(machine_path),
                ]
            ).stdout
            raise RenderError(f"{error}\n{safe_documents}") from None
        raise

    if not args.skip_talosconfig:
        secrets_path = output_dir / "secrets.json"
        private_write(secrets_path, json.dumps(context["secrets"], separators=(",", ":")))
        run(
            [
                "talosctl",
                "gen",
                "config",
                str(topology["cluster"]["name"]),
                str(topology["cluster"]["endpoint"]),
                "--with-secrets",
                str(secrets_path),
                "--output-types",
                "talosconfig",
                "--output-dir",
                str(output_dir),
                "--force",
            ]
        )
        os.chmod(output_dir / "talosconfig", 0o600)

    digest = hashlib.sha256(machine_path.read_bytes()).hexdigest()
    metadata = {
        "hostname": node["hostname"],
        "role": node["role"],
        "address": node["address"],
        "sha256": digest,
        "future_osd_present": True,
    }
    print(json.dumps(metadata, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
