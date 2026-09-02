#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
evidence="$repo_dir/.private/cilium-acceptance.json"
cd "$repo_dir"
for tool in curl jq just kubectl; do
    command -v "$tool" >/dev/null 2>&1 || { echo "missing locked tool: $tool" >&2; exit 1; }
done
[[ -f "$evidence" && ! -L "$evidence" ]] || {
    echo "reviewed external Cilium acceptance evidence is unavailable: $evidence" >&2
    exit 1
}
jq -e '
    keys == ["acceleration_mode", "api_vip", "bond_failover", "direct_return",
        "dsr_source_preserved", "mtu_payload_bytes", "performance", "reviewed_at"] and
    (.reviewed_at | type == "string" and fromdateiso8601 <= now) and
    .mtu_payload_bytes == 1468 and
    .dsr_source_preserved == true and
    .direct_return == true and
    .api_vip == "10.25.20.10" and
    (.acceleration_mode == "native-xdp" or .acceleration_mode == "safe-tc-fallback") and
    .bond_failover == {tor1: true, tor2: true} and
    (.performance | keys) ==
        ["bbr_cpu_percent", "bbr_gbps", "bbr_latency_ms", "cubic_cpu_percent",
         "cubic_gbps", "cubic_latency_ms"] and
    all(.performance[]; type == "number" and . > 0)
' "$evidence" >/dev/null || {
    echo "Cilium evidence must contain reviewed MTU, DSR, bond, acceleration, and BBR/CUBIC A/B results" >&2
    exit 1
}

nodes_json="$(kubectl get nodes -o json)"
jq -e '
    ([.items[].metadata.name] | sort) ==
        ["bsd-k8s-01", "bsd-k8s-02", "bsd-k8s-03", "bsd-k8s-04", "bsd-k8s-05"] and
    all(.items[]; any(.status.conditions[]; .type == "Ready" and .status == "True"))
' <<<"$nodes_json" >/dev/null
pods_json="$(kubectl -n kube-system get pods -l k8s-app=cilium -o json)"
jq -e '
    [.items[] | select(.status.phase == "Running") | .spec.nodeName] | sort ==
        ["bsd-k8s-01", "bsd-k8s-02", "bsd-k8s-03", "bsd-k8s-04", "bsd-k8s-05"]
' <<<"$pods_json" >/dev/null

established=0
while IFS=$'\t' read -r node pod; do
    status="$(kubectl -n kube-system exec "$pod" -c cilium-agent -- cilium-dbg status --verbose)"
    encryption="$(kubectl -n kube-system exec "$pod" -c cilium-agent -- cilium-dbg encrypt status)"
    links="$(kubectl -n kube-system exec "$pod" -c cilium-agent -- ip -details link show bond0)"
    congestion="$(kubectl -n kube-system exec "$pod" -c cilium-agent -- sysctl -n net.ipv4.tcp_congestion_control)"
    peers="$(kubectl -n kube-system exec "$pod" -c cilium-agent -- cilium-dbg bgp peers)"
    [[ "$status" == *"KubeProxyReplacement"* && "$encryption" == *"Wireguard"* &&
        "$links" == *"mtu 1496"* && "$congestion" == "bbr" ]] || {
        echo "$node: WireGuard, kube-proxy replacement, MTU, or BBR live proof failed" >&2
        exit 1
    }
    [[ "$status" == *"XDP Acceleration"* || "$status" == *"TC"* ]] || {
        echo "$node: neither native XDP nor safe TC fallback is reported" >&2
        exit 1
    }
    count="$(python -c 'import sys; print(sum("established" in line.lower() for line in sys.stdin))' <<<"$peers")"
    [[ "$count" == 1 ]] || { echo "$node: expected one established SRX adjacency" >&2; exit 1; }
    established=$((established + count))
done < <(jq -r '.items[] | select(.status.phase == "Running") | [.spec.nodeName, .metadata.name] | @tsv' <<<"$pods_json" | sort)
[[ "$established" == 5 ]]

[[ "$(curl -fsS --max-time 5 https://k8s.monosense.io:6443/readyz)" == "ok" ]]
just ansible junos bgp-verify
printf 'Cilium live acceptance passed: five encrypted peers, MTU/BBR datapath, API VIP, independent SRX RIB/FIB, and reviewed external DSR/bond/performance evidence\n'
