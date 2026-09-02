#!/usr/bin/env bash
set -euo pipefail

readonly test_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
readonly repository_root=$(cd "$test_dir/../.." && pwd)
readonly kube_root="$repository_root/kubernetes"
readonly roots=(flux-repositories infrastructure-controllers infrastructure-configs cluster-apps)

require_command() {
    command -v "$1" >/dev/null 2>&1 || {
        printf 'required locked command is unavailable: %s\n' "$1" >&2
        exit 1
    }
}

require_command just
require_command kustomize
require_command yq
"$test_dir/interfaces.sh"
bash -n "$kube_root/scripts/accept-cilium.sh" "$kube_root/scripts/accept-storage.sh" \
    "$kube_root/scripts/accept-edge.sh" "$kube_root/scripts/accept-powerdns.sh" \
    "$kube_root/scripts/accept-dragonfly.sh" "$kube_root/scripts/drill-cnpg-restore.sh" \
    "$kube_root/scripts/bootstrap-keycloak.sh" "$kube_root/scripts/accept-identity.sh" \
    "$kube_root/scripts/accept-observability.sh" "$kube_root/scripts/accept-ai.sh" \
    "$kube_root/scripts/configure-litellm.sh" "$kube_root/scripts/llmkube-mac.sh" \
    "$kube_root/scripts/host-firewall.sh" "$repository_root/scripts/provision-ai-secrets.sh"
python -m py_compile "$kube_root/scripts/dns_probe.py"
sh -n "$repository_root/scripts/llmkube-macos/sync" \
    "$repository_root/scripts/llmkube-macos/install-generation" \
    "$repository_root/scripts/llmkube-macos/switch-version" \
    "$repository_root/scripts/llmkube-macos/uninstall"
python -m py_compile "$kube_root/apps/ai/codex-adapter/app/checkpoint.py"

for root in "${roots[@]}"; do
    [[ -f "$kube_root/flux/$root/kustomization.yaml" ]] || {
        printf 'root allowlist is missing: %s\n' "$root" >&2
        exit 1
    }
    just --justfile "$repository_root/.justfile" kube render-root "$root" >/dev/null
    printf 'rendered root: %s\n' "$root"
done

python3 "$test_dir/validate_contracts.py" "$repository_root"
"$test_dir/cilium-bgp/validate.sh"

printf 'Kubernetes and Flux repository contracts passed\n'
