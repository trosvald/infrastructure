#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$repo_dir"
for tool in jq python shasum yq; do
    command -v "$tool" >/dev/null 2>&1 || {
        echo "missing locked tool: $tool" >&2
        exit 1
    }
done

inventory_dir="$repo_dir/.private/talos"
decisions="$inventory_dir/provisioning.json"
[[ -d "$inventory_dir" && ! -L "$inventory_dir" && -f "$decisions" && ! -L "$decisions" ]] || {
    echo "protected Talos inventory or provisioning decisions are unavailable" >&2
    exit 1
}

umask 077
runtime_dir="$(mktemp -d "${TMPDIR:-/tmp}/talos-inventory-validate.XXXXXX")"
cleanup() {
    local status=$?
    rm -rf "$runtime_dir"
    trap - EXIT HUP INT TERM
    exit "$status"
}
trap cleanup EXIT
trap 'exit 130' HUP INT TERM
chmod 0700 "$runtime_dir"
topology="$runtime_dir/topology.json"
python talos/scripts/build_topology.py \
    --inventory-dir "$inventory_dir" \
    --decisions "$decisions" \
    --validator talos/scripts/render.py \
    --output "$topology"
chmod 0600 "$topology"
node_count="$(jq -er '.nodes | length' "$topology")"
digest="$(shasum -a 256 "$topology" | cut -d' ' -f1)"
printf 'Protected %s-node Talos inventory valid; topology_sha256=%s\n' "$node_count" "$digest"
