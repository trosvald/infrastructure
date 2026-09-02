#!/usr/bin/env bash
set -euo pipefail

readonly repository_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
readonly module="$repository_root/kubernetes/mod.just"
readonly operator="$repository_root/kubernetes/scripts/operator.sh"

for removed in apply-ks delete-ks sync prune-pods view-secret debug-node browse-pvc; do
    if grep -Eq "^${removed}([[:space:]]|:)" "$module"; then
        printf 'removed public recipe remains: %s\n' "$removed" >&2
        exit 1
    fi
done

for required in validate render-root status activate-repositories activate-controllers activate-configs activate-apps suspend resume inventory-retired-data accept-cilium audit-host-firewall enforce-host-firewall-node; do
    grep -Eq "^${required}([[:space:]]|:)" "$module" || {
        printf 'required public recipe is missing: %s\n' "$required" >&2
        exit 1
    }
done

grep -Fq "pattern='flux-repositories|infrastructure-controllers|infrastructure-configs|cluster-apps'" "$module"
grep -Fq "pattern='ks|hr'" "$module"
bash -n "$operator"
bash -n "$repository_root/kubernetes/scripts/accept-cilium.sh"
bash -n "$repository_root/kubernetes/scripts/host-firewall.sh"

printf 'Kubernetes operator interface contracts passed\n'
