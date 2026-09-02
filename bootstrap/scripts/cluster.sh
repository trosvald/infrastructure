#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
bootstrap_dir="$repo_dir/bootstrap"
cd "$repo_dir"

stages=(preflight nodes kubernetes kubeconfig-node cilium bgp api-vip kubeconfig-cilium coredns flux verify)
network_stages=(nodes kubernetes kubeconfig-node cilium bgp api-vip kubeconfig-cilium coredns)
authenticated=false
if [[ "${1:-}" == "--authenticated" ]]; then
    authenticated=true
    shift
fi
requested_stage="${1:-all}"
[[ $# -le 1 ]] || { echo "bootstrap accepts at most one fixed stage" >&2; exit 2; }
case "$requested_stage" in
    all|preflight|network|flux|verify) ;;
    *) echo "unknown bootstrap boundary: $requested_stage" >&2; exit 2 ;;
esac

if [[ "$authenticated" == false ]]; then
    exec "$repo_dir/scripts/with-openbao-runtime.sh" \
        bootstrap/scripts/cluster.sh --authenticated "$requested_stage"
fi
[[ -n "${OPENBAO_RUNTIME_DIR:-}" && -d "$OPENBAO_RUNTIME_DIR" &&
    ! -L "$OPENBAO_RUNTIME_DIR" && -n "${BAO_TOKEN:-}" ]] || {
    echo "bootstrap requires the authenticated repository OpenBao runtime" >&2
    exit 1
}

for tool in age ansible-playbook bao helm helmfile jq kubectl kustomize minijinja-cli python talosctl yq; do
    command -v "$tool" >/dev/null 2>&1 || {
        echo "missing locked bootstrap tool: $tool" >&2
        exit 1
    }
done

umask 077
runtime_dir="$OPENBAO_RUNTIME_DIR/bootstrap"
mkdir -p "$runtime_dir/nodes"
chmod 0700 "$runtime_dir" "$runtime_dir/nodes"
state_dir="$repo_dir/.build/bootstrap"
mkdir -p "$state_dir"
chmod 0700 "$repo_dir/.build" "$state_dir"
state_file="$state_dir/state.json"
if [[ ! -e "$state_file" ]]; then
    printf '{"completed":[]}\n' > "$state_file"
    chmod 0600 "$state_file"
fi
[[ -f "$state_file" && ! -L "$state_file" ]] || {
    echo "bootstrap state file is unsafe" >&2
    exit 1
}

retry() {
    local attempts="$1" delay="$2"
    shift 2
    local count
    for ((count = 1; count <= attempts; count++)); do
        if "$@"; then
            return 0
        fi
        if ((count < attempts)); then
            sleep "$delay"
        fi
    done
    return 1
}

stage_complete() {
    jq -e --arg stage "$1" '.completed | index($stage) != null' "$state_file" >/dev/null
}

mark_complete() {
    local stage="$1" temporary="$state_file.tmp"
    jq --arg stage "$stage" '.completed += [$stage] | .completed |= unique' \
        "$state_file" > "$temporary"
    chmod 0600 "$temporary"
    mv "$temporary" "$state_file"
}

topology_raw="$runtime_dir/topology-response.json"
secrets_raw="$runtime_dir/secrets-response.json"
bgp_raw="$runtime_dir/bgp-response.json"
context_file="$runtime_dir/context.json"
bao kv get -mount=kv -format=json platform/talos/bsd/topology > "$topology_raw"
bao kv get -mount=kv -format=json platform/talos/bsd/secrets > "$secrets_raw"
bao kv get -mount=kv -format=json network/bgp/cilium-srx1500 > "$bgp_raw"
chmod 0600 "$topology_raw" "$secrets_raw" "$bgp_raw"
jq -e '.data.data | type == "object"' "$topology_raw" >/dev/null
jq -e '.data.data | type == "object"' "$secrets_raw" >/dev/null
jq -e '
    (.data.data | keys) ==
        ["password_01", "password_02", "password_03", "password_04", "password_05"] and
    ([.data.data[] |
        type == "string" and length == 43 and test("^[A-Za-z0-9_-]+$")] | all) and
    ([.data.data[]] | unique | length) == 5
' "$bgp_raw" >/dev/null || {
    echo "Cilium BGP record must contain five unique per-node password fields" >&2
    exit 1
}
jq -n --slurpfile topology "$topology_raw" --slurpfile secrets "$secrets_raw" \
    '{topology: $topology[0].data.data, secrets: $secrets[0].data.data}' > "$context_file"
chmod 0600 "$context_file"

for index in 01 02 03 04 05; do
    node_dir="$runtime_dir/nodes/bsd-k8s-$index"
    mkdir -p "$node_dir"
    chmod 0700 "$node_dir"
    render_args=(
        --context "$context_file"
        --hostname "bsd-k8s-$index"
        --output-dir "$node_dir"
        --template-dir "$repo_dir/talos"
    )
    if [[ "$index" != 01 ]]; then
        render_args+=(--skip-talosconfig)
    fi
    python "$repo_dir/talos/scripts/render.py" "${render_args[@]}" >/dev/null
done

talosconfig="$runtime_dir/nodes/bsd-k8s-01/talosconfig"
kubeconfig="$runtime_dir/kubeconfig"
export KUBECONFIG="$kubeconfig"
acceptance_active=false
cleanup_acceptance_service() {
    if [[ "$acceptance_active" == true && -f "$kubeconfig" ]]; then
        for index in 01 02 03 04 05; do
            set_bgp_label "bsd-k8s-$index" present >/dev/null 2>&1 || true
        done
        kubectl --kubeconfig "$kubeconfig" apply --server-side \
            --field-manager=bootstrap-cilium-config \
            -f "$repo_dir/kubernetes/apps/kube-system/cilium/config/clusters.yaml" \
            >/dev/null 2>&1 || true
    fi
    if [[ -f "$kubeconfig" ]]; then
        kubectl --kubeconfig "$kubeconfig" delete -f \
            "$repo_dir/kubernetes/tests/cilium-bgp/all-nodes-service.yaml" \
            --ignore-not-found --wait=false >/dev/null 2>&1 || true
    fi
}
trap cleanup_acceptance_service EXIT
trap 'exit 130' HUP INT TERM


node_field() {
    local hostname="$1" expression="$2"
    jq -er --arg hostname "$hostname" \
        '.topology.nodes[] | select(.hostname == $hostname) | '"$expression" "$context_file"
}

junos_playbook() {
    local playbook="$1"
    shift
    "$repo_dir/ansible/junos/scripts/with-openbao-runtime.sh" --authenticated live \
        ansible-playbook "$playbook" "$@"
}

talos_get() {
    local address="$1" resource="$2"
    if talosctl --talosconfig "$talosconfig" --nodes "$address" version >/dev/null 2>&1; then
        talosctl --talosconfig "$talosconfig" --nodes "$address" get "$resource" --output yaml
    else
        talosctl --nodes "$address" get "$resource" --insecure --output yaml
    fi
}

stage_preflight() {
    just kube validate-cilium-bgp
    "$bootstrap_dir/scripts/verify-oci-digests.py"
    yq -e 'select(.metadata.name == "cluster-apps") | .spec.suspend == true' \
        "$repo_dir/kubernetes/flux/cluster/ks.yaml" >/dev/null
    if stage_complete bgp; then
        junos_playbook playbooks/bgp-sessions.yml
    else
        junos_playbook playbooks/bgp-preflight.yml
    fi

    local hostname bootstrap inventory disks links install_model install_wwid install_bus_prefix install_size
    local localpv_match localpv_serial osd_serial tor1 tor2
    for index in 01 02 03 04 05; do
        hostname="bsd-k8s-$index"
        bootstrap="$(node_field "$hostname" '.bootstrap_address')"
        install_model="$(node_field "$hostname" '.install_disk.model')"
        install_wwid="$(node_field "$hostname" '.install_disk.wwid')"
        install_bus_prefix="$(node_field "$hostname" '.install_disk.bus_path_prefix')"
        install_size="$(node_field "$hostname" '.install_disk.size_bytes')"
        localpv_match="$(node_field "$hostname" '.localpv_disk.match')"
        localpv_serial="${localpv_match##*disk.serial == \"}"
        localpv_serial="${localpv_serial%%\"*}"
        osd_serial="$(node_field "$hostname" '.future_osd.serial')"
        tor1="$(node_field "$hostname" '.links.tor1.permanent_mac')"
        tor2="$(node_field "$hostname" '.links.tor2.permanent_mac')"
        disks="$(talos_get "$bootstrap" disks)"
        links="$(talos_get "$bootstrap" linkstatus)"
        [[ "$disks" == *"$install_model"* && "$disks" == *"$install_wwid"* &&
            "$disks" == *"$install_bus_prefix"* && "$disks" == *"$install_size"* &&
            "$disks" == *"$localpv_serial"* && "$disks" == *"$osd_serial"* ]] || {
            echo "$hostname: protected install, LocalPV, or future OSD identity is absent" >&2
            return 1
        }
        [[ "$links" == *"$tor1"* && "$links" == *"$tor2"* ]] || {
            echo "$hostname: one or both protected X710 links are absent" >&2
            return 1
        }
        inventory="$(talos_get "$bootstrap" timestatus)"
        [[ "$inventory" == *"synced: true"* ]] || {
            echo "$hostname: NTP is not synchronized" >&2
            return 1
        }
    done
}

wait_talos_api() {
    local address="$1"
    retry 60 5 talosctl --talosconfig "$talosconfig" --nodes "$address" version >/dev/null
}

apply_node() {
    local hostname="$1" bootstrap address config link_status route_status address_status
    local extension_status module_status volume_status param_status bond_confirmation
    local persistent_addresses
    bootstrap="$(node_field "$hostname" '.bootstrap_address')"
    address="$(node_field "$hostname" '.address')"
    config="$runtime_dir/nodes/$hostname/$hostname.yaml"
    if talosctl --talosconfig "$talosconfig" --nodes "$bootstrap" version >/dev/null 2>&1; then
        talosctl --talosconfig "$talosconfig" --nodes "$bootstrap" apply-config \
            --dry-run --mode=auto --file "$config" >/dev/null
        talosctl --talosconfig "$talosconfig" --nodes "$bootstrap" apply-config \
            --mode=auto --file "$config"
        wait_talos_api "$bootstrap"
        printf '%s: authenticated Talos configuration reconciled\n' "$hostname"
        return
    fi
    talosctl --nodes "$bootstrap" apply-config --insecure --file "$config"
    wait_talos_api "$address"
    link_status="$(talosctl --talosconfig "$talosconfig" --nodes "$address" get linkstatus --output yaml)"
    route_status="$(talosctl --talosconfig "$talosconfig" --nodes "$address" get routestatus --output yaml)"
    address_status="$(talosctl --talosconfig "$talosconfig" --nodes "$address" get addressstatus --output yaml)"
    extension_status="$(talosctl --talosconfig "$talosconfig" --nodes "$address" get extensionstatus --output yaml)"
    module_status="$(talosctl --talosconfig "$talosconfig" --nodes "$address" get loadedkernelmodules --output yaml)"
    volume_status="$(talosctl --talosconfig "$talosconfig" --nodes "$address" get volumestatus --output yaml)"
    param_status="$(talosctl --talosconfig "$talosconfig" --nodes "$address" get kernelparams --output yaml)"
    [[ "$address_status" == *"address: $address/24"* &&
        "$address_status" == *"address: $bootstrap/24"* &&
        ! "$address_status" =~ address:\ 10[.]25[.]11[.]2[0-5][0-9]/24 ]] || {
        echo "$hostname: static permanent/bootstrap addresses or DHCP exclusion failed" >&2
        return 1
    }
    [[ "$extension_status" == *"intel-ucode"* && "$extension_status" == *"i915"* &&
        "$extension_status" == *"nfsrahead"* && "$extension_status" != *"iscsi"* &&
        "$module_status" == *"id: i915"* && "$volume_status" == *"id: u-local-hostpath"* &&
        "$param_status" == *"id: proc.sys.user.max_user_namespaces"* &&
        "$param_status" == *'current: "11255"'* ]] || {
        echo "$hostname: extension, iGPU, LocalPV, or user namespace proof failed" >&2
        return 1
    }
    [[ "$link_status" == *"bond0"* && "$link_status" == *"mtu: 1496"* &&
        "$link_status" == *"enp1s0f0np0"* && "$link_status" == *"enp1s0f1np1"* ]] || {
        echo "$hostname: cross-ToR active-backup bond proof failed" >&2
        return 1
    }
    [[ "$route_status" == *"0.0.0.0/0"* && "$route_status" == *"10.25.11.1"* ]] || {
        echo "$hostname: default route proof failed" >&2
        return 1
    }
    printf '%s\n' \
        "$hostname: physically fail and restore tor1, then tor2; prove the permanent API, gateway, and MTU through each surviving member." >&2
    read -r -p "Type 'confirm-bond $hostname' only after both member-path tests pass: " \
        bond_confirmation
    [[ "$bond_confirmation" == "confirm-bond $hostname" ]] || {
        echo "$hostname: management NIC remains enabled; bond acceptance was not confirmed" >&2
        return 1
    }
    talosctl --talosconfig "$talosconfig" --nodes "$address" reboot
    wait_talos_api "$address"
    retry 60 5 talosctl --talosconfig "$talosconfig" --nodes "$bootstrap" version >/dev/null
    persistent_addresses="$(talosctl --talosconfig "$talosconfig" --nodes "$address" get addressstatus --output yaml)"
    [[ "$persistent_addresses" == *"address: $address/24"* &&
        "$persistent_addresses" == *"address: $bootstrap/24"* ]] || {
        echo "$hostname: permanent or MGMT address did not persist through reboot" >&2
        return 1
    }
}

member_count() {
    talosctl --talosconfig "$talosconfig" --nodes 10.25.11.11 etcd members |
        python -c 'import sys; print(max(0, len([line for line in sys.stdin if line.strip()]) - 1))'
}

three_members_ready() {
    [[ "$(member_count)" == 3 ]]
}

stage_nodes() {
    local members snapshot recipient count

    for index in 01 02 03 04 05; do
        apply_node "bsd-k8s-$index"
    done

    count="$(member_count)"
    if [[ "$count" == 0 ]]; then
        talosctl --talosconfig "$talosconfig" --nodes 10.25.11.11 bootstrap
    elif [[ "$count" != 3 ]]; then
        printf 'existing etcd membership is incomplete before bootstrap: %s\n' "$count" >&2
    fi

    retry 60 5 three_members_ready || {
        printf 'expected exactly three etcd members after bootstrap; found %s\n' "$(member_count)" >&2
        return 1
    }
    members="$(talosctl --talosconfig "$talosconfig" --nodes 10.25.11.11 etcd members)"
    [[ "$members" == *"10.25.11.11"* && "$members" == *"10.25.11.12"* &&
        "$members" == *"10.25.11.13"* ]] || {
        printf 'etcd members do not match the three reviewed control planes\n' >&2
        return 1
    }

    snapshot="$runtime_dir/etcd.snapshot"
    talosctl --talosconfig "$talosconfig" --nodes 10.25.11.11 etcd snapshot "$snapshot"
    recipient="$(jq -er '.topology.cluster.snapshot_age_recipient' "$context_file")"
    age -r "$recipient" -o "$state_dir/etcd-bootstrap.snapshot.age" "$snapshot"
    chmod 0600 "$state_dir/etcd-bootstrap.snapshot.age"
}

set_kubeconfig_server() {
    local server="$1" cluster
    cluster="$(kubectl --kubeconfig "$kubeconfig" config view --minify \
        -o jsonpath='{.contexts[0].context.cluster}')"
    [[ -n "$cluster" ]] || {
        echo "generated kubeconfig has no current cluster" >&2
        return 1
    }
    kubectl --kubeconfig "$kubeconfig" config set-cluster "$cluster" \
        --server="$server" >/dev/null
}

fetch_direct_kubeconfig() {
    rm -f -- "$kubeconfig"
    talosctl --talosconfig "$talosconfig" --nodes 10.25.11.11 kubeconfig \
        --force --force-context-name bootstrap "$runtime_dir"
    chmod 0600 "$kubeconfig"
    set_kubeconfig_server https://10.25.11.11:6443
}

five_nodes_registered() {
    local names
    names="$(kubectl --kubeconfig "$kubeconfig" get nodes -o json |
        jq -c '[.items[].metadata.name] | sort')"
    [[ "$names" == '["bsd-k8s-01","bsd-k8s-02","bsd-k8s-03","bsd-k8s-04","bsd-k8s-05"]' ]]
}

stage_kubernetes() {
    fetch_direct_kubeconfig
    retry 60 5 kubectl --kubeconfig "$kubeconfig" get --raw=/readyz >/dev/null
    retry 60 5 five_nodes_registered
}

stage_kubeconfig_node() {
    fetch_direct_kubeconfig
    kubectl --kubeconfig "$kubeconfig" get --raw=/readyz >/dev/null
}

flux_release_ready() {
    local name=$1
    [[ "$(kubectl --kubeconfig "$kubeconfig" -n kube-system get helmrelease "$name" \
        -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)" == True ]]
}
flux_config_ready() {
    [[ "$(kubectl --kubeconfig "$kubeconfig" -n kube-system get kustomization cilium-config \
        -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)" == True ]]
}



apply_cilium_base() {
    if flux_release_ready cilium; then
        kubectl --kubeconfig "$kubeconfig" -n kube-system rollout status \
            daemonset/cilium --timeout=5m
        kubectl --kubeconfig "$kubeconfig" -n kube-system rollout status \
            deployment/cilium-operator --timeout=5m
        return
    fi
    "$bootstrap_dir/scripts/verify-oci-digests.py"
    helmfile -f "$bootstrap_dir/helmfile/apps.yaml" --selector name=cilium sync --hide-notes
    retry 60 5 kubectl --kubeconfig "$kubeconfig" -n kube-system rollout status \
        daemonset/cilium --timeout=10s
    retry 60 5 kubectl --kubeconfig "$kubeconfig" -n kube-system rollout status \
        deployment/cilium-operator --timeout=10s
    for resource in pool-infrastructure pool-internal pool-edge-backend advertisement peers; do
        kubectl --kubeconfig "$kubeconfig" apply --server-side \
            --field-manager=bootstrap-cilium-config \
            -f "$repo_dir/kubernetes/apps/kube-system/cilium/config/$resource.yaml"
    done
}

stage_cilium() {
    fetch_direct_kubeconfig
    apply_cilium_base
}

cilium_sessions_ready() {
    local pod output
    local established=0
    local -a pods
    mapfile -t pods < <(
        kubectl --kubeconfig "$kubeconfig" -n kube-system get pods \
            -l k8s-app=cilium -o name
    )
    [[ "${#pods[@]}" == 5 ]] || return 1
    for pod in "${pods[@]}"; do
        output="$(kubectl --kubeconfig "$kubeconfig" -n kube-system exec "$pod" -- \
            cilium bgp peers 2>/dev/null)" || return 1
        [[ "$(printf '%s\n' "$output" |
            awk 'tolower($0) ~ /established/ {count++} END {print count+0}')" == 1 ]] ||
            return 1
        ((established += 1))
    done
    [[ "$established" == 5 ]]
}

stage_bgp() {
    fetch_direct_kubeconfig
    if flux_config_ready; then
        for index in 01 02 03 04 05; do
            set_bgp_label "bsd-k8s-$index" present
        done
        retry 30 3 cilium_sessions_ready
        junos_playbook playbooks/bgp-sessions.yml
        return
    fi
    for index in 01 02 03 04 05; do
        password_file="$runtime_dir/bgp-password-$index"
        password="$(jq -er --arg field "password_$index" '.data.data[$field]' "$bgp_raw")"
        printf '%s' "$password" > "$password_file"
        chmod 0600 "$password_file"
        secret="cilium-bgp-auth-bsd-k8s-$index"
        kubectl --kubeconfig "$kubeconfig" -n kube-system create secret generic "$secret" \
            --from-file=password="$password_file" --dry-run=client -o yaml |
            kubectl --kubeconfig "$kubeconfig" apply --server-side \
                --field-manager=bootstrap-cilium-config -f -
        secret_length="$(kubectl --kubeconfig "$kubeconfig" -n kube-system get secret "$secret" \
            -o json | jq -er '.data.password | @base64d | length')"
        [[ "$secret_length" == 43 ]] || {
            echo "$secret is empty or malformed" >&2
            return 1
        }
    done
    kubectl --kubeconfig "$kubeconfig" apply --server-side --field-manager=bootstrap-cilium-config \
        -f "$repo_dir/kubernetes/apps/kube-system/cilium/config/clusters.yaml"
    for index in 01 02 03 04 05; do
        set_bgp_label "bsd-k8s-$index" present
    done
    sleep 5
    if kubectl --kubeconfig "$kubeconfig" -n kube-system logs daemonset/cilium --since=5m |
        python -c 'import sys; raise SystemExit(0 if "will continue with empty password" in sys.stdin.read() else 1)'; then
        kubectl --kubeconfig "$kubeconfig" delete -f \
            "$repo_dir/kubernetes/apps/kube-system/cilium/config/clusters.yaml" --ignore-not-found
        echo "Cilium attempted an empty-password fallback; ClusterConfig was removed" >&2
        return 1
    fi
    retry 30 3 cilium_sessions_ready
    junos_playbook playbooks/bgp-sessions.yml
}

stage_api_vip() {
    fetch_direct_kubeconfig
    kubectl --kubeconfig "$kubeconfig" -n default delete service kube-vip \
        --ignore-not-found >/dev/null
    if flux_config_ready; then
        kubectl --kubeconfig "$kubeconfig" apply -f \
            "$repo_dir/kubernetes/apps/kube-system/cilium/config/vip.yaml"
        retry 30 3 bash -c '
            [[ "$(kubectl --kubeconfig "$1" -n kube-system get service kube-vip -o json |
              jq -r ".status.loadBalancer.ingress[0].ip // empty")" == "10.25.20.10" ]]
        ' _ "$kubeconfig"
        retry 30 3 kubectl --kubeconfig "$kubeconfig" \
            --server https://10.25.20.10:6443 get --raw=/readyz >/dev/null
        return
    fi
    kubectl --kubeconfig "$kubeconfig" apply -f \
        "$repo_dir/kubernetes/tests/cilium-bgp/all-nodes-service.yaml"
    retry 30 3 bash -c '
        [[ "$(kubectl --kubeconfig "$1" -n kube-system get service cilium-bgp-all-nodes -o json |
          jq -r ".status.loadBalancer.ingress[0].ip // empty")" == "10.25.20.11" ]]
    ' _ "$kubeconfig"
    retry 30 3 junos_playbook playbooks/bgp-verify.yml
    kubectl --kubeconfig "$kubeconfig" apply -f \
        "$repo_dir/kubernetes/apps/kube-system/cilium/config/vip.yaml"
    retry 30 3 bash -c '
        [[ "$(kubectl --kubeconfig "$1" -n kube-system get service kube-vip -o json |
          jq -r ".status.loadBalancer.ingress[0].ip // empty")" == "10.25.20.10" ]]
    ' _ "$kubeconfig"
    retry 30 3 kubectl --kubeconfig "$kubeconfig" \
        --server https://10.25.20.10:6443 get --raw=/readyz >/dev/null
}

stage_kubeconfig_cilium() {
    fetch_direct_kubeconfig
    set_kubeconfig_server https://k8s.monosense.io:6443
    cp "$kubeconfig" "$repo_dir/kubeconfig"
    chmod 0600 "$repo_dir/kubeconfig"
    cp "$talosconfig" "$repo_dir/talosconfig"
    chmod 0600 "$repo_dir/talosconfig"
}

stage_coredns() {
    "$bootstrap_dir/scripts/verify-oci-digests.py"
    fetch_direct_kubeconfig
    if ! flux_release_ready coredns; then
        helmfile -f "$bootstrap_dir/helmfile/apps.yaml" --selector name=coredns sync --hide-notes
    fi
    retry 30 5 kubectl --kubeconfig "$kubeconfig" -n kube-system rollout status \
        deployment/coredns --timeout=10s
    if ! kubectl --kubeconfig "$kubeconfig" -n kube-system rollout status \
        deployment/hubble-relay --timeout=10s; then
        kubectl --kubeconfig "$kubeconfig" -n kube-system rollout restart \
            deployment/hubble-relay
    fi
    retry 30 5 kubectl --kubeconfig "$kubeconfig" -n kube-system rollout status \
        deployment/hubble-relay --timeout=10s
}

stage_flux() {
    "$bootstrap_dir/scripts/verify-oci-digests.py"
    fetch_direct_kubeconfig
    KUBECONFIG="$kubeconfig" "$bootstrap_dir/scripts/install-flux.sh"
}

junos_acceptance() {
    local phase="$1"
    "$repo_dir/ansible/junos/scripts/with-openbao-runtime.sh" --authenticated live \
        ansible-playbook playbooks/bgp-acceptance.yml -e "acceptance_phase=$phase"
}

set_bgp_label() {
    local hostname="$1" value="$2"
    if [[ "$value" == "absent" ]]; then
        kubectl --kubeconfig "$kubeconfig" label node "$hostname" \
            bgp.monosense.io/enabled- >/dev/null
    else
        kubectl --kubeconfig "$kubeconfig" label node "$hostname" \
            bgp.monosense.io/enabled=true --overwrite >/dev/null
    fi
}
set_bgp_peer_state() {
    local hostname="$1" value="$2"
    if [[ "$value" == "absent" ]]; then
        kubectl --kubeconfig "$kubeconfig" delete ciliumbgpclusterconfig \
            "cilium-srx1500-$hostname" --ignore-not-found --wait=false >/dev/null
    else
        kubectl --kubeconfig "$kubeconfig" apply --server-side \
            --field-manager=bootstrap-cilium-config \
            -f "$repo_dir/kubernetes/apps/kube-system/cilium/config/clusters.yaml" >/dev/null
    fi
}



measure_acceptance() {
    local phase="$1" start end
    start="$(date +%s)"
    retry 8 1 junos_acceptance "$phase" >&2
    end="$(date +%s)"
    printf '%s' "$((end - start))"
}

stage_verify() {
    local worker_withdraw worker_restore controlplane_withdraw controlplane_restore
    local all_withdraw all_restore temporary_withdraw render_digest snapshot_digest
    local members hostname address localpv_match localpv_serial osd_serial disks
    local stability_started_at edge_review_not_before acceptance_timeout=15
    fetch_direct_kubeconfig
    acceptance_active=true
    for index in 01 02 03 04 05; do
        set_bgp_label "bsd-k8s-$index" present
    done
    kubectl --kubeconfig "$kubeconfig" apply -f \
        "$repo_dir/kubernetes/tests/cilium-bgp/all-nodes-service.yaml"
    retry 30 3 cilium_sessions_ready
    if ! retry 30 3 junos_playbook playbooks/bgp-verify.yml; then
        kubectl --kubeconfig "$kubeconfig" -n kube-system get \
            ciliumbgpadvertisement cilium-loadbalancer-hosts -o yaml >&2
        kubectl --kubeconfig "$kubeconfig" -n kube-system get \
            service cilium-bgp-all-nodes -o yaml >&2
        while IFS= read -r pod; do
            printf '%s\n' "advertised routes from $pod:" >&2
            kubectl --kubeconfig "$kubeconfig" -n kube-system exec "$pod" -- \
                cilium bgp routes advertised ipv4 unicast >&2
        done < <(kubectl --kubeconfig "$kubeconfig" -n kube-system get pods \
            -l k8s-app=cilium -o name | sort)
        return 1
    fi
    retry 8 1 junos_acceptance all

    set_bgp_peer_state bsd-k8s-05 absent
    worker_withdraw="$(measure_acceptance worker-withdrawn)"
    ((worker_withdraw <= acceptance_timeout)) || {
        echo "worker withdrawal exceeded ${acceptance_timeout} seconds" >&2
        return 1
    }
    kubectl --kubeconfig "$kubeconfig" get --raw=/readyz >/dev/null
    set_bgp_peer_state bsd-k8s-05 present
    worker_restore="$(measure_acceptance all)"

    set_bgp_peer_state bsd-k8s-03 absent
    controlplane_withdraw="$(measure_acceptance controlplane-withdrawn)"
    ((controlplane_withdraw <= acceptance_timeout)) || {
        echo "control-plane withdrawal exceeded ${acceptance_timeout} seconds" >&2
        return 1
    }
    retry 10 1 kubectl --kubeconfig "$kubeconfig" --server https://10.25.20.10:6443 \
        --request-timeout=3s get --raw=/readyz >/dev/null
    set_bgp_peer_state bsd-k8s-03 present
    controlplane_restore="$(measure_acceptance all)"

    for index in 01 02 03 04 05; do
        set_bgp_peer_state "bsd-k8s-$index" absent
    done
    all_withdraw="$(measure_acceptance all-withdrawn)"
    ((all_withdraw <= acceptance_timeout)) || {
        echo "all-peer withdrawal exceeded ${acceptance_timeout} seconds" >&2
        return 1
    }
    if kubectl --kubeconfig "$kubeconfig" --server https://10.25.20.10:6443 \
        --request-timeout=3s get --raw=/readyz >/dev/null 2>&1; then
        echo "VIP remained reachable after complete BGP withdrawal" >&2
        return 1
    fi
    kubectl --kubeconfig "$kubeconfig" get --raw=/readyz >/dev/null
    for index in 01 02 03 04 05; do
        set_bgp_peer_state "bsd-k8s-$index" present
    done
    all_restore="$(measure_acceptance all)"

    kubectl --kubeconfig "$kubeconfig" delete -f \
        "$repo_dir/kubernetes/tests/cilium-bgp/all-nodes-service.yaml" --ignore-not-found
    temporary_withdraw="$(measure_acceptance temporary-removed)"
    kubectl --kubeconfig "$kubeconfig" get --raw=/readyz >/dev/null

    [[ "$(kubectl --kubeconfig "$kubeconfig" get nodes -o json |
        jq '[.items[] | select(any(.status.conditions[]; .type == "Ready" and .status == "True"))] | length')" == 5 ]] || {
        echo "seven-day gate requires five Ready nodes" >&2
        return 1
    }
    members="$(talosctl --talosconfig "$talosconfig" --nodes 10.25.11.11 get members --output yaml)"
    [[ "$members" == *"10.25.11.11"* && "$members" == *"10.25.11.12"* &&
        "$members" == *"10.25.11.13"* ]] || {
        echo "seven-day gate requires complete etcd quorum" >&2
        return 1
    }
    for index in 01 02 03 04 05; do
        hostname="bsd-k8s-$index"
        address="$(node_field "$hostname" '.address')"
        localpv_match="$(node_field "$hostname" '.localpv_disk.match')"
        localpv_serial="${localpv_match##*disk.serial == \"}"
        localpv_serial="${localpv_serial%%\"*}"
        osd_serial="$(node_field "$hostname" '.future_osd.serial')"
        disks="$(talosctl --talosconfig "$talosconfig" --nodes "$address" get disks --output yaml)"
        [[ "$disks" == *"$localpv_serial"* && "$disks" == *"$osd_serial"* ]] || {
            echo "$hostname: LocalPV or raw future OSD identity is absent" >&2
            return 1
        }
    done
    stability_started_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    edge_review_not_before="$(python -c '
from datetime import datetime, timedelta, timezone
print((datetime.now(timezone.utc) + timedelta(days=7)).strftime("%Y-%m-%dT%H:%M:%SZ"))
')"
    render_digest="$(shasum -a 256 "$runtime_dir/nodes/bsd-k8s-01/bsd-k8s-01.yaml" |
        cut -d' ' -f1)"
    snapshot_digest="$(shasum -a 256 "$state_dir/etcd-bootstrap.snapshot.age" |
        cut -d' ' -f1)"
    jq -n \
        --argjson worker_withdraw "$worker_withdraw" \
        --argjson worker_restore "$worker_restore" \
        --argjson controlplane_withdraw "$controlplane_withdraw" \
        --argjson controlplane_restore "$controlplane_restore" \
        --argjson all_withdraw "$all_withdraw" \
        --argjson all_restore "$all_restore" \
        --argjson temporary_withdraw "$temporary_withdraw" \
        --arg render_digest "$render_digest" \
        --arg snapshot_digest "$snapshot_digest" \
        --arg stability_started_at "$stability_started_at" \
        --arg edge_review_not_before "$edge_review_not_before" \
        '{
          durations_seconds: {
            worker_withdraw: $worker_withdraw,
            worker_restore: $worker_restore,
            controlplane_withdraw: $controlplane_withdraw,
            controlplane_restore: $controlplane_restore,
            all_withdraw: $all_withdraw,
            all_restore: $all_restore,
            temporary_withdraw: $temporary_withdraw
          },
          render_sha256: $render_digest,
          encrypted_snapshot_sha256: $snapshot_digest,
          sessions_restored: 5,
          service_paths_after_cleanup: 0,
          api_paths_after_cleanup: 3,
          stability_window: {
            started_at: $stability_started_at,
            edge_review_not_before: $edge_review_not_before,
            reset_on_critical_alarm: true,
            authorizes_deployment: false
          }
        }' > "$state_dir/acceptance-evidence.json"
    chmod 0600 "$state_dir/acceptance-evidence.json"

    set_kubeconfig_server https://k8s.monosense.io:6443
    cp "$kubeconfig" "$repo_dir/kubeconfig"
    chmod 0600 "$repo_dir/kubeconfig"
    cp "$talosconfig" "$repo_dir/talosconfig"
    chmod 0600 "$repo_dir/talosconfig"
    kubectl --kubeconfig "$kubeconfig" --server https://10.25.20.10:6443 get nodes
    talosctl --talosconfig "$talosconfig" --nodes 10.25.11.11 get members
    [[ "$(kubectl --kubeconfig "$kubeconfig" --server https://10.25.20.10:6443 get nodes \
        -o json | jq '[.items[] | select(any(.status.conditions[]; .type == "Ready" and .status == "True"))] | length')" == 5 ]]
    kubectl --kubeconfig "$kubeconfig" --server https://10.25.20.10:6443 \
        -n flux-system wait deployment/flux-operator --for=condition=Available --timeout=5m
    kubectl --kubeconfig "$kubeconfig" --server https://10.25.20.10:6443 \
        -n flux-system wait fluxinstance/flux --for=condition=Ready --timeout=5m
    [[ "$(kubectl --kubeconfig "$kubeconfig" --server https://10.25.20.10:6443 \
        -n flux-system get gitrepository flux-system \
        -o jsonpath='{.spec.url} {.spec.interval}')" == \
        'https://git.monosense.io/trosvald/infrastructure.git 5m' ]]
    [[ "$(kubectl --kubeconfig "$kubeconfig" --server https://10.25.20.10:6443 \
        -n flux-system get kustomization flux-system \
        -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')" == True ]]
    for root in flux-repositories infrastructure-controllers infrastructure-configs cluster-apps; do
        [[ "$(kubectl --kubeconfig "$kubeconfig" --server https://10.25.20.10:6443 \
            -n flux-system get kustomization "$root" \
            -o jsonpath='{.spec.suspend}')" == true ]] || {
            printf 'bootstrap root is missing or not suspended: %s\n' "$root" >&2
            return 1
        }
    done
}

run_stage() {
    local stage="$1" function_name
    if stage_complete "$stage"; then
        printf 'revalidating bootstrap stage recorded by advisory checkpoint: %s\n' "$stage"
    else
        printf 'running bounded bootstrap stage: %s\n' "$stage"
    fi
    function_name="stage_${stage//-/_}"
    "$function_name"
    mark_complete "$stage"
}

case "$requested_stage" in
    all)
        for stage in "${stages[@]}"; do run_stage "$stage"; done
        ;;
    network)
        for stage in "${network_stages[@]}"; do run_stage "$stage"; done
        ;;
    preflight|flux|verify)
        run_stage "$requested_stage"
        ;;
esac
