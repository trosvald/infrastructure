#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_dir"

expected_addr="https://vault.monosense.io:8200"
export BAO_ADDR="${BAO_ADDR:-$expected_addr}"
[[ "$BAO_ADDR" == "$expected_addr" ]] || {
    echo "Talos record provisioning requires $expected_addr" >&2
    exit 1
}
[[ -z "${BAO_SKIP_VERIFY:-}" && -z "${VAULT_SKIP_VERIFY:-}" ]] || {
    echo "Talos record provisioning rejects TLS verification bypasses" >&2
    exit 1
}
[[ -z "${BAO_TLS_SERVER_NAME:-}" && -z "${VAULT_TLS_SERVER_NAME:-}" ]] || {
    echo "Talos record provisioning rejects TLS server-name overrides" >&2
    exit 1
}

for tool in bao jq openssl python shasum talosctl yq; do
    command -v "$tool" >/dev/null 2>&1 || {
        echo "missing locked tool: $tool" >&2
        exit 1
    }
done
[[ "$(talosctl version --client --short | tr -d '\r')" == $'Client:\nTalos v1.14.0-rc.2' ]] || {
    echo "Talos secrets require locked talosctl v1.14.0-rc.2" >&2
    exit 1
}

inventory_dir="$repo_dir/.private/talos"
decisions="$inventory_dir/provisioning.json"
[[ -d "$inventory_dir" && ! -L "$inventory_dir" && -f "$decisions" && ! -L "$decisions" ]] || {
    echo "protected Talos inventory or provisioning decisions are unavailable" >&2
    exit 1
}
decision_mode="$(stat -f '%Lp' "$decisions" 2>/dev/null || stat -c '%a' "$decisions")"
[[ "$decision_mode" == "600" ]] || {
    echo "protected Talos provisioning decisions must have mode 0600" >&2
    exit 1
}

bao token lookup >/dev/null || {
    echo "authenticate an OpenBao administrator with: just openbao-admin-login" >&2
    exit 1
}

paths=(
    network/bgp/cilium-srx1500
    platform/talos/bsd/topology
    platform/talos/bsd/secrets
)
for path in "${paths[@]}"; do
    capabilities="$(bao token capabilities "kv/data/$path" | tr -d ' ')"
    if [[ "$capabilities" != "root" ]]; then
        for required in create read update; do
            [[ ",$capabilities," == *",$required,"* ]] || {
                echo "administrator token lacks $required on one required Talos record" >&2
                exit 1
            }
        done
    fi
done

umask 077
runtime_dir="$(mktemp -d "${TMPDIR:-/tmp}/talos-record-provision.XXXXXX")"
[[ -d "$runtime_dir" && ! -L "$runtime_dir" && "$runtime_dir" == *talos-record-provision.* ]] || {
    echo "failed to create protected Talos provisioning directory" >&2
    exit 1
}
chmod 0700 "$runtime_dir"
cleanup() {
    local status=$?
    rm -rf "$runtime_dir"
    trap - EXIT HUP INT TERM
    exit "$status"
}
trap cleanup EXIT
trap 'exit 130' HUP INT TERM

topology="$runtime_dir/topology.json"
secrets="$runtime_dir/secrets.json"
bgp="$runtime_dir/bgp.json"
python talos/scripts/build_topology.py \
    --inventory-dir "$inventory_dir" \
    --decisions "$decisions" \
    --validator talos/scripts/render.py \
    --output "$topology"
chmod 0600 "$topology"

fetch_record() {
    local path=$1
    local destination=$2
    local response="$runtime_dir/$(printf '%s' "$path" | tr '/' '-').response.json"
    local error="$response.error"
    if bao kv get -mount=kv -format=json "$path" > "$response" 2> "$error"; then
        chmod 0600 "$response"
        jq -e '.data.data | type == "object"' "$response" >/dev/null || {
            echo "existing OpenBao record has an invalid envelope" >&2
            exit 1
        }
        jq -c '.data.data' "$response" > "$destination"
        chmod 0600 "$destination"
        return 0
    fi
    local message
    message="$(<"$error")"
    if [[ "$message" == *"No value found at"* ]]; then
        return 1
    fi
    echo "failed to inspect required OpenBao record" >&2
    exit 1
}

bgp_exists=false
topology_exists=false
secrets_exists=false
if fetch_record "${paths[0]}" "$bgp"; then bgp_exists=true; fi
existing_topology="$runtime_dir/existing-topology.json"
if fetch_record "${paths[1]}" "$existing_topology"; then topology_exists=true; fi
if fetch_record "${paths[2]}" "$secrets"; then secrets_exists=true; fi

if [[ "$topology_exists" == true ]]; then
    jq -e --slurpfile expected "$topology" '. == $expected[0]' "$existing_topology" >/dev/null || {
        echo "existing Talos topology differs; overwrite requires a separate reviewed change" >&2
        exit 1
    }
fi
if [[ "$bgp_exists" == true ]]; then
    jq -e 'type == "object" and keys == ["password"] and (.password | type == "string" and length == 43 and test("^[A-Za-z0-9_-]{43}$"))' "$bgp" >/dev/null || {
        echo "existing Cilium BGP record has an invalid schema" >&2
        exit 1
    }
else
    openssl rand 32 | openssl base64 -A | tr '+/' '-_' | tr -d '=' | jq -Rn '{password: input}' > "$bgp"
    chmod 0600 "$bgp"
    jq -e '.password | length == 43 and test("^[A-Za-z0-9_-]{43}$")' "$bgp" >/dev/null
fi

if [[ "$secrets_exists" == false ]]; then
    secrets_yaml="$runtime_dir/secrets.yaml"
    talosctl gen secrets --talos-version v1.14.0-rc.2 --output-file "$secrets_yaml"
    chmod 0600 "$secrets_yaml"
    yq -o=json -I=0 '.' "$secrets_yaml" > "$secrets"
    chmod 0600 "$secrets"
fi

python talos/scripts/build_topology.py \
    --inventory-dir "$inventory_dir" \
    --decisions "$decisions" \
    --validator talos/scripts/render.py \
    --secrets "$secrets" \
    --output "$topology"

if [[ "$secrets_exists" == false ]]; then
    bao kv put -mount=kv -cas=0 "${paths[2]}" "@$secrets" >/dev/null
fi
if [[ "$bgp_exists" == false ]]; then
    bao kv put -mount=kv -cas=0 "${paths[0]}" "@$bgp" >/dev/null
fi
if [[ "$topology_exists" == false ]]; then
    bao kv put -mount=kv -cas=0 "${paths[1]}" "@$topology" >/dev/null
fi

fetch_record "${paths[0]}" "$bgp"
fetch_record "${paths[1]}" "$existing_topology"
fetch_record "${paths[2]}" "$secrets"
jq -e --slurpfile expected "$topology" '. == $expected[0]' "$existing_topology" >/dev/null
jq -e 'type == "object" and keys == ["password"] and (.password | length == 43 and test("^[A-Za-z0-9_-]{43}$"))' "$bgp" >/dev/null
python talos/scripts/build_topology.py \
    --inventory-dir "$inventory_dir" \
    --decisions "$decisions" \
    --validator talos/scripts/render.py \
    --secrets "$secrets" \
    --output "$topology"

topology_digest="$(shasum -a 256 "$topology" | cut -d' ' -f1)"
secrets_digest="$(shasum -a 256 "$secrets" | cut -d' ' -f1)"
printf 'OpenBao Talos records valid; topology_sha256=%s secrets_sha256=%s\n' "$topology_digest" "$secrets_digest"
