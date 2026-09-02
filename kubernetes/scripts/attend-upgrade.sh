#!/usr/bin/env bash
set -euo pipefail

readonly KIND=${1:-}
readonly NAMESPACE=system-upgrade
readonly FLUX_KUSTOMIZATION=tuppr-upgrades
readonly ALERTMANAGER_RAW='/api/v1/namespaces/observability/services/http:vmalertmanager-victoria-metrics:9093/proxy/api/v2'
readonly ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

case "$KIND" in
    kubernetes)
        readonly RESOURCE=kubernetesupgrades.tuppr.home-operations.com/kubernetes
        readonly SUSPEND_VALUE=separate-attended-window-required
        readonly TARGET_VERSION=v1.36.4
        ;;
    *)
        printf 'usage: %s kubernetes\n' "$0" >&2
        exit 2
        ;;
esac
for command in kubectl flux jq just talosctl; do
    command -v "$command" >/dev/null || { printf 'required command is unavailable: %s\n' "$command" >&2; exit 1; }
done

"$ROOT_DIR/kubernetes/scripts/accept-upgrade-preflight.sh"
weekday=$(TZ=Asia/Jakarta date +%u)
hour=$(TZ=Asia/Jakarta date +%H)
[[ "$weekday" == 7 && 10#$hour -ge 1 && 10#$hour -lt 7 ]] || {
    printf 'attended upgrades are allowed only Sunday 01:00-07:00 Asia/Jakarta\n' >&2
    exit 1
}
printf 'Type exactly "attend %s %s" to lease silences and resume only this upgrade: ' "$KIND" "$TARGET_VERSION" >&2
IFS= read -r confirmation
[[ "$confirmation" == "attend $KIND $TARGET_VERSION" ]] || {
    printf 'confirmation did not match; upgrade remains suspended\n' >&2
    exit 1
}

silence_ids=()
cleanup() {
    local status=$?
    trap - EXIT INT TERM
    kubectl -n "$NAMESPACE" annotate "$RESOURCE" "tuppr.home-operations.com/suspend=$SUSPEND_VALUE" --overwrite >/dev/null 2>&1 || true
    for silence_id in "${silence_ids[@]}"; do
        kubectl delete --raw "$ALERTMANAGER_RAW/silence/$silence_id" >/dev/null 2>&1 || true
    done
    kubectl -n "$NAMESPACE" patch kustomization "$FLUX_KUSTOMIZATION" --type=merge -p '{"spec":{"suspend":null}}' >/dev/null 2>&1 || true
    flux reconcile kustomization "$FLUX_KUSTOMIZATION" --namespace "$NAMESPACE" --with-source >/dev/null 2>&1 || true
    exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

create_silence() {
    local comment=$1 matchers=$2 response
    response=$(jq -cn --arg comment "$comment" --argjson matchers "$matchers" '
        {
            matchers: $matchers,
            startsAt: (now | todateiso8601),
            endsAt: ((now + 21600) | todateiso8601),
            createdBy: "just-kube-attended-upgrade",
            comment: $comment
        }
    ' | kubectl create --raw "$ALERTMANAGER_RAW/silences" -f -)
    jq -er '.silenceID' <<<"$response"
}

node_matchers='[
  {"name":"alertname","value":"KubeNodeNotReady|KubeNodeUnreachable","isRegex":true,"isEqual":true},
  {"name":"node","value":"bsd-k8s-0[1-5]","isRegex":true,"isEqual":true}
]'
controller_matchers='[
  {"name":"alertname","value":"KubePodNotReady|KubeDeploymentReplicasMismatch","isRegex":true,"isEqual":true},
  {"name":"namespace","value":"system-upgrade","isRegex":false,"isEqual":true}
]'
silence_ids+=("$(create_silence "$KIND $TARGET_VERSION attended node lease" "$node_matchers")")
silence_ids+=("$(create_silence "$KIND $TARGET_VERSION attended controller lease" "$controller_matchers")")

kubectl -n "$NAMESPACE" patch kustomization "$FLUX_KUSTOMIZATION" --type=merge -p '{"spec":{"suspend":true}}'
kubectl -n "$NAMESPACE" annotate "$RESOURCE" tuppr.home-operations.com/suspend-

readonly deadline=$(( $(date +%s) + 21600 ))
while (( $(date +%s) < deadline )); do
    phase=$(kubectl -n "$NAMESPACE" get "$RESOURCE" -o jsonpath='{.status.phase}')
    case "$phase" in
        Completed)
            break
            ;;
        Failed)
            kubectl -n "$NAMESPACE" get "$RESOURCE" -o yaml >&2
            printf '%s upgrade failed\n' "$KIND" >&2
            exit 1
            ;;
    esac
    sleep 30
done
[[ ${phase:-} == Completed ]] || {
    printf '%s upgrade did not complete within its six-hour lease\n' "$KIND" >&2
    exit 1
}

kubectl get nodes
kubectl -n rook-ceph get cephcluster rook-ceph -o json | jq -e '.status.ceph.health == "HEALTH_OK"' >/dev/null
kubectl -n database get cluster.postgresql.cnpg.io postgres -o json | jq -e '.status.instances == 3 and .status.readyInstances == 3' >/dev/null
talosctl health --server=false
just ansible junos bgp-verify
printf '%s %s completed; the upgrade is suspended again and silence cleanup is armed\n' "$KIND" "$TARGET_VERSION"
