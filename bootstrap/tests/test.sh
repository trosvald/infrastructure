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
internal_stages = (
    "preflight",
    "nodes",
    "kubernetes",
    "kubeconfig-node",
    "cilium",
    "bgp",
    "api-vip",
    "kubeconfig-cilium",
    "coredns",
    "flux",
    "verify",
)
public_boundaries = ("cluster", "preflight", "network", "flux", "verify", "validate")
assert "until " not in script
assert "AlreadyExists" not in script
assert "while true" not in script
assert "--force-conflicts" not in script
assert "retry 60 5" in script and "retry 30 3" in script
assert "will continue with empty password" in script
assert "delete -f" in script and "clusters.yaml" in script
assert "cilium-bgp-auth-bsd-k8s-" in script and "--from-file=password=" in script
assert "10.25.20.11" in script and "10.25.20.10" in script
assert "etcd snapshot" in script and "age -r" in script
assert "member_count" in script and "etcd members" in script and "len([line for line in sys.stdin" in script
assert 'if [[ "$count" == 0 ]]' in script
assert "three_members_ready" in script and "expected exactly three etcd members" in script
assert "revalidating bootstrap stage recorded by advisory checkpoint" in script
assert "set_kubeconfig_server https://10.25.11.11:6443" in script
assert "set_kubeconfig_server https://k8s.monosense.io:6443" in script
assert "jsonpath='{.contexts[0].context.cluster}'" in script
assert "pool-infrastructure pool-internal pool-edge-backend advertisement peers" in script
assert "-l k8s-app=cilium -o name" in script
assert '[[ "${#pods[@]}" == 5 ]]' in script
assert '"$output"' in script and "== 1" in script
for index in ("01", "02", "03", "04", "05"):
    assert f'"password_{index}"' in script
assert "--selector name=cilium" in script and "--selector name=coredns" in script
assert 'cp "$kubeconfig" "$repo_dir/kubeconfig"' in script
assert 'cp "$talosconfig" "$repo_dir/talosconfig"' in script
assert "worker-withdrawn" in script and "controlplane-withdrawn" in script
assert "all-withdrawn" in script and "temporary-removed" in script
assert "set_bgp_label" in script and script.count("set_bgp_peer_state") >= 6
assert "acceptance-evidence.json" in script
assert "worker withdrawal exceeded ${acceptance_timeout} seconds" in script
assert "all-peer withdrawal exceeded ${acceptance_timeout} seconds" in script
assert "fluxinstance/flux" in script
for root in ("flux-repositories", "infrastructure-controllers", "infrastructure-configs", "cluster-apps"):
    assert root in script
acceptance = Path("ansible/junos/playbooks/bgp-acceptance.yml").read_text()
assert "show route forwarding-table destination 10.25.20.11" in acceptance
assert "show route forwarding-table destination 10.25.20.10" in acceptance
assert "acceptance_service_paths ==" in acceptance
assert "acceptance_api_paths ==" in acceptance
assert "edge_review_not_before" in script
assert "timedelta(days=7)" in script
assert "authorizes_deployment: false" in script
assert "protected install, LocalPV, or future OSD identity is absent" in script
assert ".install_disk.wwid" in script and ".install_disk.bus_path_prefix" in script
assert ".localpv_disk.match" in script and ".future_osd.serial" in script
assert ".bootstrap_address" in render
assert "apply-config --insecure" in render
assert "verify_maintenance_target" in render
assert "live protected disk identities changed before apply" in render
assert "live X710 or NTP gate failed before apply" in render
assert "verify_node" in render
assert "confirm-bond $hostname" in script
assert "management NIC remains enabled" in script
assert "permanent or MGMT address did not persist" in script
for forbidden in ("spegel", "cert-manager", "external-secrets", "flux sync"):
    assert forbidden not in script, forbidden
for stage in internal_stages:
    assert stage in script
for boundary in public_boundaries:
    assert f"{boundary}:" in justfile
assert justfile.count("[doc(") == len(public_boundaries)
assert 'cluster:\n    "{{ source_directory() }}/scripts/cluster.sh" all' in justfile
apps = Path("bootstrap/helmfile/apps.yaml").read_text()
assert "name: cilium" in apps and "name: coredns" in apps
for rejected in ("spegel", "cert-manager", "external-secrets", "flux-operator"):
    assert rejected not in apps
assert not Path("bootstrap/helmfile/crds.yaml").exists()
bootstrap_flux = Path("bootstrap/flux/fluxinstance.yaml").read_bytes()
git_flux = Path("kubernetes/apps/flux-system/flux-instance/app/fluxinstance.yaml").read_bytes()
assert bootstrap_flux == git_flux
flux = bootstrap_flux.decode()
assert "https://git.monosense.io/trosvald/infrastructure.git" in flux
assert "interval: 5m" in flux and "networkPolicy: true" in flux
for component in ("notification-controller", "image-reflector-controller", "image-automation-controller"):
    assert component in flux
for rejected in ("--concurrent", "OOMWatch", "DisableChartDigestTracking", "medium: Memory"):
    assert rejected not in flux
print("Bootstrap state machine is bounded to Cilium, CoreDNS, Flux Operator, and FluxInstance")
PY
