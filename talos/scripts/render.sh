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
case "$action" in
    render|apply-node|verify-node|backup-storage-network|apply-storage-network)
        [[ "$hostname" =~ ^bsd-k8s-[0-9]{2,}$ && $# -eq 2 ]] || {
            echo "Talos action requires exactly one bsd-k8s-NN hostname" >&2
            exit 2
        }
        ;;
    *)
        echo "usage: render.sh render|apply-node|verify-node|backup-storage-network|apply-storage-network bsd-k8s-NN" >&2
        exit 2
        ;;
esac

if [[ "$authenticated" == false ]]; then
    exec "$repo_dir/scripts/with-openbao-runtime.sh" \
        talos/scripts/render.sh --authenticated "$@"
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
talosconfig="$runtime_dir/talosconfig"

node_field() {
    local node_hostname="$1" expression="$2"
    jq -er --arg hostname "$node_hostname" \
        '.topology.nodes[] | select(.hostname == $hostname) | '"$expression" "$context_file"
}

verify_maintenance_target() {
    local node_hostname="$1"
    local bootstrap disks links time_status install_model install_wwid install_bus_prefix install_size
    local localpv_match localpv_serial osd_serial tor1 tor2
    bootstrap="$(node_field "$node_hostname" '.bootstrap_address')"
    install_model="$(node_field "$node_hostname" '.install_disk.model')"
    install_wwid="$(node_field "$node_hostname" '.install_disk.wwid')"
    install_bus_prefix="$(node_field "$node_hostname" '.install_disk.bus_path_prefix')"
    install_size="$(node_field "$node_hostname" '.install_disk.size_bytes')"
    localpv_match="$(node_field "$node_hostname" '.localpv_disk.match')"
    localpv_serial="${localpv_match##*disk.serial == \"}"
    localpv_serial="${localpv_serial%%\"*}"
    osd_serial="$(node_field "$node_hostname" '.future_osd.serial')"
    tor1="$(node_field "$node_hostname" '.links.tor1.permanent_mac')"
    tor2="$(node_field "$node_hostname" '.links.tor2.permanent_mac')"
    disks="$(talosctl --nodes "$bootstrap" get disks --insecure --output yaml)"
    links="$(talosctl --nodes "$bootstrap" get linkstatus --insecure --output yaml)"
    time_status="$(talosctl --nodes "$bootstrap" get timestatus --insecure --output yaml)"
    [[ "$disks" == *"$install_model"* && "$disks" == *"$install_wwid"* &&
        "$disks" == *"$install_bus_prefix"* && "$disks" == *"$install_size"* &&
        "$disks" == *"$localpv_serial"* && "$disks" == *"$osd_serial"* ]] || {
        echo "$node_hostname: live protected disk identities changed before apply" >&2
        return 1
    }
    [[ "$links" == *"$tor1"* && "$links" == *"$tor2"* &&
        "$links" == *"speedMbit: 10000"* && "$time_status" == *"synced: true"* ]] || {
        echo "$node_hostname: live X710 or NTP gate failed before apply" >&2
        return 1
    }
}

wait_talos_api() {
    local management_target="$1" ready=false
    for _ in {1..60}; do
        if talosctl --talosconfig "$talosconfig" --nodes "$management_target" version >/dev/null 2>&1; then
            ready=true
            break
        fi
        sleep 5
    done
    [[ "$ready" == true ]]
}

verify_node() {
    local node_hostname="$1"
    local address storage_address bootstrap expected_version expected_schematic links routes addresses extensions modules
    local volumes params watchdog disks localpv_match localpv_serial osd_serial install_model
    local install_wwid install_bus_prefix install_size tor1 tor2 extension_count ready=false
    address="$(node_field "$node_hostname" '.address')"
    storage_address="$(node_field "$node_hostname" '.storage_address')"
    bootstrap="$(node_field "$node_hostname" '.bootstrap_address')"
    expected_version="$(jq -er '.topology.versions.talos' "$context_file")"
    expected_schematic="$(jq -er '.topology.versions.schematic' "$context_file")"
    for _ in {1..60}; do
        if talosctl --talosconfig "$talosconfig" --nodes "$bootstrap" version \
            >"$runtime_dir/server-version.txt" 2>/dev/null; then
            ready=true
            break
        fi
        sleep 5
    done
    [[ "$ready" == true ]] || {
        echo "$node_hostname: Talos management API did not become ready" >&2
        return 1
    }
    [[ "$(<"$runtime_dir/server-version.txt")" == *"$expected_version"* ]] || {
        echo "$node_hostname: installed Talos version differs from protected topology" >&2
        return 1
    }
    links="$(talosctl --talosconfig "$talosconfig" --nodes "$bootstrap" get linkstatus --output yaml)"
    routes="$(talosctl --talosconfig "$talosconfig" --nodes "$bootstrap" get routestatus --output yaml)"
    addresses="$(talosctl --talosconfig "$talosconfig" --nodes "$bootstrap" get addressstatus --output yaml)"
    extensions="$(talosctl --talosconfig "$talosconfig" --nodes "$bootstrap" get extensionstatus --output yaml)"
    modules="$(talosctl --talosconfig "$talosconfig" --nodes "$bootstrap" get loadedkernelmodules --output yaml)"
    volumes="$(talosctl --talosconfig "$talosconfig" --nodes "$bootstrap" get volumestatus --output yaml)"
    params="$(talosctl --talosconfig "$talosconfig" --nodes "$bootstrap" get kernelparams --output yaml)"
    watchdog="$(talosctl --talosconfig "$talosconfig" --nodes "$bootstrap" get watchdogtimerstatus --output yaml)"
    disks="$(talosctl --talosconfig "$talosconfig" --nodes "$bootstrap" get disks --output yaml)"
    tor1="$(node_field "$node_hostname" '.links.tor1.permanent_mac')"
    tor2="$(node_field "$node_hostname" '.links.tor2.permanent_mac')"
    [[ "$links" == *"id: bond0"* && "$links" == *"mtu: 1496"* &&
        "$links" == *"$tor1"* && "$links" == *"$tor2"* &&
        "$links" == *"speedMbit: 10000"* && "$links" == *"mode: active-backup"* ]] || {
        echo "$node_hostname: bond or X710 link state differs from the reviewed contract" >&2
        return 1
    }
    [[ "$routes" == *"gateway: 10.25.11.1"* && "$routes" == *"outLinkName: bond0"* &&
        "$routes" == *"priority: 1024"* ]] || {
        echo "$node_hostname: permanent default route is absent from bond0" >&2
        return 1
    }
    [[ "$addresses" == *"address: $address/24"* &&
        "$addresses" == *"address: $storage_address/24"* &&
        "$addresses" == *"address: $bootstrap/24"* &&
        ! "$addresses" =~ address:\ 10[.]25[.]11[.]2[0-5][0-9]/24 ]] || {
        echo "$node_hostname: static permanent/bootstrap/storage addresses or DHCP exclusion failed" >&2
        return 1
    }
    extension_count="$(python -c \
        'import sys; print(sys.stdin.read().count("type: ExtensionStatuses.runtime.talos.dev"))' \
        <<<"$extensions")"
    [[ "$extension_count" == 5 && "$extensions" == *"name: intel-ucode"* &&
        "$extensions" == *"name: i915"* && "$extensions" == *"name: nfsrahead"* &&
        "$extensions" == *"name: schematic"* && "$extensions" == *"name: modules.dep"* &&
        "$extensions" == *"$expected_schematic"* && "$extensions" != *"iscsi"* ]] || {
        echo "$node_hostname: installed schematic extensions differ from the reviewed set" >&2
        return 1
    }
    [[ "$modules" == *"id: i915"* && "$volumes" == *"id: u-local-hostpath"* &&
        "$params" == *"id: proc.sys.user.max_user_namespaces"* &&
        "$params" == *'current: "11255"'* && "$watchdog" == *"/dev/watchdog0"* ]] || {
        echo "$node_hostname: iGPU, LocalPV, user namespace, or watchdog proof failed" >&2
        return 1
    }
    localpv_match="$(node_field "$node_hostname" '.localpv_disk.match')"
    localpv_serial="${localpv_match##*disk.serial == \"}"
    localpv_serial="${localpv_serial%%\"*}"
    osd_serial="$(node_field "$node_hostname" '.future_osd.serial')"
    install_model="$(node_field "$node_hostname" '.install_disk.model')"
    install_wwid="$(node_field "$node_hostname" '.install_disk.wwid')"
    install_bus_prefix="$(node_field "$node_hostname" '.install_disk.bus_path_prefix')"
    install_size="$(node_field "$node_hostname" '.install_disk.size_bytes')"
    [[ "$disks" == *"$install_model"* && "$disks" == *"$install_wwid"* &&
        "$disks" == *"$install_bus_prefix"* && "$disks" == *"$install_size"* &&
        "$disks" == *"$localpv_serial"* && "$disks" == *"$osd_serial"* ]] || {
        echo "$node_hostname: protected install, LocalPV, or future OSD disk disappeared" >&2
        return 1
    }
    printf '{"hostname":"%s","management_api":"ready","network":"verified","hardware":"verified"}\n' \
        "$node_hostname"
}
wait_verified_node() {
    local node_hostname="$1" status_file error_file
    status_file="$runtime_dir/$node_hostname-verify.json"
    error_file="$runtime_dir/$node_hostname-verify.err"
    for _ in {1..60}; do
        if verify_node "$node_hostname" >"$status_file" 2>"$error_file"; then
            cat "$status_file"
            return
        fi
        sleep 5
    done
    cat "$error_file" >&2
    return 1
}


apply_one_node() {
    local node_hostname="$1" bootstrap config members_file anchor_hostname anchor_bootstrap
    bootstrap="$(node_field "$node_hostname" '.bootstrap_address')"
    config="$runtime_dir/$node_hostname.yaml"

    if talosctl --talosconfig "$talosconfig" --nodes "$bootstrap" version >/dev/null 2>&1; then
        wait_verified_node "$node_hostname" >/dev/null
        talosctl --talosconfig "$talosconfig" --nodes "$bootstrap" apply-config \
            --dry-run --mode=auto --file "$config" >/dev/null
        talosctl --talosconfig "$talosconfig" --nodes "$bootstrap" apply-config \
            --mode=auto --file "$config"
        wait_talos_api "$bootstrap" || {
            echo "$node_hostname: Talos management API did not remain ready after reconciliation" >&2
            return 1
        }
        wait_verified_node "$node_hostname" >/dev/null
        echo "$node_hostname: installed configuration reconciled and verified"
        return
    fi

    verify_maintenance_target "$node_hostname"
    members_file="$runtime_dir/etcd-members.txt"
    anchor_hostname="$(jq -er \
        'first(.topology.nodes[] | select(.role == "controlplane") | .hostname)' \
        "$context_file")"
    anchor_bootstrap="$(node_field "$anchor_hostname" '.bootstrap_address')"
    if talosctl --talosconfig "$talosconfig" --nodes "$anchor_bootstrap" get etcdmembers \
        --output yaml >"$members_file" 2>/dev/null && [[ -s "$members_file" ]]; then
        echo "Talos initial apply refuses an already bootstrapped etcd cluster" >&2
        return 1
    fi

    talosctl --nodes "$bootstrap" apply-config --insecure --mode=auto --file "$config"
    wait_talos_api "$bootstrap" || {
        echo "$node_hostname: Talos management API did not become ready" >&2
        return 1
    }
    wait_verified_node "$node_hostname" >/dev/null
    talosctl --talosconfig "$talosconfig" --nodes "$bootstrap" reboot --wait=false
    wait_talos_api "$bootstrap" || {
        echo "$node_hostname: Talos management API did not return after reboot" >&2
        return 1
    }
    wait_verified_node "$node_hostname" >/dev/null


    echo "$node_hostname: configuration applied and reboot persistence verified"
}
backup_storage_network() {
    local node_hostname="$1" bootstrap backup_dir backup temporary digest
    command -v yq >/dev/null 2>&1 || {
        echo "missing locked tool: yq" >&2
        return 1
    }
    python "$talos_dir/scripts/validate_storage_network.py" --inventory-only >/dev/null
    bootstrap="$(node_field "$node_hostname" '.bootstrap_address')"
    backup_dir="$repo_dir/.private/talos-pre-storage"
    [[ ! -L "$repo_dir/.private" && ! -L "$backup_dir" ]] || {
        echo "Talos pre-storage backup path is unsafe" >&2
        return 1
    }
    mkdir -p "$backup_dir"
    chmod 0700 "$backup_dir"
    backup="$backup_dir/$node_hostname.yaml"
    [[ ! -e "$backup" ]] || {
        echo "$backup already exists; refusing to replace reviewed rollback state" >&2
        return 1
    }
    temporary="$backup.tmp"
    talosctl --talosconfig "$talosconfig" --nodes "$bootstrap" \
        get machineconfig v1alpha1 --output yaml | yq -e '.spec' > "$temporary"
    chmod 0600 "$temporary"
    ! grep -Eq 'bond0[.]2514|vlanID:[[:space:]]*2514' "$temporary" || {
        rm -f "$temporary"
        echo "$node_hostname already contains VLAN 2514; refusing a post-change backup" >&2
        return 1
    }
    mv "$temporary" "$backup"
    digest="$(python -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1], \"rb\").read()).hexdigest())' "$backup")"
    printf '%s: review %s, then write only this digest to %s.reviewed\n' \
        "$node_hostname" "$backup" "$backup" >&2
    printf '%s\n' "$digest"
}
apply_storage_network() {
    local node_hostname="$1" bootstrap config backup review digest
    command -v kubectl >/dev/null 2>&1 || {
        echo "missing locked tool: kubectl" >&2
        return 1
    }
    python "$talos_dir/scripts/validate_storage_network.py" --inventory-only >/dev/null
    bootstrap="$(node_field "$node_hostname" '.bootstrap_address')"
    config="$runtime_dir/$node_hostname.yaml"
    backup="$repo_dir/.private/talos-pre-storage/$node_hostname.yaml"
    review="$backup.reviewed"
    [[ -f "$backup" && ! -L "$backup" && -f "$review" && ! -L "$review" ]] || {
        echo "$node_hostname: reviewed pre-storage Talos backup is absent or unsafe" >&2
        return 1
    }
    digest="$(python -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1], \"rb\").read()).hexdigest())' "$backup")"
    [[ "$(<"$review")" == "$digest" ]] || {
        echo "$node_hostname: backup review digest does not match rollback content" >&2
        return 1
    }
    kubectl get nodes -o json | jq -e '
        ([.items[].metadata.name] | sort) ==
            [\"bsd-k8s-01\", \"bsd-k8s-02\", \"bsd-k8s-03\", \"bsd-k8s-04\", \"bsd-k8s-05\"] and
        all(.items[]; any(.status.conditions[];
            .type == \"Ready\" and .status == \"True\"))
    ' >/dev/null || {
        echo "all five Talos nodes must be Ready before one-node storage rollout" >&2
        return 1
    }
    if ! talosctl --talosconfig "$talosconfig" --nodes "$bootstrap" \
        apply-config --mode=reboot --file "$config"; then
        echo "$node_hostname: storage config apply failed before health proof" >&2
        return 1
    fi
    if ! wait_talos_api "$bootstrap" || ! wait_verified_node "$node_hostname" >/dev/null ||
        ! kubectl wait --for=condition=Ready "node/$node_hostname" --timeout=10m; then
        echo "$node_hostname: health failed; restoring reviewed pre-storage config" >&2
        talosctl --talosconfig "$talosconfig" --nodes "$bootstrap" \
            apply-config --mode=reboot --file "$backup" || true
        wait_talos_api "$bootstrap" || true
        return 1
    fi
    echo "$node_hostname: VLAN 2514 applied; node and cluster readiness verified"
}

case "$action" in
    apply-node)
        apply_one_node "$hostname"
        ;;
    verify-node)
        wait_verified_node "$hostname"
        ;;
    backup-storage-network)
        backup_storage_network "$hostname"
        ;;
    apply-storage-network)
        apply_storage_network "$hostname"
        ;;
esac
