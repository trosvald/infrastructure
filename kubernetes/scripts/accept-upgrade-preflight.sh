#!/usr/bin/env bash
set -euo pipefail

readonly KUBERNETES_VERSION=v1.36.4
readonly TALOS_RESOURCE=talosupgrades.tuppr.home-operations.com/talos
readonly KUBERNETES_RESOURCE=kubernetesupgrades.tuppr.home-operations.com/kubernetes
readonly EXPECTED_NODES='["bsd-k8s-01","bsd-k8s-02","bsd-k8s-03","bsd-k8s-04","bsd-k8s-05"]'
readonly ALERTMANAGER_RAW='/api/v1/namespaces/observability/services/http:vmalertmanager-victoria-metrics:9093/proxy/api/v2/alerts'
readonly ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
readonly VERSION_GUARD="$ROOT_DIR/kubernetes/scripts/assert-forward-version.sh"

for command in kubectl talosctl jq yq just; do
    command -v "$command" >/dev/null || { printf 'required command is unavailable: %s\n' "$command" >&2; exit 1; }
done
[[ -s "$ROOT_DIR/kubeconfig" && -s "$ROOT_DIR/talosconfig" ]] || {
    printf 'reviewed kubeconfig and talosconfig rollback access are required\n' >&2
    exit 1
}

assert_suspended() {
    local resource=$1 expected=$2
    local actual
    actual=$(kubectl -n system-upgrade get "$resource" -o jsonpath='{.metadata.annotations.tuppr\.home-operations\.com/suspend}')
    [[ "$actual" == "$expected" ]] || {
        printf '%s must remain suspended with value %s (found %s)\n' "$resource" "$expected" "${actual:-<empty>}" >&2
        exit 1
    }
}

if kubectl -n system-upgrade get "$TALOS_RESOURCE" >/dev/null 2>&1; then
    printf 'TalosUpgrade must be absent until a stable forward v1.14 target is reviewed\n' >&2
    exit 1
fi
assert_suspended "$KUBERNETES_RESOURCE" separate-attended-window-required
[[ $(kubectl -n system-upgrade get "$KUBERNETES_RESOURCE" -o jsonpath='{.spec.kubernetes.version}') == "$KUBERNETES_VERSION" ]]
[[ "$KUBERNETES_VERSION" != *-* && "$KUBERNETES_VERSION" =~ ^v1\.36\.[0-9]+$ ]]

nodes_json=$(kubectl get nodes -o json)
actual_nodes=$(jq -c '[.items[].metadata.name] | sort' <<<"$nodes_json")
[[ "$actual_nodes" == "$EXPECTED_NODES" ]] || {
    printf 'expected exactly five reviewed nodes; found %s\n' "$actual_nodes" >&2
    exit 1
}
jq -e 'all(.items[]; any(.status.conditions[]; .type == "Ready" and .status == "True"))' <<<"$nodes_json" >/dev/null
while IFS= read -r current_version; do
    "$VERSION_GUARD" "$current_version" "$KUBERNETES_VERSION" 1
done < <(jq -r '.items[].status.nodeInfo.kubeletVersion' <<<"$nodes_json")

leader_holder=$(kubectl -n system-upgrade get lease bea89bcd.home-operations.com -o jsonpath='{.spec.holderIdentity}')
leader_pod=${leader_holder%%_*}
leader_node=$(kubectl -n system-upgrade get pod "$leader_pod" -o jsonpath='{.spec.nodeName}')
jq -e --arg leader "$leader_node" --argjson nodes "$EXPECTED_NODES" '
    ($nodes | index($leader)) != null and
    ([$leader] + [$nodes[] | select(. != $leader)] | length == 5)
' <<<null >/dev/null
printf 'Reviewed Tuppr node order: %s' "$leader_node"
jq -r --arg leader "$leader_node" --argjson nodes "$EXPECTED_NODES" '$nodes[] | select(. != $leader) | " -> " + .' <<<null

jq -e '.status.ceph.health == "HEALTH_OK"' < <(kubectl -n rook-ceph get cephcluster rook-ceph -o json) >/dev/null
jq -e '.status.instances == 3 and .status.readyInstances == 3' < <(kubectl -n database get cluster.postgresql.cnpg.io postgres -o json) >/dev/null
jq -e 'any(.status.conditions[]; .type == "Programmed" and .status == "True")' < <(kubectl -n networking get gateway envoy-internal -o json) >/dev/null

for target in \
    kube-system:daemonset/cilium \
    kube-system:deployment/cilium-operator \
    kube-system:deployment/coredns \
    flux-system:deployment/source-controller \
    flux-system:deployment/kustomize-controller \
    flux-system:deployment/helm-controller \
    flux-system:deployment/notification-controller; do
    namespace=${target%%:*}
    workload=${target#*:}
    kubectl -n "$namespace" rollout status "$workload" --timeout=5m
 done
for kustomization in ceph-csi-drivers rook-ceph rook-ceph-cluster; do
    kubectl -n rook-ceph wait --for=condition=Ready "kustomization/$kustomization" --timeout=5m
done
kubectl -n kube-system get endpointslice -l k8s-app=kube-dns -o json | jq -e '
    [.items[].endpoints[] | select(.conditions.ready == true)] | length >= 2
' >/dev/null
[[ $(kubectl -n kube-system get service kube-vip -o jsonpath='{.status.loadBalancer.ingress[0].ip}') == 10.25.20.10 ]]

pdb_json=$(kubectl get pdb -A -o json)
jq -e '[.items[] | select(
    (.metadata.namespace == "kube-system" or .metadata.namespace == "rook-ceph" or
     .metadata.namespace == "database" or .metadata.namespace == "flux-system") and
    (.status.expectedPods > 0) and (.status.disruptionsAllowed < 1)
)] | length == 0' <<<"$pdb_json" >/dev/null || {
    jq -r '.items[] | select(.status.expectedPods > 0 and .status.disruptionsAllowed < 1) | [.metadata.namespace,.metadata.name] | @tsv' <<<"$pdb_json" >&2
    printf 'a critical PodDisruptionBudget currently blocks eviction\n' >&2
    exit 1
}

backup_json=$(kubectl -n database get backups.postgresql.cnpg.io -l cnpg.io/cluster=postgres -o json)
jq -e 'now as $now | any(.items[];
    .status.phase == "completed" and
    (($now - (.status.stoppedAt | fromdateiso8601)) < 93600)
)' <<<"$backup_json" >/dev/null || {
    printf 'no completed PostgreSQL backup is newer than 26 hours\n' >&2
    exit 1
}

alerts=$(kubectl get --raw "$ALERTMANAGER_RAW")
jq -e '[.[] | select(.status.state == "active" and (.status.silencedBy | length) == 0)] | length == 0' <<<"$alerts" >/dev/null || {
    jq -r '.[] | select(.status.state == "active" and (.status.silencedBy | length) == 0) | .labels.alertname' <<<"$alerts" >&2
    printf 'active unsilenced alerts block an upgrade\n' >&2
    exit 1
}

just ansible junos bgp-verify
talosctl health --server=false
for address in 10.25.11.11 10.25.11.12 10.25.11.13; do
    talosctl --nodes "$address" etcd status >/dev/null
done
snapshot_dir=$(mktemp -d "${TMPDIR:-/tmp}/upgrade-preflight.XXXXXX")
trap 'rm -rf "$snapshot_dir"' EXIT
talosctl --nodes 10.25.11.11 etcd snapshot "$snapshot_dir/etcd.snapshot" >/dev/null
[[ -s "$snapshot_dir/etcd.snapshot" ]]

if kubectl -n system-upgrade get "$TALOS_RESOURCE" >/dev/null 2>&1; then
    printf 'TalosUpgrade appeared during preflight\n' >&2
    exit 1
fi
assert_suspended "$KUBERNETES_RESOURCE" separate-attended-window-required
printf 'Kubernetes upgrade preflight passed without resuming its target: five Ready nodes, controller-first order, Ceph, CNPG, Cilium, DNS, CSI, Flux, etcd, backup, SRX BGP, API VIP, Envoy, alerts, PDBs, and rollback snapshot verified\n'
