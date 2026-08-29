#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
talos_dir="$repo_dir/talos"
cd "$repo_dir"
for tool in jq minijinja-cli python talosctl yq; do
    command -v "$tool" >/dev/null 2>&1 || {
        echo "missing locked tool: $tool" >&2
        exit 1
    }
done

umask 077
runtime_dir="$(mktemp -d "${TMPDIR:-/tmp}/talos-test.XXXXXX")"
[[ -d "$runtime_dir" && ! -L "$runtime_dir" && "$runtime_dir" == *talos-test.* ]] || {
    echo "failed to create safe Talos test directory" >&2
    exit 1
}
cleanup() {
    chmod -R u=rwX,go= "$runtime_dir" 2>/dev/null || true
    rm -rf -- "$runtime_dir"
}
trap cleanup EXIT
trap 'exit 130' HUP INT TERM
mkdir "$runtime_dir/first" "$runtime_dir/second" "$runtime_dir/talosconfig"
chmod 0700 "$runtime_dir/first" "$runtime_dir/second" "$runtime_dir/talosconfig"

talosctl gen secrets --output-file "$runtime_dir/secrets.yaml"
yq -o=json '.' "$talos_dir/tests/topology.yml" > "$runtime_dir/topology.json"
yq -o=json '.' "$runtime_dir/secrets.yaml" > "$runtime_dir/secrets.json"
jq -n \
    --slurpfile topology "$runtime_dir/topology.json" \
    --slurpfile secrets "$runtime_dir/secrets.json" \
    '{topology: $topology[0], secrets: $secrets[0]}' > "$runtime_dir/context.json"
chmod 0600 "$runtime_dir"/*.{json,yaml}

mapfile -t hostnames < <(jq -er '.nodes[].hostname' "$runtime_dir/topology.json")
for output in first second; do
    for hostname in "${hostnames[@]}"; do
        python "$talos_dir/scripts/render.py" \
            --context "$runtime_dir/context.json" \
            --hostname "$hostname" \
            --output-dir "$runtime_dir/$output" \
            --template-dir "$talos_dir" \
            --allow-synthetic \
            --skip-talosconfig >/dev/null
    done
done
python "$talos_dir/tests/test_render.py" \
    --first "$runtime_dir/first" \
    --second "$runtime_dir/second" \
    --fixture "$talos_dir/tests/topology.yml" \
    --talos-dir "$talos_dir"

python "$talos_dir/scripts/render.py" \
    --context "$runtime_dir/context.json" \
    --hostname "${hostnames[0]}" \
    --output-dir "$runtime_dir/talosconfig" \
    --template-dir "$talos_dir" \
    --allow-synthetic >/dev/null
[[ -f "$runtime_dir/talosconfig/talosconfig" &&
    "$(stat -f '%Lp' "$runtime_dir/talosconfig/talosconfig")" == "600" ]] || {
    echo "Talos renderer did not produce a mode-0600 talosconfig" >&2
    exit 1
}
jq -e --slurpfile topology "$runtime_dir/topology.json" '
    .context == "synthetic-bsd" and
    .contexts[.context].endpoints ==
        [$topology[0].nodes[] | select(.role == "controlplane") | .bootstrap_address] and
    .contexts[.context].nodes == [$topology[0].nodes[0].bootstrap_address]
' < <(yq -o=json '.' "$runtime_dir/talosconfig/talosconfig") >/dev/null
"$talos_dir/tests/test_apply.sh"
