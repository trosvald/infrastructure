#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
talos_dir="$repo_dir/talos"
cd "$repo_dir"

authenticated=false
if [[ "${1:-}" == "--authenticated" ]]; then
    authenticated=true
    shift
fi
action="${1:-}"
hostname="${2:-}"
[[ "$action" == "render" || "$action" == "apply-node" ]] || {
    echo "usage: render.sh render|apply-node bsd-k8s-0N" >&2
    exit 2
}
[[ "$hostname" =~ ^bsd-k8s-0[1-5]$ && $# -eq 2 ]] || {
    echo "Talos action requires exactly one known hostname" >&2
    exit 2
}

if [[ "$authenticated" == false ]]; then
    exec "$repo_dir/scripts/with-openbao-runtime.sh" \
        talos/scripts/render.sh --authenticated "$action" "$hostname"
fi

[[ -n "${OPENBAO_RUNTIME_DIR:-}" && -d "$OPENBAO_RUNTIME_DIR" &&
    ! -L "$OPENBAO_RUNTIME_DIR" && -n "${BAO_TOKEN:-}" ]] || {
    echo "Talos rendering requires the authenticated repository OpenBao runtime" >&2
    exit 1
}
for tool in bao jq minijinja-cli python talosctl; do
    command -v "$tool" >/dev/null 2>&1 || {
        echo "missing locked tool: $tool" >&2
        exit 1
    }
done

runtime_dir="$OPENBAO_RUNTIME_DIR/talos"
mkdir "$runtime_dir"
chmod 0700 "$runtime_dir"
topology_raw="$runtime_dir/topology-response.json"
secrets_raw="$runtime_dir/secrets-response.json"
context_file="$runtime_dir/context-source.json"
bao kv get -mount=kv -format=json platform/talos/bsd/topology > "$topology_raw"
bao kv get -mount=kv -format=json platform/talos/bsd/secrets > "$secrets_raw"
chmod 0600 "$topology_raw" "$secrets_raw"
jq -e '.data.data | type == "object"' "$topology_raw" >/dev/null || {
    echo "OpenBao Talos topology record must contain one object" >&2
    exit 1
}
jq -e '.data.data | type == "object"' "$secrets_raw" >/dev/null || {
    echo "OpenBao Talos secrets record must contain one object" >&2
    exit 1
}
jq -n --slurpfile topology "$topology_raw" --slurpfile secrets "$secrets_raw" \
    '{topology: $topology[0].data.data, secrets: $secrets[0].data.data}' > "$context_file"
chmod 0600 "$context_file"

metadata="$(python "$talos_dir/scripts/render.py" \
    --context "$context_file" \
    --hostname "$hostname" \
    --output-dir "$runtime_dir" \
    --template-dir "$talos_dir")"
printf '%s\n' "$metadata"

if [[ "$action" == "apply-node" ]]; then
    talosctl --nodes "$hostname" apply-config --file "$runtime_dir/$hostname.yaml"
fi
