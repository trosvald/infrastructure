#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$repo_dir"
bash -n bootstrap/scripts/cluster.sh
bash -n talos/scripts/render.sh
bash -n scripts/with-openbao-runtime.sh
python - <<'PY'
from pathlib import Path

script = Path("bootstrap/scripts/cluster.sh").read_text(encoding="utf-8")
render = Path("talos/scripts/render.sh").read_text(encoding="utf-8")
justfile = Path("bootstrap/mod.just").read_text(encoding="utf-8")
expected = (
    "preflight",
    "nodes",
    "kubernetes",
    "kubeconfig-node",
    "cilium",
    "bgp",
    "api-vip",
    "kubeconfig-cilium",
    "verify",
)
assert "until " not in script
assert "AlreadyExists" not in script
assert "while true" not in script
assert "retry 60 5" in script and "retry 30 3" in script
assert "will continue with empty password" in script
assert "delete -f" in script and "cluster.yaml" in script
assert "cilium-bgp-auth" in script and "--from-file=password=" in script
assert "10.25.20.11" in script and "10.25.20.10" in script
assert "etcd snapshot" in script and "age -r" in script
assert "--server=https://10.25.11.11:6443" in script
assert "--server=https://k8s.monosense.io:6443" in script
assert "pool-infrastructure pool-internal pool-edge-backend advertisement peer" in script
assert "--selector name=cilium" in script and "--selector name=coredns" in script
assert 'cp "$kubeconfig" "$repo_dir/kubeconfig"' in script
assert 'cp "$talosconfig" "$repo_dir/talosconfig"' in script
assert '.spec.suspend == true' in script
assert "worker-withdrawn" in script and "controlplane-withdrawn" in script
assert "all-withdrawn" in script and "temporary-removed" in script
assert script.count("set_bgp_label") >= 6
assert "acceptance-evidence.json" in script
assert "worker withdrawal exceeded 9 seconds" in script
assert "all-peer withdrawal exceeded 9 seconds" in script
acceptance = Path("ansible/junos/playbooks/bgp-acceptance.yml").read_text()
assert "show route forwarding-table destination 10.25.20.11" in acceptance
assert "show route forwarding-table destination 10.25.20.10" in acceptance
assert "acceptance_service_paths ==" in acceptance
assert "acceptance_api_paths ==" in acceptance
assert "edge_review_not_before" in script
assert "timedelta(days=7)" in script
assert "authorizes_deployment: false" in script
assert "protected install, LocalPV, or future OSD identity is absent" in script
assert ".install_disk.wwid" in script and ".install_disk.bus_path" in script
assert ".localpv_disk.match" in script and ".future_osd.serial" in script
assert ".bootstrap_address" in render
assert 'apply-config --insecure' in render
assert "verify_maintenance_target" in render
assert "live protected disk identities changed before apply" in render
assert "live X710 or NTP gate failed before apply" in render
assert "verify_node" in render
assert "confirm-bond $hostname" in script
assert "bootstrap NIC remains enabled" in script
junos_intent = "\n".join(
    path.read_text()
    for path in Path("ansible/junos/intent/srx1500").glob("*.yml")
)
for forbidden in ("2515", "irb.2515", "EDGE", "destination_rules", "proxy-arp"):
    assert forbidden not in junos_intent, forbidden
for forbidden in ("spegel", "cert-manager", "external-secrets", "flux sync"):
    assert forbidden not in script, forbidden
for stage in expected:
    assert f"{stage}:" in justfile
    assert stage in script
assert justfile.count("[doc(") == 3
assert 'cluster:\n    "{{ source_directory() }}/scripts/cluster.sh" all' in justfile
assert "suspend: true" in Path("kubernetes/flux/cluster/ks.yaml").read_text()
print("Bootstrap state machine is bounded, resumable, secret-gated, and staged")
PY
