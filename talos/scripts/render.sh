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
[[ "$action" == "render" || "$action" == "apply-node" || "$action" == "verify-node" ]] || {
    echo "usage: render.sh render|apply-node|verify-node bsd-k8s-0N" >&2
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

verify_maintenance_target() {
    local bootstrap disks links time_status install_model install_wwid install_bus install_size
    local localpv_match localpv_serial osd_serial tor1 tor2
    bootstrap="$(jq -er --arg hostname "$hostname" \
        '.topology.nodes[] | select(.hostname == $hostname) | .bootstrap_address' "$context_file")"
    install_model="$(jq -er --arg hostname "$hostname" \
        '.topology.nodes[] | select(.hostname == $hostname) | .install_disk.model' "$context_file")"
    install_wwid="$(jq -er --arg hostname "$hostname" \
        '.topology.nodes[] | select(.hostname == $hostname) | .install_disk.wwid' "$context_file")"
    install_bus="$(jq -er --arg hostname "$hostname" \
        '.topology.nodes[] | select(.hostname == $hostname) | .install_disk.bus_path' "$context_file")"
    install_size="$(jq -er --arg hostname "$hostname" \
        '.topology.nodes[] | select(.hostname == $hostname) | .install_disk.size_bytes' "$context_file")"
    localpv_match="$(jq -er --arg hostname "$hostname" \
        '.topology.nodes[] | select(.hostname == $hostname) | .localpv_disk.match' "$context_file")"
    localpv_serial="${localpv_match##*disk.serial == \"}"
    localpv_serial="${localpv_serial%%\"*}"
    osd_serial="$(jq -er --arg hostname "$hostname" \
        '.topology.nodes[] | select(.hostname == $hostname) | .future_osd.serial' "$context_file")"
    tor1="$(jq -er --arg hostname "$hostname" \
        '.topology.nodes[] | select(.hostname == $hostname) | .links.tor1.permanent_mac' "$context_file")"
    tor2="$(jq -er --arg hostname "$hostname" \
        '.topology.nodes[] | select(.hostname == $hostname) | .links.tor2.permanent_mac' "$context_file")"
    disks="$(talosctl --nodes "$bootstrap" get disks --insecure --output yaml)"
    links="$(talosctl --nodes "$bootstrap" get linkstatus --insecure --output yaml)"
    time_status="$(talosctl --nodes "$bootstrap" get timestatus --insecure --output yaml)"
    [[ "$disks" == *"$install_model"* && "$disks" == *"$install_wwid"* &&
        "$disks" == *"$install_bus"* && "$disks" == *"$install_size"* &&
        "$disks" == *"$localpv_serial"* && "$disks" == *"$osd_serial"* ]] || {
        echo "$hostname: live protected disk identities changed before apply" >&2
        return 1
    }
    [[ "$links" == *"$tor1"* && "$links" == *"$tor2"* &&
        "$links" == *"speedMbit: 10000"* && "$time_status" == *"synced: true"* ]] || {
        echo "$hostname: live X710 or NTP gate failed before apply" >&2
        return 1
    }
}

verify_node() {
    local address bootstrap expected_version links routes addresses extensions modules volumes params watchdog disks
    local localpv_match localpv_serial osd_serial ready=false
    address="$(jq -er --arg hostname "$hostname" \
        '.topology.nodes[] | select(.hostname == $hostname) | .address' "$context_file")"
    bootstrap="$(jq -er --arg hostname "$hostname" \
        '.topology.nodes[] | select(.hostname == $hostname) | .bootstrap_address' "$context_file")"
    expected_version="$(jq -er '.topology.versions.talos' "$context_file")"
    for _ in {1..60}; do
        if talosctl --talosconfig "$runtime_dir/talosconfig" --nodes "$address" version \
            >"$runtime_dir/server-version.txt" 2>/dev/null; then
            ready=true
            break
        fi
        sleep 5
    done
    [[ "$ready" == true ]] || {
        echo "$hostname: permanent Talos API did not become ready" >&2
        return 1
    }
    [[ "$(<"$runtime_dir/server-version.txt")" == *"$expected_version"* ]] || {
        echo "$hostname: installed Talos version differs from protected topology" >&2
        return 1
    }
    links="$(talosctl --talosconfig "$runtime_dir/talosconfig" --nodes "$address" get linkstatus --output yaml)"
    routes="$(talosctl --talosconfig "$runtime_dir/talosconfig" --nodes "$address" get routestatus --output yaml)"
    addresses="$(talosctl --talosconfig "$runtime_dir/talosconfig" --nodes "$address" get addressstatus --output yaml)"
    extensions="$(talosctl --talosconfig "$runtime_dir/talosconfig" --nodes "$address" get extensionstatus --output yaml)"
    modules="$(talosctl --talosconfig "$runtime_dir/talosconfig" --nodes "$address" get loadedkernelmodules --output yaml)"
    volumes="$(talosctl --talosconfig "$runtime_dir/talosconfig" --nodes "$address" get volumestatus --output yaml)"
    params="$(talosctl --talosconfig "$runtime_dir/talosconfig" --nodes "$address" get kernelparams --output yaml)"
    watchdog="$(talosctl --talosconfig "$runtime_dir/talosconfig" --nodes "$address" get watchdogtimerstatus --output yaml)"
    disks="$(talosctl --talosconfig "$runtime_dir/talosconfig" --nodes "$address" get disks --output yaml)"
    [[ "$links" == *"id: bond0"* && "$links" == *"mtu: 1496"* &&
        "$links" == *"speedMbit: 10000"* ]] || {
        echo "$hostname: bond or X710 link state differs from the reviewed contract" >&2
        return 1
    }
    [[ "$routes" == *"gateway: 10.25.11.1"* && "$routes" == *"outLinkName: bond0"* ]] || {
        echo "$hostname: permanent default route is absent from bond0" >&2
        return 1
    }
    [[ "$addresses" == *"address: $address/24"* && "$addresses" == *"address: $bootstrap/24"* &&
        ! "$addresses" =~ address:\ 10[.]25[.]11[.]2[0-5][0-9]/24 ]] || {
        echo "$hostname: static permanent/bootstrap addresses or DHCP exclusion failed" >&2
        return 1
    }
    [[ "$extensions" == *"intel-ucode"* && "$extensions" == *"i915"* &&
        "$extensions" == *"nfsrahead"* && "$extensions" != *"iscsi"* ]] || {
        echo "$hostname: installed schematic extensions differ from the reviewed set" >&2
        return 1
    }
    [[ "$modules" == *"id: i915"* && "$volumes" == *"id: local-hostpath"* &&
        "$params" == *"id: proc.sys.user.max_user_namespaces"* &&
        "$params" == *'current: "11255"'* && "$watchdog" == *"/dev/watchdog0"* ]] || {
        echo "$hostname: iGPU, LocalPV, user namespace, or watchdog proof failed" >&2
        return 1
    }
    localpv_match="$(jq -er --arg hostname "$hostname" \
        '.topology.nodes[] | select(.hostname == $hostname) | .localpv_disk.match' "$context_file")"
    localpv_serial="${localpv_match##*disk.serial == \"}"
    localpv_serial="${localpv_serial%%\"*}"
    osd_serial="$(jq -er --arg hostname "$hostname" \
        '.topology.nodes[] | select(.hostname == $hostname) | .future_osd.serial' "$context_file")"
    [[ "$disks" == *"$localpv_serial"* && "$disks" == *"$osd_serial"* ]] || {
        echo "$hostname: LocalPV or raw future OSD disappeared after installation" >&2
        return 1
    }
    printf '{"hostname":"%s","permanent_api":"ready","network":"verified","hardware":"verified"}\n' \
        "$hostname"
}

if [[ "$action" == "apply-node" ]]; then
    verify_maintenance_target
    bootstrap_target="$(jq -er --arg hostname "$hostname" \
        '.topology.nodes[] | select(.hostname == $hostname) | .bootstrap_address' "$context_file")"
    talosctl --nodes "$bootstrap_target" apply-config --insecure \
        --file "$runtime_dir/$hostname.yaml"
    verify_node
elif [[ "$action" == "verify-node" ]]; then
    verify_node
fi
