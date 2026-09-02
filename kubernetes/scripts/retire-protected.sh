#!/usr/bin/env bash
set -euo pipefail

readonly script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
readonly allowlist="$script_dir/../retirement/protected-resources.tsv"
readonly fixed_id=${1:-}
[[ $# == 1 && "$fixed_id" =~ ^[a-z0-9-]+$ ]] || {
    printf 'retire-protected requires one fixed allowlisted identifier\n' >&2
    exit 2
}
record=$(awk -F '\t' -v id="$fixed_id" '$1 == id { print $0 }' "$allowlist")
[[ -n "$record" ]] || {
    printf 'protected resource identifier is not allowlisted: %s\n' "$fixed_id" >&2
    exit 2
}
IFS=$'\t' read -r _ api_version kind namespace name reason <<<"$record"
[[ -n "$reason" ]] || {
    printf 'protected resource lacks a retirement reason: %s\n' "$fixed_id" >&2
    exit 1
}
kubectl get --raw=/version >/dev/null
annotation=$(kubectl -n "$namespace" get "$kind" "$name" -o jsonpath='{.metadata.annotations.kustomize\.toolkit\.fluxcd\.io/prune}')
[[ "$annotation" == disabled ]] || {
    printf 'live resource is not prune-protected: %s\n' "$fixed_id" >&2
    exit 1
}
kubectl -n "$namespace" delete "$kind" "$name" --wait=true
printf 'retired protected resource %s (%s)\n' "$fixed_id" "$reason"
