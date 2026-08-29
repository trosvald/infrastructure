#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import hashlib
from pathlib import Path
import re
import subprocess


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--first", type=Path, required=True)
    parser.add_argument("--second", type=Path, required=True)
    parser.add_argument("--fixture", type=Path, required=True)
    parser.add_argument("--talos-dir", type=Path, required=True)
    args = parser.parse_args()

    fixture = args.fixture.read_text(encoding="utf-8")
    fixture_data = json.loads(
        subprocess.run(
            ["yq", "-o=json", ".", str(args.fixture)],
            check=True,
            text=True,
            stdout=subprocess.PIPE,
        ).stdout
    )
    nodes = fixture_data["nodes"]
    machine_template = (args.talos_dir / "machineconfig.yaml.j2").read_text(encoding="utf-8")
    networking_template = (args.talos_dir / "networking.yaml.j2").read_text(encoding="utf-8")
    normalized_machine_template = machine_template.replace('"', "")
    tracked = "\n".join(
        path.read_text(encoding="utf-8")
        for path in (
            args.fixture,
            args.talos_dir / "machineconfig.yaml.j2",
            args.talos_dir / "networking.yaml.j2",
            args.talos_dir / "node.yaml.j2",
            args.talos_dir / "schematic.yaml.j2",
        )
    )
    forbidden = (
        "op://",
        "802.3ad",
        "lacpRate",
        "DHCPv4Config",
        "VLANConfig",
        "2514",
        "mtu: 9000",
        "hostname: k1",
        "hostname: k2",
        "hostname: k3",
        "hostname: k4",
        "hostname: k5",
        "TPBF2408190010102014",
        "TPBF2302090010406892",
        "TPBF2502170050103057",
        "S666NN0W401713",
        "S666NN0X221313",
        "BEGIN PRIVATE KEY",
        "BEGIN RSA PRIVATE KEY",
        "BEGIN EC PRIVATE KEY",
        "module_blacklist=e1000e",
        "mitigations=off",
        "apparmor=0",
        "security=none",
        "- net.core.*",
        "- net.ipv4.*",
    )
    for pattern in forbidden:
        assert pattern not in tracked, f"tracked Talos source contains forbidden pattern: {pattern}"
    assert "future_osd:" in fixture
    assert fixture.count("size_bytes: 1000204886016") == len(nodes)
    assert fixture.count("disk.size == 512110190592u") == len(nodes)
    macs = re.findall(r'permanent_mac: "([0-9a-f:]+)"', fixture)
    assert len(macs) == 2 * len(nodes) and len(set(macs)) == 2 * len(nodes)
    for legacy_field in (
        "  files:",
        "  install:",
        "  kernel:",
        "  kubelet:",
        "  sysctls:",
        "  discovery:",
        "  id:",
        "  network:",
        "  secret:",
        "  allowSchedulingOnControlPlanes:",
        "  apiServer:",
        "  controllerManager:",
        "  coreDNS:",
        "  proxy:",
        "  scheduler:",
        "  secretboxEncryptionSecret:",
    ):
        assert re.search(rf"(?m)^{re.escape(legacy_field)}", machine_template) is None, legacy_field
    assert "hostDNS:" in machine_template
    assert "forwardKubeDNSToHost: true" in machine_template
    assert "resolveMemberNames: true" in machine_template
    assert "hostDNS:" not in networking_template
    assert all(mac.startswith("02:") for mac in macs)
    for node in nodes:
        assert f"bootstrap_address: {node['bootstrap_address']}" in fixture

    for node in nodes:
        hostname = node["hostname"]
        first_path = args.first / f"{hostname}.yaml"
        second_path = args.second / f"{hostname}.yaml"
        assert digest(first_path) == digest(second_path), f"{hostname}: nondeterministic digest"
        text = first_path.read_text(encoding="utf-8")
        role = node["role"]
        address = f"{node['address']}/24"
        bootstrap_address = f"{node['bootstrap_address']}/24"
        localpv_serial = re.search(
            r'disk\.serial == "([^"]+)"', node["localpv_disk"]["match"]
        )
        assert localpv_serial is not None
        assert f"hostname: {hostname}" in text
        assert f"type: {role}" in text
        assert address in text
        assert bootstrap_address in text
        assert f"- {node['address']}/32" in text
        assert "kind: LinkConfig" in text
        assert "bondMode: active-backup" in text
        assert f"hardwareAddr: '{node['links']['tor1']['permanent_mac']}'" in text
        assert "arpInterval: 1000" in text
        assert "arpValidate: active" in text
        assert "arpAllTargets: all" in text
        assert "primaryReselect: failure" in text
        assert "numPeerNotif: 3" in text
        assert "mtu: 1496" in text
        assert "enp1s0f0np0" in text and "enp1s0f1np1" in text
        assert "kind: LinkAliasConfig" not in text
        assert "metric: 1024" in text and "metric: 2048" in text
        assert node["install_disk"]["wwid"] in text
        install_bus_prefix = node["install_disk"]["bus_path_prefix"]
        assert f'disk.bus_path.startsWith("{install_bus_prefix}")' in text
        assert "filesystem:" in text and "type: xfs" in text
        assert localpv_serial.group(1) in text
        assert node["future_osd"]["serial"] not in text
        assert 'bgp.monosense.io/enabled: \"true\"' in text
        assert "topology.monosense.io/site:" in text
        assert "topology.monosense.io/power-domain:" in text
        assert "topology.monosense.io/network-domain:" in text
        assert "kind: ResolverConfig" in text
        assert "192.0.2.53" in text and "198.51.100.53" in text
        assert "kind: TimeSyncConfig" in text
        assert "time-a.example.invalid" in text
        for kind in (
            "DiscoveryServiceConfig",
            "DiscoveryIdentityConfig",
            "UnattendedInstallConfig",
            "FilesystemTrimConfig",
            "FilesystemScrubConfig",
            "WatchdogTimerConfig",
            "SysctlConfig",
            "EtcFileConfig",
            "CRICustomizationConfig",
            "KubeletConfig",
            "KubeNetworkConfig",
            "KubePrismConfig",
        ):
            assert f"kind: {kind}" in text
        assert "metal-installer/" in text and ":v1.14.0-rc.2" in text
        for setting in (
            "fs.inotify.max_user_instances: 8192",
            "fs.inotify.max_user_watches: 1048576",
            "net.core.default_qdisc: fq",
            "user.max_user_namespaces: 11255",
            "net.core.rmem_max: 67108864",
            "net.core.wmem_max: 67108864",
            "net.ipv4.ping_group_range: 0 2147483647",
            "net.ipv4.tcp_congestion_control: bbr",
            "net.ipv4.tcp_fastopen: 3",
            "net.ipv4.tcp_mtu_probing: 1",
            "net.ipv4.tcp_notsent_lowat: 131072",
            "net.ipv4.tcp_slow_start_after_idle: 0",
            "net.ipv4.tcp_window_scaling: 1",
            "net.ipv4.tcp_rmem: 4096 87380 33554432",
            "net.ipv4.tcp_wmem: 4096 65536 33554432",
            "sunrpc.tcp_slot_table_entries: 128",
            "sunrpc.tcp_max_slot_table_entries: 128",
        ):
            assert setting in normalized_machine_template, setting
            assert setting.split(":", 1)[0] in text, setting
        for removed in (
            "net.core.netdev_max_backlog",
            "net.core.somaxconn",
            "net.ipv4.ip_local_port_range",
            "net.ipv4.tcp_fin_timeout",
            "net.ipv4.tcp_max_syn_backlog",
            "net.ipv4.tcp_tw_reuse",
        ):
            assert f"    {removed}:" not in normalized_machine_template
        assert "kind: KernelModuleConfig" not in text
        assert "vm.nr_hugepages" not in text
        assert "nconnect=8" in text
        assert "rsize=1048576" in text
        assert "wsize=1048576" in text
        for allowed_sysctl in (
            "net.ipv4.ip_local_port_range",
            "net.ipv4.tcp_fastopen",
            "net.ipv4.tcp_fin_timeout",
            "net.ipv4.tcp_notsent_lowat",
            "net.ipv4.tcp_slow_start_after_idle",
            "net.ipv4.tcp_tw_reuse",
        ):
            assert f"- {allowed_sysctl}" in normalized_machine_template
        assert "time-b.example.invalid" in text
        assert "time-c.example.invalid" in text
        assert "10.244.0.0/16" in text and "10.245.0.0/16" in text
        assert "192.168.10.0/24" not in text
        assert "192.168.20.0/24" not in text
        assert "k8s.internal" not in text
        assert "VLANConfig" not in text and "9000" not in text
        if role == "controlplane":
            assert "198.51.100.0/24" in text
            for kind in (
                "KubeAPIServerConfig",
                "KubeControllerManagerConfig",
                "KubeCoreDNSConfig",
                "KubeEtcdEncryptionConfig",
                "KubeProxyConfig",
                "KubeSchedulerConfig",
                "KubeTalosAPIAccessConfig",
            ):
                assert f"kind: {kind}" in text
            for san in fixture_data["cluster"]["api_sans"]:
                assert san in text
            assert "node-role.kubernetes.io/control-plane" in text
        else:
            assert "198.18.0.10" not in text
            assert "kind: KubeAPIServerConfig" not in text
            assert "kind: KubeEtcdEncryptionConfig" not in text
            assert "kind: KubeTalosAPIAccessConfig" not in text
            assert "node-role.kubernetes.io/worker" in text
    print(f"Talos synthetic {len(nodes)}-node renders are strict, deterministic, and validated")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
