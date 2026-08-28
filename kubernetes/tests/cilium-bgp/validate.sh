#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
config_dir="$repo_dir/kubernetes/apps/kube-system/cilium/config"
cd "$repo_dir"
for tool in kustomize python yq; do
    command -v "$tool" >/dev/null 2>&1 || {
        echo "missing locked tool: $tool" >&2
        exit 1
    }
done

rendered="$(mktemp "${TMPDIR:-/tmp}/cilium-bgp.XXXXXX")"
trap 'rm -f -- "$rendered"' EXIT
kustomize build "$config_dir" > "$rendered"
echo "validating pool documents"

yq -e '
    .metadata.name == "infrastructure" and
    .spec.blocks[0].cidr == "10.25.20.0/27" and
    .spec.serviceSelector.matchLabels."lbipam.monosense.io/class" == "infrastructure"
' "$config_dir/pool-infrastructure.yaml" >/dev/null
yq -e '
    .metadata.name == "internal" and
    .spec.blocks[0].cidr == "10.25.20.32/27" and
    .spec.serviceSelector.matchLabels."lbipam.monosense.io/class" == "internal"
' "$config_dir/pool-internal.yaml" >/dev/null
yq -e '
    .metadata.name == "edge-backend" and
    .spec.blocks[0].cidr == "10.25.20.64/27" and
    .spec.serviceSelector.matchLabels."lbipam.monosense.io/class" == "edge-backend"
' "$config_dir/pool-edge-backend.yaml" >/dev/null
echo "validating advertisement"
yq -e '
    (.spec.advertisements | length) == 1 and
    .spec.advertisements[0].advertisementType == "Service" and
    .spec.advertisements[0].selector.matchLabels."bgp.monosense.io/advertise" == "true" and
    (.spec.advertisements[0].service.addresses | length) == 1 and
    .spec.advertisements[0].service.addresses[0] == "LoadBalancerIP"
' "$config_dir/advertisement.yaml" >/dev/null
echo "validating peer"
yq -e '
    .spec.authSecretRef == "cilium-bgp-auth" and
    .spec.timers.connectRetryTimeSeconds == 5 and
    .spec.timers.holdTimeSeconds == 9 and
    .spec.timers.keepAliveTimeSeconds == 3 and
    .spec.gracefulRestart.enabled == false and
    .spec.families[0].afi == "ipv4" and
    .spec.families[0].safi == "unicast"
' "$config_dir/peer.yaml" >/dev/null
echo "validating cluster"
yq -e '
    .spec.nodeSelector.matchLabels."bgp.monosense.io/enabled" == "true" and
    .spec.bgpInstances[0].localASN == 64513 and
    .spec.bgpInstances[0].peers[0].peerASN == 64512 and
    .spec.bgpInstances[0].peers[0].peerAddress == "10.25.11.1" and
    .spec.bgpInstances[0].peers[0].peerConfigRef.name == "cilium-srx1500" and
    (.spec.bgpInstances[0] | has("localPort") | not)
' "$config_dir/cluster.yaml" >/dev/null
echo "validating API VIP"
yq -e '
    .metadata.annotations."lbipam.cilium.io/ips" == "10.25.20.10" and
    .metadata.labels."lbipam.monosense.io/class" == "infrastructure" and
    .metadata.labels."bgp.monosense.io/advertise" == "true" and
    (.metadata.annotations | has("external-dns.alpha.kubernetes.io/hostname") | not) and
    .spec.externalTrafficPolicy == "Local"
' "$config_dir/vip.yaml" >/dev/null
echo "validating Helm values"
yq -e '
    .spec.values.mtu == 1496 and .spec.values.devices == "bond0" and
    .spec.values.routingMode == "native" and
    .spec.values.autoDirectNodeRoutes == true and
    .spec.values.bgpControlPlane.enabled == true and
    .spec.values.loadBalancer.algorithm == "maglev" and
    .spec.values.loadBalancer.mode == "dsr" and
    (.spec.values.bgpControlPlane | has("localPort") | not)
' "$repo_dir/kubernetes/apps/kube-system/cilium/app/helmrelease.yaml" >/dev/null
echo "validating aggregate output"

python - "$rendered" <<'PY'
from pathlib import Path
import sys

text = Path(sys.argv[1]).read_text(encoding="utf-8")
for forbidden in (
    "192.168.0.1",
    "192.168.20.0/24",
    "k8s.internal",
    "2514",
    "selector: {}",
    "localPort:",
    "PodCIDR",
    "ClusterIP",
):
    assert forbidden not in text, forbidden
assert text.count("kind: CiliumLoadBalancerIPPool") == 3
envoy = Path("kubernetes/apps/networking/envoy-gateway/proxy/envoy.yaml").read_text()
assert "lbipam.cilium.io/ips: 10.25.20.40" in envoy
assert "lbipam.cilium.io/ips: 10.25.20.80" in envoy
assert envoy.count('bgp.monosense.io/advertise: "true"') == 2
assert "lbipam.monosense.io/class: internal" in envoy
assert "lbipam.monosense.io/class: edge-backend" in envoy
assert "suspend: true" in Path("kubernetes/apps/media/qbittorrent/ks.yaml").read_text()
assert "tag: 1.19.6" in Path(
    "kubernetes/apps/kube-system/cilium/app/ocirepository.yaml"
).read_text()
assert "--kustomize=../../kubernetes/apps/{{ .Release.Namespace }}/{{ .Release.Name }}/config" not in Path(
    "bootstrap/helmfile/apps.yaml"
).read_text()
assert "10.25.20.10" in text
assert "localASN: 64513" in text and "peerASN: 64512" in text
print("Cilium BGP resources preserve staged authenticated /32-only activation")
PY
