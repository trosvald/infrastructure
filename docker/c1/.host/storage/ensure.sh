#!/usr/bin/env bash
set -euo pipefail
umask 077

REALPATH_BIN="${REALPATH_BIN:-realpath}"
LSBLK_BIN="${LSBLK_BIN:-lsblk}"
FINDMNT_BIN="${FINDMNT_BIN:-findmnt}"
WIPEFS_BIN="${WIPEFS_BIN:-wipefs}"
SMARTCTL_BIN="${SMARTCTL_BIN:-smartctl}"
PVS_BIN="${PVS_BIN:-pvs}"
NVME_BIN="${NVME_BIN:-nvme}"
MDADM_BIN="${MDADM_BIN:-mdadm}"
FUSER_BIN="${FUSER_BIN:-fuser}"
SHA256_BIN="${SHA256_BIN:-sha256sum}"
SGDISK_BIN="${SGDISK_BIN:-sgdisk}"
SFDISK_BIN="${SFDISK_BIN:-sfdisk}"
PARTPROBE_BIN="${PARTPROBE_BIN:-partprobe}"
UDEVADM_BIN="${UDEVADM_BIN:-udevadm}"
MKFS_XFS_BIN="${MKFS_XFS_BIN:-mkfs.xfs}"
BLKID_BIN="${BLKID_BIN:-blkid}"
MOUNT_BIN="${MOUNT_BIN:-mount}"
MOUNTPOINT_BIN="${MOUNTPOINT_BIN:-mountpoint}"
XFS_INFO_BIN="${XFS_INFO_BIN:-xfs_info}"
INSTALL_BIN="${INSTALL_BIN:-install}"
ID_BIN="${ID_BIN:-id}"
STAT_BIN="${STAT_BIN:-stat}"
SYSTEMCTL_BIN="${SYSTEMCTL_BIN:-systemctl}"
BLOCK_DEVICE_TEST_BIN="${BLOCK_DEVICE_TEST_BIN:-}"
FSTAB="${FSTAB:-/etc/fstab}"
STATE_DIR="${STATE_DIR:-/var/lib/c1-storage}"
SYS_BLOCK_ROOT="${SYS_BLOCK_ROOT:-/sys/class/block}"
BY_ID_ROOT="${BY_ID_ROOT:-/dev/disk/by-id}"
DEV_ROOT="${DEV_ROOT:-/dev}"
readonly REALPATH_BIN LSBLK_BIN FINDMNT_BIN WIPEFS_BIN SMARTCTL_BIN NVME_BIN PVS_BIN
readonly MDADM_BIN FUSER_BIN SHA256_BIN SGDISK_BIN SFDISK_BIN PARTPROBE_BIN UDEVADM_BIN
readonly MKFS_XFS_BIN BLKID_BIN MOUNT_BIN MOUNTPOINT_BIN XFS_INFO_BIN INSTALL_BIN
readonly ID_BIN STAT_BIN SYSTEMCTL_BIN BLOCK_DEVICE_TEST_BIN FSTAB STATE_DIR SYS_BLOCK_ROOT
readonly BY_ID_ROOT DEV_ROOT

fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
usage() {
    printf 'Usage: %s {check|plan} <1TB-by-id>\n       %s apply <1TB-by-id> <PLAN_SHA256>\n       %s verify\n' \
        "$0" "$0" "$0" >&2
    exit 64
}

assert_no_raid() {
    local device="$1" role="$2" output status
    set +e
    output="$("$MDADM_BIN" --examine --export "$device" 2>/dev/null)"
    status=$?
    set -e
    case "$status" in
        0|1) ;;
        *) fail "failed to inspect $role RAID metadata" ;;
    esac
    if grep -q '^MD_UUID=' <<<"$output"; then
        fail "$role target has RAID metadata"
    fi
}

nvme_health() {
    local device="$1" role="$2" smart
    "$SMARTCTL_BIN" -H "$device" >/dev/null || fail "$role target lacks passing SMART health"
    smart="$("$NVME_BIN" smart-log -o json "$device")" \
        || fail "failed to read $role NVMe health counters"
    python3 -c '
import json,sys
x=json.load(sys.stdin)
def number(key):
 value=x.get(key)
 if isinstance(value,bool): raise ValueError(key)
 return int(value)
try:
 critical=number("critical_warning")
 media=number("media_errors")
 spare=number("avail_spare")
 threshold=number("spare_thresh")
 used=number("percent_used")
 entries=number("num_err_log_entries")
 valid=(critical==0 and media==0 and spare>=threshold and 0<=used<=100)
except (TypeError,ValueError):
 valid=False
if not valid:
 raise SystemExit(1)
print(f"1TB_HEALTH_CRITICAL_WARNING={critical}")
print(f"1TB_HEALTH_MEDIA_ERRORS={media}")
print(f"1TB_HEALTH_AVAILABLE_SPARE={spare}")
print(f"1TB_HEALTH_SPARE_THRESHOLD={threshold}")
print(f"1TB_HEALTH_PERCENT_USED={used}")
print(f"1TB_HEALTH_ERROR_LOG_ENTRIES={entries}")
' <<<"$smart" || fail "$role target has unacceptable NVMe health counters"
}

stable_device() {
    local path="$1" resolved kind children mountpoints root_source root_disk base holder
    local os_layout pvs_output status
    [[ "$path" == "$BY_ID_ROOT"/* && "$path" != *-part* ]] \
        || fail '1TB input is not a whole-disk stable by-id path'
    [[ -L "$path" ]] || fail '1TB stable path is not a symlink'
    resolved="$("$REALPATH_BIN" -e -- "$path")" || fail '1TB stable path cannot be resolved'
    [[ "$resolved" == "$DEV_ROOT"/* ]] || fail '1TB stable path resolves outside the device directory'
    kind="$("$LSBLK_BIN" -dnro TYPE -- "$resolved")" || fail 'cannot inspect 1TB device type'
    [[ "$kind" == disk ]] || fail '1TB target is not a whole disk'
    children="$("$LSBLK_BIN" -nrpo NAME -- "$resolved")" || fail 'cannot inspect 1TB children'
    [[ "$children" == "$resolved" ]] || fail '1TB target has partitions or child devices'
    mountpoints="$("$LSBLK_BIN" -nrpo MOUNTPOINTS -- "$resolved")" || fail 'cannot inspect 1TB mounts'
    [[ -z "${mountpoints//[[:space:]]/}" ]] || fail '1TB target or child is mounted'
    root_source="$("$FINDMNT_BIN" -n -o SOURCE /)" || fail 'cannot identify root filesystem source'
    root_disk="$("$LSBLK_BIN" -s -dnro PATH -- "$root_source" | tail -n 1)" \
        || fail 'cannot identify root backing disk'
    [[ "$resolved" != "$root_disk" ]] || fail '1TB target backs the root filesystem'
    os_layout="$("$LSBLK_BIN" -nrpo MOUNTPOINTS,NAME -- "$resolved")" \
        || fail 'cannot inspect 1TB OS mount relationships'
    if grep -Eq '(^|[[:space:]])(/|/boot|/boot/efi|\[SWAP\])([[:space:]]|$)' <<<"$os_layout"; then
        fail '1TB target backs an OS or swap filesystem'
    fi
    base="${resolved##*/}"
    if [[ -d "$SYS_BLOCK_ROOT/$base/holders" ]]; then
        for holder in "$SYS_BLOCK_ROOT/$base/holders"/*; do
            [[ ! -e "$holder" ]] || fail '1TB target has active holders'
        done
    fi
    pvs_output="$("$PVS_BIN" --noheadings -o pv_name 2>/dev/null)" \
        || fail 'failed to inspect LVM physical volumes'
    if grep -Fxq "$resolved" <<<"$pvs_output"; then
        fail '1TB target is an LVM physical volume'
    fi
    assert_no_raid "$resolved" 1TB
    set +e
    "$FUSER_BIN" -s "$resolved"
    status=$?
    set -e
    case "$status" in
        1) ;;
        0) fail '1TB target is in use' ;;
        *) fail 'failed to inspect open-device users' ;;
    esac
    nvme_health "$resolved" 1TB >/dev/null
    printf '%s\n' "$resolved"
}

signature_state() {
    local output
    output="$("$WIPEFS_BIN" --no-act --json -- "$1")" || fail 'signature inspection failed'
    python3 -c 'import json,sys; x=json.load(sys.stdin); s=x.get("signatures",[]); print("none" if not s else ";".join(sorted("%s@%s"%(i.get("type","unknown"),i.get("offset","unknown")) for i in s)))' \
        <<<"$output"
}

layout_values() {
    local size="$1" sector_size="$2" total last start usable half part2_start part1_end
    [[ "$sector_size" =~ ^[0-9]+$ && "$sector_size" -ge 512 ]] \
        || fail '1TB logical sector size is invalid'
    (( size % sector_size == 0 )) || fail '1TB byte size is not sector aligned'
    total=$((size / sector_size))
    start=2048
    last=$((total - 34))
    (( last > start )) || fail '1TB device is too small for the approved GPT layout'
    usable=$((last - start + 1))
    half=$((start + usable / 2))
    part2_start=$((((half + 2047) / 2048) * 2048))
    part1_end=$((part2_start - 1))
    (( part1_end > start && part2_start < last )) || fail 'computed partition split is invalid'
    printf '%s\n' \
        "TOTAL_SECTORS=$total" "LAST_USABLE_SECTOR=$last" \
        "PART1_START=$start" "PART1_END=$part1_end" \
        "PART2_START=$part2_start" "PART2_END=$last"
}

evidence() {
    local path="$1" device model size sector signatures layout health
    device="$(stable_device "$path")"
    model="$("$LSBLK_BIN" -dnro MODEL -- "$device" | tr -s ' ' | sed 's/^ //;s/ $//')"
    size="$("$LSBLK_BIN" -bdnro SIZE -- "$device")"
    sector="$("$LSBLK_BIN" -bdnro LOG-SEC -- "$device")"
    [[ "$size" =~ ^[0-9]+$ && "$size" -ge 900000000000 && "$size" -le 1100000000000 ]] \
        || fail '1TB target size is outside the approved range'
    [[ -n "$model" ]] || fail '1TB target model is unavailable'
    signatures="$(signature_state "$device")"
    [[ "$signatures" == none ]] || fail '1TB target has an unapproved signature'
    health="$(nvme_health "$device" 1TB)"
    layout="$(layout_values "$size" "$sector")"
    printf '%s\n' \
        'C1_STORAGE_PLAN_VERSION=2' "1TB_PATH=$path" "1TB_DEVICE=$device" \
        "1TB_MODEL=$model" "1TB_SIZE=$size" "1TB_LOGICAL_SECTOR=$sector" \
        "1TB_SIGNATURES=$signatures" "$health" "$layout" \
        'PART1_LABEL=c1_librefs' 'PART1_MOUNT=/srv/librefs' \
        'PART2_LABEL=c1_applications' 'PART2_MOUNT=/srv/applications' \
        'PARTITION_LAYOUT=50% LIBREFS + 50% APPLICATIONS' \
        '1TB_ACTION=erase-gpt;gpt-two-xfs-partitions' \
        'OS_DISK_EXCLUDED=true' '512GB_EXCLUDED=true' \
        'DOCKER_ROOTS_REMAIN_OS=true' \
        'ROLLBACK=formatting-cannot-recover-existing-content'
}

make_plan() {
    local body digest
    body="$(evidence "$1")"
    digest="$(printf '%s\n' "$body" | "$SHA256_BIN" | cut -d' ' -f1)"
    printf '%s\nPLAN_SHA256=%s\n' "$body" "$digest"
}

atomic_state_file() {
    local path="$1" mode="$2"
    python3 -c '
import os,sys,tempfile
path=sys.argv[1]; mode=int(sys.argv[2],8); data=sys.stdin.buffer.read()
os.makedirs(os.path.dirname(path),mode=0o700,exist_ok=True)
fd,tmp=tempfile.mkstemp(prefix=".c1-state-",dir=os.path.dirname(path))
try:
 os.fchmod(fd,mode)
 with os.fdopen(fd,"wb") as f: f.write(data); f.flush(); os.fsync(f.fileno())
 os.replace(tmp,path)
 dfd=os.open(os.path.dirname(path),os.O_DIRECTORY); os.fsync(dfd); os.close(dfd)
except BaseException:
 try: os.close(fd)
 except OSError: pass
 try: os.unlink(tmp)
 except OSError: pass
 raise
' "$path" "$mode"
}

plan_value() {
    local plan="$1" key="$2"
    printf '%s\n' "$plan" | sed -n "s/^${key}=//p"
}

verify_saved_identity() {
    local plan="$1" path expected model size sector resolved kind actual_model actual_size actual_sector
    local root_source root_disk base holder os_layout pvs_output
    path="$(plan_value "$plan" 1TB_PATH)"
    expected="$(plan_value "$plan" 1TB_DEVICE)"
    model="$(plan_value "$plan" 1TB_MODEL)"
    size="$(plan_value "$plan" 1TB_SIZE)"
    sector="$(plan_value "$plan" 1TB_LOGICAL_SECTOR)"
    [[ "$path" == "$BY_ID_ROOT"/* && "$path" != *-part* && -L "$path" ]] \
        || fail 'saved 1TB stable path is no longer valid'
    resolved="$("$REALPATH_BIN" -e -- "$path")" || fail '1TB stable path cannot be resolved'
    [[ "$resolved" == "$expected" && "$resolved" == "$DEV_ROOT"/* ]] \
        || fail '1TB stable path no longer resolves to the approved device'
    kind="$("$LSBLK_BIN" -dnro TYPE -- "$resolved")" || fail 'cannot inspect 1TB device type'
    [[ "$kind" == disk ]] || fail 'approved 1TB target is no longer a whole disk'
    actual_model="$("$LSBLK_BIN" -dnro MODEL -- "$resolved" | tr -s ' ' | sed 's/^ //;s/ $//')"
    actual_size="$("$LSBLK_BIN" -bdnro SIZE -- "$resolved")"
    actual_sector="$("$LSBLK_BIN" -bdnro LOG-SEC -- "$resolved")"
    [[ "$actual_model" == "$model" && "$actual_size" == "$size" && "$actual_sector" == "$sector" ]] \
        || fail '1TB model, size, or sector size changed since approval'
    root_source="$("$FINDMNT_BIN" -n -o SOURCE /)" || fail 'cannot identify root filesystem source'
    root_disk="$("$LSBLK_BIN" -s -dnro PATH -- "$root_source" | tail -n 1)" \
        || fail 'cannot identify root backing disk'
    [[ "$resolved" != "$root_disk" ]] || fail '1TB target backs the root filesystem'
    os_layout="$("$LSBLK_BIN" -nrpo MOUNTPOINTS,NAME -- "$resolved")" \
        || fail 'cannot inspect 1TB OS mount relationships'
    if grep -Eq '(^|[[:space:]])(/|/boot|/boot/efi|\[SWAP\])([[:space:]]|$)' <<<"$os_layout"; then
        fail '1TB target backs an OS or swap filesystem'
    fi
    base="${resolved##*/}"
    if [[ -d "$SYS_BLOCK_ROOT/$base/holders" ]]; then
        for holder in "$SYS_BLOCK_ROOT/$base/holders"/*; do
            [[ ! -e "$holder" ]] || fail '1TB target has active holders'
        done
    fi
    pvs_output="$("$PVS_BIN" --noheadings -o pv_name 2>/dev/null)" \
        || fail 'failed to inspect LVM physical volumes'
    if grep -Fxq "$resolved" <<<"$pvs_output"; then
        fail '1TB target is an LVM physical volume'
    fi
    assert_no_raid "$resolved" 1TB
    nvme_health "$resolved" 1TB >/dev/null
}


assert_unmounted_and_unused() {
    local device="$1" context="$2" mountpoints status
    mountpoints="$("$LSBLK_BIN" -nrpo MOUNTPOINTS -- "$device")" \
        || fail "cannot inspect $context mounts"
    [[ -z "${mountpoints//[[:space:]]/}" ]] || fail "$context has a mounted filesystem"
    set +e
    "$FUSER_BIN" -s "$device"
    status=$?
    set -e
    case "$status" in
        1) ;;
        0) fail "$context is in use" ;;
        *) fail "failed to inspect $context open users" ;;
    esac
}

assert_pristine_before_wipe() {
    local device="$1" plan="$2" children signatures
    children="$("$LSBLK_BIN" -nrpo NAME -- "$device")" || fail 'cannot inspect 1TB children'
    [[ "$children" == "$device" ]] || fail '1TB target gained partitions after approval'
    assert_unmounted_and_unused "$device" '1TB target'
    signatures="$(signature_state "$device")"
    [[ "$signatures" == "$(plan_value "$plan" 1TB_SIGNATURES)" ]] \
        || fail '1TB signatures changed after approval'
    nvme_health "$device" 1TB >/dev/null
}

assert_partial_layout_safe_to_recreate() {
    local device="$1" nodes node signatures base holder pvs_output status
    assert_unmounted_and_unused "$device" 'partial GPT layout'
    nodes="$("$LSBLK_BIN" -nrpo NAME -- "$device")" || fail 'cannot inspect partial GPT children'
    pvs_output="$("$PVS_BIN" --noheadings -o pv_name 2>/dev/null)" \
        || fail 'failed to inspect partial GPT LVM state'
    while IFS= read -r node; do
        [[ -n "$node" && "$node" != "$device" ]] || continue
        signatures="$(signature_state "$node")"
        [[ "$signatures" == none ]] \
            || fail 'partial GPT child gained a filesystem or other signature'
        if grep -Fxq "$node" <<<"$pvs_output"; then
            fail 'partial GPT child became an LVM physical volume'
        fi
        assert_no_raid "$node" 'partial GPT child'
        base="${node##*/}"
        if [[ -d "$SYS_BLOCK_ROOT/$base/holders" ]]; then
            for holder in "$SYS_BLOCK_ROOT/$base/holders"/*; do
                [[ ! -e "$holder" ]] || fail 'partial GPT child has active holders'
            done
        fi
        set +e
        "$FUSER_BIN" -s "$node"
        status=$?
        set -e
        case "$status" in
            1) ;;
            0) fail 'partial GPT child is in use' ;;
            *) fail 'failed to inspect partial GPT child open users' ;;
        esac
    done <<<"$nodes"
    nvme_health "$device" 1TB >/dev/null
}
partition_path() {
    local device="$1" number="$2" part
    part="${device}p${number}"
    [[ -e "$part" ]] || part="${device}${number}"
    if [[ -n "$BLOCK_DEVICE_TEST_BIN" ]]; then
        "$BLOCK_DEVICE_TEST_BIN" "$part" || fail "partition $number for $device did not appear"
    else
        [[ -b "$part" ]] || fail "partition $number for $device did not appear"
    fi
    printf '%s\n' "$part"
}

layout_matches() {
    local device="$1" plan="$2" document
    document="$("$SFDISK_BIN" --json "$device" 2>/dev/null)" || return 1
    python3 -c '
import json,sys
x=json.load(sys.stdin).get("partitiontable",{})
p=x.get("partitions",[])
expected_type="0FC63DAF-8483-4772-8E79-3D69D8477DE4"
expected=[
 (int(sys.argv[1]),int(sys.argv[2]),"c1_librefs",expected_type),
 (int(sys.argv[3]),int(sys.argv[4]),"c1_applications",expected_type),
]
actual=[
 (i.get("start"),i.get("size"),i.get("name"),str(i.get("type","")).upper())
 for i in p
]
ok=(x.get("label")=="gpt" and x.get("unit")=="sectors" and actual==expected)
raise SystemExit(0 if ok else 1)
' \
        "$(plan_value "$plan" PART1_START)" \
        "$(( $(plan_value "$plan" PART1_END) - $(plan_value "$plan" PART1_START) + 1 ))" \
        "$(plan_value "$plan" PART2_START)" \
        "$(( $(plan_value "$plan" PART2_END) - $(plan_value "$plan" PART2_START) + 1 ))" \
        <<<"$document"
}

ensure_layout() {
    local device="$1" plan="$2" marker="$STATE_DIR/layout.created"
    local pending="$STATE_DIR/layout.pending" digest
    digest="$(plan_value "$plan" PLAN_SHA256)"
    if layout_matches "$device" "$plan"; then
        [[ -r "$marker" ]] || printf '%s\n' "$digest" | atomic_state_file "$marker" 0600
        rm -f "$pending"
        return
    fi
    [[ ! -e "$marker" ]] || fail 'persisted GPT layout no longer matches the approved plan'
    if [[ -r "$pending" ]]; then
        [[ "$(cat "$pending")" == "$digest" ]] || fail 'GPT pending digest differs from approved plan'
        assert_partial_layout_safe_to_recreate "$device"
    else
        assert_pristine_before_wipe "$device" "$plan"
        [[ -e "$STATE_DIR/1TB.no-gpt.before" ]] \
            || printf 'no GPT signature was present in the approved plan\n' \
                | atomic_state_file "$STATE_DIR/1TB.no-gpt.before" 0600
        [[ -e "$STATE_DIR/1TB.signatures.before.json" ]] \
            || "$WIPEFS_BIN" --no-act --json -- "$device" \
                | atomic_state_file "$STATE_DIR/1TB.signatures.before.json" 0600
        printf '%s\n' "$digest" | atomic_state_file "$pending" 0600
    fi
    "$SGDISK_BIN" --zap-all "$device"
    "$SGDISK_BIN" --clear \
        --new="1:$(plan_value "$plan" PART1_START):$(plan_value "$plan" PART1_END)" \
        --typecode=1:8300 --change-name=1:c1_librefs \
        --new="2:$(plan_value "$plan" PART2_START):$(plan_value "$plan" PART2_END)" \
        --typecode=2:8300 --change-name=2:c1_applications "$device"
    "$PARTPROBE_BIN" "$device"
    "$UDEVADM_BIN" settle
    layout_matches "$device" "$plan" || fail 'created GPT layout does not match approved plan'
    printf '%s\n' "$digest" | atomic_state_file "$marker" 0600
    rm -f "$pending"
}

assert_mount() {
    local target="$1" uuid="$2" source options
    "$MOUNTPOINT_BIN" -q "$target" || fail "$target is not mounted"
    source="$("$FINDMNT_BIN" -n -o UUID,FSTYPE,OPTIONS --target "$target")" \
        || fail "cannot inspect $target"
    [[ "$source" == "$uuid xfs "* || "$source" == "$uuid xfs,"* ]] \
        || fail "$target has wrong UUID or filesystem"
    options="${source#*xfs }"
    [[ ",$options," == *,rw,* ]] || fail "$target is not read-write"
    "$XFS_INFO_BIN" "$target" | grep -Eq 'ftype=1' || fail "$target XFS lacks ftype=1"
}

commit_fstab() {
    local mount_path="$1" uuid="$2"
    python3 - "$FSTAB" "$mount_path" "$uuid" <<'PY'
import os,sys,tempfile
path,mount,uuid=sys.argv[1:]
old=open(path).readlines() if os.path.exists(path) else []
lines=[x for x in old if not (x.strip() and not x.lstrip().startswith("#") and len(x.split())>1 and x.split()[1]==mount)]
lines.append(f"UUID={uuid} {mount} xfs defaults,noatime 0 2\n")
fd,tmp=tempfile.mkstemp(prefix=".c1-fstab-",dir=os.path.dirname(path) or ".",text=True)
try:
 with os.fdopen(fd,"w") as f: f.writelines(lines); f.flush(); os.fsync(f.fileno())
 os.chmod(tmp,0o644); os.replace(tmp,path)
 dfd=os.open(os.path.dirname(path) or ".",os.O_DIRECTORY); os.fsync(dfd); os.close(dfd)
except BaseException:
 try: os.close(fd)
 except OSError: pass
 try: os.unlink(tmp)
 except OSError: pass
 raise
PY
}

assert_fstab_entry() {
    local mount_path="$1" uuid="$2"
    python3 - "$FSTAB" "$mount_path" "$uuid" <<'PY'
import sys
path,mount,uuid=sys.argv[1:]; rows=[]
for line in open(path):
 s=line.strip()
 if not s or s.startswith("#"): continue
 fields=s.split()
 if len(fields)>1 and fields[1]==mount: rows.append(fields)
ok=(len(rows)==1 and rows[0][0]==f"UUID={uuid}" and rows[0][2]=="xfs" and rows[0][3]=="defaults,noatime" and rows[0][4:6]==["0","2"])
raise SystemExit(0 if ok else 1)
PY
}

finish_pending() {
    local device="$1" number="$2" label="$3" mount_path="$4"
    local pending="$STATE_DIR/${label}.pending" complete="$STATE_DIR/${label}.uuid"
    local uuid part actual_uuid actual_label
    [[ -r "$pending" && ! -e "$complete" ]] || fail "$label pending state is invalid"
    IFS= read -r uuid <"$pending"
    [[ "$uuid" =~ ^[[:alnum:]-]+$ ]] || fail "$label pending UUID is invalid"
    part="$(partition_path "$device" "$number")"
    actual_uuid="$("$BLKID_BIN" -s UUID -o value "$part")"
    actual_label="$("$BLKID_BIN" -s LABEL -o value "$part")"
    [[ "$actual_uuid" == "$uuid" && "$actual_label" == "$label" ]] \
        || fail "$label pending filesystem identity changed"
    "$INSTALL_BIN" -d -m 0755 "$mount_path"
    if ! "$MOUNTPOINT_BIN" -q "$mount_path"; then
        "$MOUNT_BIN" "$part" "$mount_path" || fail "failed to mount $label filesystem"
    fi
    assert_mount "$mount_path" "$uuid"
    commit_fstab "$mount_path" "$uuid"
    assert_fstab_entry "$mount_path" "$uuid" || fail "$label fstab verification failed"
    mv -f "$pending" "$complete"
}

provision_partition() {
    local device="$1" number="$2" label="$3" mount_path="$4"
    local complete="$STATE_DIR/${label}.uuid" pending="$STATE_DIR/${label}.pending"
    local part uuid actual_label actual_type
    if [[ -r "$complete" ]]; then
        [[ ! -e "$pending" ]] || fail "$label has both complete and pending state"
        IFS= read -r uuid <"$complete"
        assert_mount "$mount_path" "$uuid"
        assert_fstab_entry "$mount_path" "$uuid" || fail "$label fstab verification failed"
        return
    fi
    if [[ -r "$pending" ]]; then
        finish_pending "$device" "$number" "$label" "$mount_path"
        return
    fi
    part="$(partition_path "$device" "$number")"
    actual_label="$("$BLKID_BIN" -s LABEL -o value "$part" 2>/dev/null || true)"
    actual_type="$("$BLKID_BIN" -s TYPE -o value "$part" 2>/dev/null || true)"
    [[ -z "$actual_type" || ( "$actual_type" == xfs && "$actual_label" == "$label" ) ]] \
        || fail "$label partition has an unexpected filesystem"
    "$MKFS_XFS_BIN" -f -m crc=1,reflink=1 -n ftype=1 -L "$label" "$part"
    uuid="$("$BLKID_BIN" -s UUID -o value "$part")"
    [[ "$uuid" =~ ^[[:alnum:]-]+$ ]] || fail "$label filesystem UUID is invalid"
    printf '%s\n' "$uuid" | atomic_state_file "$pending" 0600
    finish_pending "$device" "$number" "$label" "$mount_path"
}

verify_installed() {
    local librefs_uuid applications_uuid root_source docker_source containerd_source plan device
    [[ -r "$STATE_DIR/approved-plan" ]] || fail 'approved storage plan state is missing'
    plan="$(cat "$STATE_DIR/approved-plan")"
    verify_saved_identity "$plan"
    device="$(plan_value "$plan" 1TB_DEVICE)"
    layout_matches "$device" "$plan" || fail 'installed GPT layout differs from approved plan'
    [[ -r "$STATE_DIR/c1_librefs.uuid" && -r "$STATE_DIR/c1_applications.uuid" ]] \
        || fail 'installed filesystem UUID state is missing'
    IFS= read -r librefs_uuid <"$STATE_DIR/c1_librefs.uuid"
    IFS= read -r applications_uuid <"$STATE_DIR/c1_applications.uuid"
    assert_mount /srv/librefs "$librefs_uuid"
    assert_mount /srv/applications "$applications_uuid"
    assert_fstab_entry /srv/librefs "$librefs_uuid" || fail 'libreFS fstab entry verification failed'
    assert_fstab_entry /srv/applications "$applications_uuid" \
        || fail 'applications fstab entry verification failed'
    [[ "$("$STAT_BIN" -c '%u:%g:%a' /srv/librefs/data)" == 1000:1000:750 ]] \
        || fail 'libreFS data directory state mismatch'
    [[ "$("$STAT_BIN" -c '%u:%g:%a' /srv/applications)" == 0:0:755 ]] \
        || fail 'applications mount root state mismatch'
    root_source="$("$FINDMNT_BIN" -n -o SOURCE --target /)" \
        || fail 'cannot inspect OS root filesystem'
    docker_source="$("$FINDMNT_BIN" -n -o SOURCE --target /var/lib/docker)" \
        || fail 'cannot inspect Docker root filesystem'
    containerd_source="$("$FINDMNT_BIN" -n -o SOURCE --target /var/lib/containerd)" \
        || fail 'cannot inspect containerd root filesystem'
    [[ "$docker_source" == "$root_source" ]] \
        || fail 'Docker data-root is not on the OS root filesystem'
    [[ "$containerd_source" == "$root_source" ]] \
        || fail 'containerd root is not on the OS root filesystem'
    printf 'c1 split storage and OS-resident Docker roots match installed state\n'
}

apply_plan() {
    [[ "$("$ID_BIN" -u)" == 0 ]] || fail 'apply requires root'
    local path="$1" reviewed="$2" current approval expected body stored="$STATE_DIR/approved-plan"
    local device
    [[ "$reviewed" =~ ^[0-9a-f]{64}$ ]] || fail 'reviewed plan digest is invalid'
    "$INSTALL_BIN" -d -m 0700 "$STATE_DIR"
    if [[ -r "$stored" ]]; then
        current="$(cat "$stored")"
        [[ "$(plan_value "$current" PLAN_SHA256)" == "$reviewed" ]] \
            || fail 'persisted plan digest differs from invocation'
        [[ "$(plan_value "$current" 1TB_PATH)" == "$path" ]] \
            || fail 'persisted plan path differs from invocation'
        body="${current%$'\n'PLAN_SHA256=*}"
        [[ "$(printf '%s\n' "$body" | "$SHA256_BIN" | cut -d' ' -f1)" == "$reviewed" ]] \
            || fail 'persisted plan content failed digest verification'
    else
        current="$(make_plan "$path")"
        [[ "$(plan_value "$current" PLAN_SHA256)" == "$reviewed" ]] \
            || fail 'reviewed plan digest does not match immediate evidence'
    fi
    IFS= read -r -d '' approval || true
    expected="APPROVE C1 STORAGE
1TB=$path
PLAN_SHA256=$reviewed
1TB_SIGNATURES=$(plan_value "$current" 1TB_SIGNATURES)
PARTITION_LAYOUT=50% LIBREFS + 50% APPLICATIONS
ACKNOWLEDGE_WIPE=ERASE APPROVED 1TB TARGET ONLY"
    [[ "$approval" == "$expected" ]] \
        || fail 'approval input is not byte-identical to the reviewed plan binding'
    if [[ ! -e "$stored" ]]; then
        printf '%s\n' "$current" | atomic_state_file "$stored" 0600
    fi
    verify_saved_identity "$current"
    device="$(plan_value "$current" 1TB_DEVICE)"
    ensure_layout "$device" "$current"
    provision_partition "$device" 1 c1_librefs /srv/librefs
    provision_partition "$device" 2 c1_applications /srv/applications
    "$INSTALL_BIN" -d -m 0750 -o 1000 -g 1000 /srv/librefs/data
    "$INSTALL_BIN" -d -m 0755 -o root -g root /srv/applications
    verify_installed >/dev/null
    "$SYSTEMCTL_BIN" enable --now fstrim.timer
    printf 'c1 split storage apply completed or safely resumed; verification passed\n'
}

[[ $# -ge 1 ]] || usage
case "$1" in
    check) [[ $# == 2 ]] || usage; evidence "$2" >/dev/null; printf 'c1 1TB target passes read-only checks\n' ;;
    plan) [[ $# == 2 ]] || usage; make_plan "$2" ;;
    apply) [[ $# == 3 ]] || usage; apply_plan "$2" "$3" ;;
    verify) [[ $# == 1 ]] || usage; verify_installed ;;
    *) usage ;;
esac
