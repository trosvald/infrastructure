#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
talos_dir="$repo_dir/talos"
real_talosctl="$(command -v talosctl)"
umask 077
runtime_dir="$(mktemp -d "${TMPDIR:-/tmp}/talos-apply-test.XXXXXX")"
cleanup() {
    rm -rf -- "$runtime_dir"
}
trap cleanup EXIT
trap 'exit 130' HUP INT TERM
mkdir "$runtime_dir/bin"

cat >"$runtime_dir/bin/bao" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'bao\n' >>"$FAKE_STATE_DIR/calls"
record="${*: -1}"
case "$record" in
    platform/talos/bsd/topology)
        jq -n --slurpfile value "$TOPOLOGY_JSON" '{data:{data:$value[0]}}'
        ;;
    platform/talos/bsd/secrets)
        jq -n --slurpfile value "$SECRETS_JSON" '{data:{data:$value[0]}}'
        ;;
    *)
        exit 1
        ;;
esac
EOF
chmod 0700 "$runtime_dir/bin/bao"
cat >"$runtime_dir/bin/sleep" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod 0700 "$runtime_dir/bin/sleep"


cat >"$runtime_dir/bin/talosctl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
joined=" $* "
if [[ "$joined" == *" version --client "* && -n "${CLIENT_VERSION:-}" ]]; then
    printf 'Client:\n    Tag: %s\n' "$CLIENT_VERSION"
    exit 0
fi
if [[ "$joined" == *" machineconfig patch "* || "$joined" == *" validate --config "* ||
    "$joined" == *" version --client "* || "$joined" == *" gen config "* ||
    "$joined" == *" config endpoint "* || "$joined" == *" config node "* ]]; then
    exec "$REAL_TALOSCTL" "$@"
fi

target=""
resource=""
insecure=false
for ((index = 1; index <= $#; index++)); do
    argument="${!index}"
    case "$argument" in
        --nodes|-n)
            next=$((index + 1))
            target="${!next}"
            ;;
        --insecure)
            insecure=true
            ;;
        get)
            next=$((index + 1))
            resource="${!next}"
            ;;
    esac
done
if [[ "$target" == 10.25.11.* ]]; then
    echo "Talos management operation targeted data-plane address $target" >&2
    exit 1
fi
node_json="$(jq -cer --arg target "$target" \
    '.nodes[] | select(.address == $target or .bootstrap_address == $target)' "$TOPOLOGY_JSON")"
hostname="$(jq -r '.hostname' <<<"$node_json")"
node_index="$(jq -r --arg hostname "$hostname" \
    '.nodes | to_entries[] | select(.value.hostname == $hostname) | .key + 1' "$TOPOLOGY_JSON")"
marker="$FAKE_STATE_DIR/applied-$hostname"

if [[ "$joined" == *" apply-config "* ]]; then
    if [[ "$joined" != *" --dry-run "* ]]; then
        printf 'apply %s\n' "$target" >>"$FAKE_STATE_DIR/mutations"
        touch "$marker"
    fi
    exit 0
fi
if [[ "$joined" == *" reboot "* ]]; then
    printf 'reboot %s\n' "$target" >>"$FAKE_STATE_DIR/mutations"
    exit 0
fi
if [[ "$joined" == *" version "* ]]; then
    if [[ -f "$marker" || "$node_index" -le "$INSTALLED_COUNT" ]]; then
        echo 'Server: v1.14.0-rc.2'
        exit 0
    fi
    exit 1
fi
if [[ "$resource" == etcdmembers ]]; then
    if [[ "${ETCD_BOOTSTRAPPED:-false}" == true ]]; then
        echo 'etcdMembers: [synthetic-member]'
    fi
    exit 0
fi

install_model="$(jq -r '.install_disk.model' <<<"$node_json")"
install_wwid="$(jq -r '.install_disk.wwid' <<<"$node_json")"
install_bus="$(jq -r '.install_disk.bus_path_prefix' <<<"$node_json")"
install_size="$(jq -r '.install_disk.size_bytes' <<<"$node_json")"
localpv_match="$(jq -r '.localpv_disk.match' <<<"$node_json")"
localpv_serial="${localpv_match##*disk.serial == \"}"
localpv_serial="${localpv_serial%%\"*}"
osd_serial="$(jq -r '.future_osd.serial' <<<"$node_json")"
tor1="$(jq -r '.links.tor1.permanent_mac' <<<"$node_json")"
tor2="$(jq -r '.links.tor2.permanent_mac' <<<"$node_json")"
address="$(jq -r '.address' <<<"$node_json")"
storage_address="$(jq -r '.storage_address' <<<"$node_json")"
bootstrap="$(jq -r '.bootstrap_address' <<<"$node_json")"

case "$resource" in
    disks)
        printf '%s\n' "$install_model" "$install_wwid" "$install_bus" "$install_size" \
            "$localpv_serial" "$osd_serial"
        ;;
    linkstatus)
        if [[ "${DRIFT_HOST:-}" == "$hostname" && "$insecure" == false ]]; then
            echo 'id: drifted-link'
        else
            printf 'id: bond0\nmtu: 1496\nmode: active-backup\npermanentAddr: %s\nspeedMbit: 10000\npermanentAddr: %s\nspeedMbit: 10000\n' \
                "$tor1" "$tor2"
        fi
        ;;
    timestatus)
        if [[ "${MISMATCH_HOST:-}" == "$hostname" ]]; then
            echo 'synced: false'
        else
            echo 'synced: true'
        fi
        ;;
    routestatus)
        if [[ "${DELAY_ROUTE_HOST:-}" == "$hostname" &&
            ! -f "$FAKE_STATE_DIR/route-ready-$hostname" ]]; then
            touch "$FAKE_STATE_DIR/route-ready-$hostname"
            echo 'route state is still converging'
        else
            echo 'gateway: 10.25.11.1'
            echo 'outLinkName: bond0'
            echo 'priority: 1024'
        fi
        ;;
    addressstatus)
        printf 'address: %s/24\naddress: %s/24\naddress: %s/24\n' \
            "$address" "$bootstrap" "$storage_address"
        ;;
    extensionstatus)
        printf '%s\n' \
            'type: ExtensionStatuses.runtime.talos.dev' 'name: intel-ucode' \
            'type: ExtensionStatuses.runtime.talos.dev' 'name: i915' \
            'type: ExtensionStatuses.runtime.talos.dev' 'name: nfsrahead' \
            'type: ExtensionStatuses.runtime.talos.dev' 'name: schematic' \
            'bd0e9976660939539a20d0c88516154f1cd97d95c2bed48b26314e830023f1b3' \
            'type: ExtensionStatuses.runtime.talos.dev' 'name: modules.dep'
        ;;
    loadedkernelmodules)
        echo 'id: i915'
        ;;
    volumestatus)
        echo 'id: u-local-hostpath'
        ;;
    kernelparams)
        echo 'id: proc.sys.user.max_user_namespaces'
        echo 'current: "11255"'
        ;;
    watchdogtimerstatus)
        echo '/dev/watchdog0'
        ;;
    machineconfig)
        echo 'bondMode: active-backup'
        echo 'bd0e9976660939539a20d0c88516154f1cd97d95c2bed48b26314e830023f1b3'
        ;;
    *)
        echo "unexpected fake talosctl call: $*" >&2
        exit 1
        ;;
esac
EOF
chmod 0700 "$runtime_dir/bin/talosctl"

"$real_talosctl" gen secrets --output-file "$runtime_dir/secrets.yaml"
yq -o=json '.' "$runtime_dir/secrets.yaml" >"$runtime_dir/secrets.json"
yq -o=json '.' "$talos_dir/tests/topology.yml" | jq '
    del(.synthetic) |
    .cluster.name = "bsd-k8s" |
    .cluster.endpoint = "https://k8s.monosense.io:6443" |
    .cluster.snapshot_age_recipient = "age14a89rfvvdrf62v0xe8hlp6hdvgwfnxcku9sjrxc2f47ujkqf5qqqz0c7wk" |
    .network = {subnet:"10.25.11.0/24", gateway:"10.25.11.1"} |
    .management_network = {subnet:"10.25.10.0/24", gateway:"10.25.10.1"} |
    .storage_network = {subnet:"10.25.14.0/24", vlan_id:2514, mtu:1496} |
    .private_dns = ["10.25.13.35", "10.25.10.100"] |
    .ntp_servers = ["time.cloudflare.com", "time.google.com", "0.id.pool.ntp.org"] |
    .approved_admin_sources = ["10.25.10.0/24"] |
    .nodes |= to_entries | .nodes |= map(
        .value.address = "10.25.11.\(.key + 11)" |
        .value.bootstrap_address = "10.25.10.\(.key + 111)" |
        .value.storage_address = "10.25.14.\(.key + 11)" |
        .value.bootstrap_link = "eno1" |
        .value.links.tor1.switch = "tor1" |
        .value.links.tor2.switch = "tor2" |
        .value.links.tor1.port = "\(.key + 1)" |
        .value.links.tor2.port = "\(.key + 1)" |
        .value.install_disk.bus_path_prefix = "/pci0000:00/0000:00:17.0/ata1/" |
        .value.labels = {region:"id-banten", zone:"bsd-home-01", site:"bsd", power_domain:"ups-01", network_domain:"srx1500-01"} |
        .value
    ) |
    .cluster.api_sans = ["k8s.monosense.io", "10.25.20.10"] +
        [.nodes[] | select(.role == "controlplane") | .address]
' >"$runtime_dir/topology.json"

run_case() {
    local name="$1" installed_count="$2" hostname="$3"
    shift 3
    local case_dir="$runtime_dir/$name"
    mkdir -p "$case_dir/runtime" "$case_dir/state"
    : >"$case_dir/state/calls"
    : >"$case_dir/state/mutations"
    local status=0
    env PATH="$runtime_dir/bin:$PATH" \
        REAL_TALOSCTL="$real_talosctl" \
        TOPOLOGY_JSON="$runtime_dir/topology.json" \
        SECRETS_JSON="$runtime_dir/secrets.json" \
        FAKE_STATE_DIR="$case_dir/state" \
        INSTALLED_COUNT="$installed_count" \
        OPENBAO_RUNTIME_DIR="$case_dir/runtime" \
        BAO_TOKEN=fake \
        "$@" \
        "$talos_dir/scripts/render.sh" --authenticated apply-node "$hostname" \
        >"$case_dir/stdout" 2>"$case_dir/stderr" || status=$?
    if [[ $status -ne 0 ]]; then
        cat "$case_dir/stderr" >&2
    fi
    return "$status"
}

run_case installed 1 bsd-k8s-01
[[ "$(awk '$1 == "apply" {print $2}' "$runtime_dir/installed/state/mutations")" == \
    '10.25.10.111' ]]
[[ "$(awk '$1 == "reboot" {count++} END {print count+0}' \
    "$runtime_dir/installed/state/mutations")" == 0 ]]
grep -Fqx 'bsd-k8s-01: installed configuration reconciled and verified' \
    "$runtime_dir/installed/stdout"

run_case maintenance 1 bsd-k8s-02 DELAY_ROUTE_HOST=bsd-k8s-02
[[ "$(awk '$1 == "apply" {print $2}' "$runtime_dir/maintenance/state/mutations")" == \
    '10.25.10.112' ]]
[[ "$(awk '$1 == "reboot" {print $2}' "$runtime_dir/maintenance/state/mutations")" == \
    '10.25.10.112' ]]
grep -Fqx 'bsd-k8s-02: configuration applied and reboot persistence verified' \
    "$runtime_dir/maintenance/stdout"

if run_case mismatch 1 bsd-k8s-03 MISMATCH_HOST=bsd-k8s-03; then
    echo 'hardware/NTP mismatch unexpectedly succeeded' >&2
    exit 1
fi
[[ ! -s "$runtime_dir/mismatch/state/mutations" ]]

if run_case etcd 1 bsd-k8s-02 ETCD_BOOTSTRAPPED=true; then
    echo 'bootstrapped etcd unexpectedly passed the initial apply guard' >&2
    exit 1
fi
grep -Fqx 'Talos initial apply refuses an already bootstrapped etcd cluster' \
    "$runtime_dir/etcd/stderr"
[[ ! -s "$runtime_dir/etcd/state/mutations" ]]

if run_case drift 1 bsd-k8s-01 DRIFT_HOST=bsd-k8s-01; then
    echo 'installed drift unexpectedly fell back to insecure apply' >&2
    exit 1
fi
[[ ! -s "$runtime_dir/drift/state/mutations" ]]
if run_case old-client 1 bsd-k8s-02 CLIENT_VERSION=v1.14.0-rc.1; then
    echo 'mismatched talosctl client unexpectedly passed rendering' >&2
    exit 1
fi
grep -Fq 'talosctl client must be v1.14.0-rc.2' "$runtime_dir/old-client/stderr"
[[ ! -s "$runtime_dir/old-client/state/mutations" ]]


bad_dir="$runtime_dir/bad-args"
mkdir -p "$bad_dir/state"
: >"$bad_dir/state/calls"
if env PATH="$runtime_dir/bin:$PATH" FAKE_STATE_DIR="$bad_dir/state" \
    "$talos_dir/scripts/render.sh" apply-node >"$bad_dir/stdout" 2>"$bad_dir/stderr"; then
    echo 'malformed apply-node arguments unexpectedly succeeded' >&2
    exit 1
fi
[[ ! -s "$bad_dir/state/calls" ]]

python - "$talos_dir/scripts/render.sh" <<'PY'
from pathlib import Path
import sys

source = Path(sys.argv[1]).read_text(encoding="utf-8")
for forbidden in (
    "talosctl bootstrap",
    "etcd snapshot",
    "helmfile",
    "cilium",
    "01 02 03 04 05",
):
    assert forbidden not in source, forbidden
assert "apply-all" not in source
assert 'apply_one_node "$hostname"' in source
assert 'apply_storage_network "$hostname"' in source
assert 'backup_storage_network "$hostname"' in source
assert "reviewed pre-storage Talos backup is absent or unsafe" in source
assert "health failed; restoring reviewed pre-storage config" in source
PY

printf 'Talos per-node initial apply orchestration is fail-closed and restartable\n'
