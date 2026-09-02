#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
action="${1:-}"
node="${2:-}"
case "$action" in
    audit)
        [[ $# -eq 1 ]] || { echo "usage: host-firewall.sh audit" >&2; exit 2; }
        ;;
    enforce)
        [[ $# -eq 2 && "$node" =~ ^bsd-k8s-0[1-5]$ ]] || {
            echo "usage: host-firewall.sh enforce bsd-k8s-0[1-5]" >&2
            exit 2
        }
        ;;
    *) echo "usage: host-firewall.sh audit|enforce" >&2; exit 2 ;;
esac
cd "$repo_dir"
for tool in jq kubectl talosctl; do
    command -v "$tool" >/dev/null 2>&1 || { echo "missing locked tool: $tool" >&2; exit 1; }
done

pod_for_node() {
    kubectl -n kube-system get pods -l k8s-app=cilium \
        --field-selector "spec.nodeName=$1,status.phase=Running" -o json |
        jq -er 'if (.items | length) == 1 then .items[0].metadata.name else error("one Cilium pod required") end'
}
host_endpoint() {
    kubectl -n kube-system exec "$1" -c cilium-agent -- cilium-dbg endpoint list -o json |
        jq -er '[.[] | select(any(.status.identity.labels[]?; . == "reserved:host"))] |
            if length == 1 then .[0].id else error("one host endpoint required") end'
}
endpoint_mode() {
    kubectl -n kube-system exec "$1" -c cilium-agent -- \
        cilium-dbg endpoint config "$2" | awk '$1 == "PolicyAuditMode" {print $2}'
}

if [[ "$action" == audit ]]; then
    for index in 01 02 03 04 05; do
        current="bsd-k8s-$index"
        pod="$(pod_for_node "$current")"
        endpoint="$(host_endpoint "$pod")"
        mode="$(endpoint_mode "$pod" "$endpoint")"
        printf '%s\tendpoint=%s\tPolicyAuditMode=%s\n' "$current" "$endpoint" "$mode"
    done
    echo "Review bounded Hubble evidence for BGP, WireGuard, API/etcd/kubelet/KubePrism/Talos, DNS/NTP, and storage before enforcement."
    exit 0
fi

evidence="$repo_dir/.private/host-firewall/$node.json"
[[ -f "$evidence" && ! -L "$evidence" ]] || {
    echo "$node: reviewed Hubble and break-glass evidence is unavailable: $evidence" >&2
    exit 1
}
jq -e '
    keys == ["bgp", "break_glass", "dns_ntp", "kubernetes_control_plane", "quorum",
        "reviewed_at", "storage", "talos", "wireguard"] and
    (.reviewed_at | type == "string" and fromdateiso8601 <= now) and
    .bgp and .break_glass and .dns_ntp and .kubernetes_control_plane and .quorum and
    .storage and .talos and .wireguard
' "$evidence" >/dev/null || {
    echo "$node: evidence does not cover every required host flow, quorum, and break-glass path" >&2
    exit 1
}
kubectl get ciliumclusterwidenetworkpolicy "host-firewall-$node" >/dev/null || {
    echo "$node: declarative host firewall policy is not reconciled" >&2
    exit 1
}
kubectl get nodes -o json | jq -e '
    ([.items[] | select(any(.status.conditions[]; .type == "Ready" and .status == "True"))] | length) == 5
' >/dev/null || { echo "all five nodes must be Ready before enforcement" >&2; exit 1; }

pod="$(pod_for_node "$node")"
endpoint="$(host_endpoint "$pod")"
[[ "$(endpoint_mode "$pod" "$endpoint")" == "Enabled" ]] || {
    echo "$node: host endpoint is not in audit mode" >&2
    exit 1
}
rollback() {
    rollback_pod="$(pod_for_node "$node" 2>/dev/null || true)"
    if [[ -n "$rollback_pod" ]]; then
        rollback_endpoint="$(host_endpoint "$rollback_pod" 2>/dev/null || true)"
        if [[ -n "$rollback_endpoint" ]]; then
            kubectl -n kube-system exec "$rollback_pod" -c cilium-agent -- \
                cilium-dbg endpoint config "$rollback_endpoint" PolicyAuditMode=Enabled >/dev/null || true
        fi
    fi
    kubectl uncordon "$node" >/dev/null 2>&1 || true
}
trap rollback ERR HUP INT TERM
kubectl drain "$node" --ignore-daemonsets --delete-emptydir-data --timeout=10m
management="10.25.10.$((110 + 10#${node##*-}))"
talosctl --nodes "$management" reboot --wait=false
kubectl wait --for=condition=Ready "node/$node" --timeout=10m
new_pod="$(pod_for_node "$node")"
new_endpoint="$(host_endpoint "$new_pod")"
[[ "$(endpoint_mode "$new_pod" "$new_endpoint")" == "Enabled" ]]
kubectl -n kube-system exec "$new_pod" -c cilium-agent -- \
    cilium-dbg endpoint config "$new_endpoint" PolicyAuditMode=Disabled >/dev/null
[[ "$(endpoint_mode "$new_pod" "$new_endpoint")" == "Disabled" ]]
kubectl uncordon "$node"
[[ "$(kubectl -n kube-system exec "$new_pod" -c cilium-agent -- cilium-dbg bgp peers)" == *"Established"* ]]
[[ "$(kubectl get --raw=/readyz)" == "ok" ]]
trap - ERR HUP INT TERM
printf '%s: host firewall enforced after drain, reboot, quorum, BGP, API, and break-glass gates\n' "$node"
