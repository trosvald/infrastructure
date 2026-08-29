#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
bootstrap_dir="$repo_dir/bootstrap"
cd "$repo_dir"

stages=(preflight nodes kubernetes kubeconfig-node cilium bgp api-vip kubeconfig-cilium verify)
authenticated=false
if [[ "${1:-}" == "--authenticated" ]]; then
    authenticated=true
    shift
fi
requested_stage="${1:-all}"
[[ $# -le 1 ]] || { echo "bootstrap accepts at most one fixed stage" >&2; exit 2; }
if [[ "$requested_stage" != "all" ]]; then
    valid=false
    for stage in "${stages[@]}"; do
        [[ "$requested_stage" == "$stage" ]] && valid=true
    done
    [[ "$valid" == true ]] || { echo "unknown bootstrap stage: $requested_stage" >&2; exit 2; }
fi

if [[ "$authenticated" == false ]]; then
    exec "$repo_dir/scripts/with-openbao-runtime.sh" \
        bootstrap/scripts/cluster.sh --authenticated "$requested_stage"
fi
[[ -n "${OPENBAO_RUNTIME_DIR:-}" && -d "$OPENBAO_RUNTIME_DIR" &&
    ! -L "$OPENBAO_RUNTIME_DIR" && -n "${BAO_TOKEN:-}" ]] || {
    echo "bootstrap requires the authenticated repository OpenBao runtime" >&2
    exit 1
}

for tool in age ansible-playbook bao helmfile jq kubectl kustomize minijinja-cli python talosctl yq; do
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
    (.data.data | keys) == ["password"] and
    (.data.data.password | type == "string" and length == 43 and test("^[A-Za-z0-9_-]+$"))
' "$bgp_raw" >/dev/null || {
    echo "shared Cilium BGP record is missing its exact password field" >&2
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
cleanup_acceptance_service() {
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
    "$repo_dir/ansible/junos/scripts/with-openbao-runtime.sh" --authenticated live \
        ansible-playbook "$1"
}

stage_preflight() {
    just kube validate-cilium-bgp
    yq -e 'select(.metadata.name == "cluster-apps") | .spec.suspend == true' \
        "$repo_dir/kubernetes/flux/cluster/ks.yaml" >/dev/null
    python -c 'import socket; assert socket.gethostbyname("k8s.monosense.io") == "10.25.20.10"'
    junos_playbook playbooks/bgp-preflight.yml

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
        disks="$(talosctl --nodes "$bootstrap" get disks --insecure --output yaml)"
        links="$(talosctl --nodes "$bootstrap" get linkstatus --insecure --output yaml)"
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
        inventory="$(talosctl --nodes "$bootstrap" get timestatus --insecure --output yaml)"
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

stage_nodes() {
    local members snapshot recipient
    apply_node bsd-k8s-01
    if ! talosctl --talosconfig "$talosconfig" --nodes 10.25.11.11 get members >/dev/null 2>&1; then
        talosctl --talosconfig "$talosconfig" --nodes 10.25.11.11 bootstrap
    fi
    retry 60 5 talosctl --talosconfig "$talosconfig" --nodes 10.25.11.11 get members >/dev/null
    snapshot="$runtime_dir/etcd.snapshot"
    talosctl --talosconfig "$talosconfig" --nodes 10.25.11.11 etcd snapshot "$snapshot"
    recipient="$(jq -er '.topology.cluster.snapshot_age_recipient' "$context_file")"
    age -r "$recipient" -o "$state_dir/etcd-bootstrap.snapshot.age" "$snapshot"
    chmod 0600 "$state_dir/etcd-bootstrap.snapshot.age"

    apply_node bsd-k8s-02
    retry 60 5 talosctl --talosconfig "$talosconfig" --nodes 10.25.11.11 get members >/dev/null
    members="$(talosctl --talosconfig "$talosconfig" --nodes 10.25.11.11 get members --output yaml)"
    [[ "$members" == *"10.25.11.11"* && "$members" == *"10.25.11.12"* ]] || return 1
    apply_node bsd-k8s-03
    retry 60 5 talosctl --talosconfig "$talosconfig" --nodes 10.25.11.11 get members >/dev/null
    members="$(talosctl --talosconfig "$talosconfig" --nodes 10.25.11.11 get members --output yaml)"
    [[ "$members" == *"10.25.11.11"* && "$members" == *"10.25.11.12"* &&
        "$members" == *"10.25.11.13"* ]] || return 1
    apply_node bsd-k8s-04
    apply_node bsd-k8s-05
}

fetch_direct_kubeconfig() {
    rm -f -- "$kubeconfig"
    talosctl --talosconfig "$talosconfig" --nodes 10.25.11.11 kubeconfig \
        --force --force-context-name bootstrap "$runtime_dir"
    chmod 0600 "$kubeconfig"
    kubectl --kubeconfig "$kubeconfig" config set-cluster bootstrap \
        --server=https://10.25.11.11:6443 >/dev/null
}

stage_kubernetes() {
    fetch_direct_kubeconfig
    retry 60 5 kubectl --kubeconfig "$kubeconfig" get --raw=/readyz >/dev/null
    retry 60 5 bash -c '
        [[ "$(kubectl --kubeconfig "$1" get nodes -o json |
          jq "[.items[] | select(any(.status.conditions[]; .type == \"Ready\" and .status == \"False\"))] | length")" == 5 ]]
    ' _ "$kubeconfig"
}

stage_kubeconfig_node() {
    fetch_direct_kubeconfig
    kubectl --kubeconfig "$kubeconfig" get --raw=/readyz >/dev/null
}

apply_cilium_base() {
    helmfile -f "$bootstrap_dir/helmfile/crds.yaml" template -q |
        yq ea -r -e 'select(.kind == "CustomResourceDefinition")' |
        kubectl --kubeconfig "$kubeconfig" apply --server-side --force-conflicts -f -
    helmfile -f "$bootstrap_dir/helmfile/apps.yaml" --selector name=cilium sync --hide-notes
    retry 60 5 kubectl --kubeconfig "$kubeconfig" -n kube-system rollout status \
        daemonset/cilium --timeout=10s
    for resource in pool-infrastructure pool-internal pool-edge-backend advertisement peer; do
        kubectl --kubeconfig "$kubeconfig" apply --server-side --force-conflicts \
            -f "$repo_dir/kubernetes/apps/kube-system/cilium/config/$resource.yaml"
    done
}

stage_cilium() {
    fetch_direct_kubeconfig
    apply_cilium_base
}

cilium_sessions_ready() {
    local output
    output="$(kubectl --kubeconfig "$kubeconfig" -n kube-system exec daemonset/cilium -- \
        cilium bgp peers 2>/dev/null)" || return 1
    [[ "$(printf '%s\n' "$output" | awk 'tolower($0) ~ /established/ {count++} END {print count+0}')" == 5 ]]
}

stage_bgp() {
    fetch_direct_kubeconfig
    password_file="$runtime_dir/bgp-password"
    jq -er '.data.data.password' "$bgp_raw" > "$password_file"
    chmod 0600 "$password_file"
    kubectl --kubeconfig "$kubeconfig" -n kube-system create secret generic cilium-bgp-auth \
        --from-file=password="$password_file" --dry-run=client -o yaml |
        kubectl --kubeconfig "$kubeconfig" apply --server-side --force-conflicts -f -
    secret_length="$(kubectl --kubeconfig "$kubeconfig" -n kube-system get secret cilium-bgp-auth \
        -o json | jq -er '.data.password | @base64d | length')"
    [[ "$secret_length" == 43 ]] || { echo "Cilium BGP Secret is empty or malformed" >&2; return 1; }
    kubectl --kubeconfig "$kubeconfig" apply --server-side --force-conflicts \
        -f "$repo_dir/kubernetes/apps/kube-system/cilium/config/cluster.yaml"
    sleep 5
    if kubectl --kubeconfig "$kubeconfig" -n kube-system logs daemonset/cilium --since=5m |
        python -c 'import sys; raise SystemExit(0 if "will continue with empty password" in sys.stdin.read() else 1)'; then
        kubectl --kubeconfig "$kubeconfig" delete -f \
            "$repo_dir/kubernetes/apps/kube-system/cilium/config/cluster.yaml" --ignore-not-found
        echo "Cilium attempted an empty-password fallback; ClusterConfig was removed" >&2
        return 1
    fi
    retry 30 3 cilium_sessions_ready
    junos_playbook playbooks/bgp-verify.yml
}

stage_api_vip() {
    fetch_direct_kubeconfig
    kubectl --kubeconfig "$kubeconfig" apply -f \
        "$repo_dir/kubernetes/tests/cilium-bgp/all-nodes-service.yaml"
    retry 30 3 bash -c '
        [[ "$(kubectl --kubeconfig "$1" -n kube-system get service cilium-bgp-all-nodes -o json |
          jq -r ".status.loadBalancer.ingress[0].ip // empty")" == "10.25.20.11" ]]
    ' _ "$kubeconfig"
    junos_playbook playbooks/bgp-verify.yml
    kubectl --kubeconfig "$kubeconfig" apply -f \
        "$repo_dir/kubernetes/apps/kube-system/cilium/config/vip.yaml"
    retry 30 3 bash -c '
        [[ "$(kubectl --kubeconfig "$1" -n kube-system get service kube-vip -o json |
          jq -r ".status.loadBalancer.ingress[0].ip // empty")" == "10.25.20.10" ]]
    ' _ "$kubeconfig"
    retry 30 3 python -c '
import ssl, urllib.request
context = ssl.create_default_context()
with urllib.request.urlopen("https://k8s.monosense.io:6443/readyz", context=context, timeout=3) as response:
    assert response.read().strip() == b"ok"
'
}

stage_kubeconfig_cilium() {
    fetch_direct_kubeconfig
    kubectl --kubeconfig "$kubeconfig" config set-cluster bootstrap \
        --server=https://k8s.monosense.io:6443 >/dev/null
    cp "$kubeconfig" "$repo_dir/kubeconfig"
    chmod 0600 "$repo_dir/kubeconfig"
    cp "$talosconfig" "$repo_dir/talosconfig"
    chmod 0600 "$repo_dir/talosconfig"
    helmfile -f "$bootstrap_dir/helmfile/apps.yaml" --selector name=coredns sync --hide-notes
    retry 30 5 kubectl --kubeconfig "$kubeconfig" -n kube-system rollout status \
        deployment/coredns --timeout=10s
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

measure_acceptance() {
    local phase="$1" start end
    start="$(date +%s)"
    retry 8 1 junos_acceptance "$phase"
    end="$(date +%s)"
    printf '%s' "$((end - start))"
}

stage_verify() {
    local worker_withdraw worker_restore controlplane_withdraw controlplane_restore
    local all_withdraw all_restore temporary_withdraw render_digest snapshot_digest
    local members hostname address localpv_match localpv_serial osd_serial disks
    local stability_started_at edge_review_not_before
    fetch_direct_kubeconfig
    kubectl --kubeconfig "$kubeconfig" apply -f \
        "$repo_dir/kubernetes/tests/cilium-bgp/all-nodes-service.yaml"
    retry 30 3 cilium_sessions_ready
    junos_playbook playbooks/bgp-verify.yml
    retry 8 1 junos_acceptance all

    set_bgp_label bsd-k8s-05 absent
    worker_withdraw="$(measure_acceptance worker-withdrawn)"
    ((worker_withdraw <= 9)) || { echo "worker withdrawal exceeded 9 seconds" >&2; return 1; }
    kubectl --kubeconfig "$kubeconfig" get --raw=/readyz >/dev/null
    set_bgp_label bsd-k8s-05 present
    worker_restore="$(measure_acceptance all)"

    set_bgp_label bsd-k8s-03 absent
    controlplane_withdraw="$(measure_acceptance controlplane-withdrawn)"
    ((controlplane_withdraw <= 9)) || {
        echo "control-plane withdrawal exceeded 9 seconds" >&2
        return 1
    }
    retry 10 1 python -c '
import ssl, urllib.request
with urllib.request.urlopen(
    "https://k8s.monosense.io:6443/readyz",
    context=ssl.create_default_context(),
    timeout=3,
) as response:
    assert response.read().strip() == b"ok"
'
    set_bgp_label bsd-k8s-03 present
    controlplane_restore="$(measure_acceptance all)"

    for index in 01 02 03 04 05; do
        set_bgp_label "bsd-k8s-$index" absent
    done
    all_withdraw="$(measure_acceptance all-withdrawn)"
    ((all_withdraw <= 9)) || { echo "all-peer withdrawal exceeded 9 seconds" >&2; return 1; }
    if python -c '
import ssl, urllib.request
urllib.request.urlopen(
    "https://k8s.monosense.io:6443/readyz",
    context=ssl.create_default_context(),
    timeout=3,
)
'; then
        echo "VIP remained reachable after complete BGP withdrawal" >&2
        return 1
    fi
    kubectl --kubeconfig "$kubeconfig" get --raw=/readyz >/dev/null
    for index in 01 02 03 04 05; do
        set_bgp_label "bsd-k8s-$index" present
    done
    all_restore="$(measure_acceptance all)"

    kubectl --kubeconfig "$kubeconfig" delete -f \
        "$repo_dir/kubernetes/tests/cilium-bgp/all-nodes-service.yaml" --ignore-not-found
    temporary_withdraw="$(measure_acceptance temporary-removed)"
    kubectl --kubeconfig "$kubeconfig" get --raw=/readyz >/dev/null
    junos_playbook playbooks/bgp-verify.yml

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

    kubectl --kubeconfig "$kubeconfig" config set-cluster bootstrap \
        --server=https://k8s.monosense.io:6443 >/dev/null
    cp "$kubeconfig" "$repo_dir/kubeconfig"
    chmod 0600 "$repo_dir/kubeconfig"
    cp "$talosconfig" "$repo_dir/talosconfig"
    chmod 0600 "$repo_dir/talosconfig"
    kubectl --kubeconfig "$kubeconfig" get nodes
    talosctl --talosconfig "$talosconfig" --nodes 10.25.11.11 get members
}

run_stage() {
    local stage="$1" function_name
    if stage_complete "$stage"; then
        printf 'bootstrap stage already complete: %s\n' "$stage"
        return
    fi
    printf 'running bounded bootstrap stage: %s\n' "$stage"
    function_name="stage_${stage//-/_}"
    "$function_name"
    mark_complete "$stage"
}

if [[ "$requested_stage" == "all" ]]; then
    for stage in "${stages[@]}"; do
        run_stage "$stage"
    done
else
    run_stage "$requested_stage"
fi
