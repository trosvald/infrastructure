#!/usr/bin/env bash
set -euo pipefail

readonly repository_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
readonly chart='oci://ghcr.io/controlplaneio-fluxcd/charts/flux-operator@sha256:9e73c85b586f3649b317b215228ac35c1dd15a10dec87b8806f34bd7a22d42ae'
readonly manifest="$repository_root/bootstrap/flux/fluxinstance.yaml"

[[ $# == 0 ]] || {
    printf 'install-flux accepts no arguments\n' >&2
    exit 2
}
: "${KUBECONFIG:?KUBECONFIG must identify the reviewed cluster}"

if kubectl -n flux-system get helmrelease.helm.toolkit.fluxcd.io flux-operator >/dev/null 2>&1; then
    printf 'refusing bootstrap mutation: Flux already owns flux-operator\n' >&2
    exit 1
fi

helm upgrade --install flux-operator "$chart" \
    --namespace flux-system \
    --create-namespace \
    --set web.enabled=false \
    --set serviceMonitor.create=false \
    --wait \
    --wait-for-jobs
kubectl -n flux-system rollout status deployment/flux-operator --timeout=5m
kubectl apply --server-side --field-manager=bootstrap-flux-instance -f "$manifest"
kubectl -n flux-system wait fluxinstance/flux --for=condition=Ready --timeout=10m
