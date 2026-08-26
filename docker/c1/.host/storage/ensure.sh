#!/usr/bin/env bash
set -euo pipefail
umask 077

REALPATH_BIN="${REALPATH_BIN:-realpath}"; LSBLK_BIN="${LSBLK_BIN:-lsblk}"; FINDMNT_BIN="${FINDMNT_BIN:-findmnt}"
WIPEFS_BIN="${WIPEFS_BIN:-wipefs}"; SMARTCTL_BIN="${SMARTCTL_BIN:-smartctl}"; PVS_BIN="${PVS_BIN:-pvs}"
MDADM_BIN="${MDADM_BIN:-mdadm}"; FUSER_BIN="${FUSER_BIN:-fuser}"; SHA256_BIN="${SHA256_BIN:-sha256sum}"
SGDISK_BIN="${SGDISK_BIN:-sgdisk}"; PARTPROBE_BIN="${PARTPROBE_BIN:-partprobe}"; UDEVADM_BIN="${UDEVADM_BIN:-udevadm}"
MKFS_XFS_BIN="${MKFS_XFS_BIN:-mkfs.xfs}"; BLKID_BIN="${BLKID_BIN:-blkid}"; MOUNT_BIN="${MOUNT_BIN:-mount}"
MOUNTPOINT_BIN="${MOUNTPOINT_BIN:-mountpoint}"; XFS_INFO_BIN="${XFS_INFO_BIN:-xfs_info}"; INSTALL_BIN="${INSTALL_BIN:-install}"
ID_BIN="${ID_BIN:-id}"; STAT_BIN="${STAT_BIN:-stat}"; SYSTEMCTL_BIN="${SYSTEMCTL_BIN:-systemctl}"; BLOCK_DEVICE_TEST_BIN="${BLOCK_DEVICE_TEST_BIN:-}"
FSTAB="${FSTAB:-/etc/fstab}"; STATE_DIR="${STATE_DIR:-/var/lib/c1-storage}"; SYS_BLOCK_ROOT="${SYS_BLOCK_ROOT:-/sys/class/block}"
BY_ID_ROOT="${BY_ID_ROOT:-/dev/disk/by-id}"; DEV_ROOT="${DEV_ROOT:-/dev}"
readonly REALPATH_BIN LSBLK_BIN FINDMNT_BIN WIPEFS_BIN SMARTCTL_BIN PVS_BIN MDADM_BIN FUSER_BIN SHA256_BIN
readonly SGDISK_BIN PARTPROBE_BIN UDEVADM_BIN MKFS_XFS_BIN BLKID_BIN MOUNT_BIN MOUNTPOINT_BIN XFS_INFO_BIN INSTALL_BIN ID_BIN STAT_BIN SYSTEMCTL_BIN
readonly FSTAB STATE_DIR SYS_BLOCK_ROOT BY_ID_ROOT DEV_ROOT BLOCK_DEVICE_TEST_BIN
fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
usage() { printf 'Usage: %s {check|plan} <1TB-by-id> <512GB-by-id>\n       %s apply <1TB-by-id> <512GB-by-id> <PLAN_SHA256>\n       %s verify\n' "$0" "$0" "$0" >&2; exit 64; }

stable_device() {
    local path="$1" role="$2" resolved kind children mountpoints root_source root_disk base holder os_layout pvs_output status
    [[ "$path" == "$BY_ID_ROOT"/* && "$path" != *-part* ]] || fail "$role input is not a whole-disk stable by-id path"
    [[ -L "$path" ]] || fail "$role stable path is not a symlink"
    resolved="$("$REALPATH_BIN" -e -- "$path")" || fail "$role stable path cannot be resolved"
    [[ "$resolved" == "$DEV_ROOT"/* ]] || fail "$role stable path resolves outside the device directory"
    kind="$("$LSBLK_BIN" -dnro TYPE -- "$resolved")" || fail "cannot inspect $role device type"
    [[ "$kind" == disk ]] || fail "$role target is not a whole disk"
    children="$("$LSBLK_BIN" -nrpo NAME -- "$resolved")" || fail "cannot inspect $role children"
    [[ "$children" == "$resolved" ]] || fail "$role target has partitions or child devices"
    mountpoints="$("$LSBLK_BIN" -nrpo MOUNTPOINTS -- "$resolved")" || fail "cannot inspect $role mounts"
    [[ -z "${mountpoints//[[:space:]]/}" ]] || fail "$role target or child is mounted"
    root_source="$("$FINDMNT_BIN" -n -o SOURCE /)" || fail 'cannot identify root filesystem source'
    root_disk="$("$LSBLK_BIN" -s -dnro PATH -- "$root_source" | tail -n 1)" || fail 'cannot identify root backing disk'
    [[ "$resolved" != "$root_disk" ]] || fail "$role target backs the root filesystem"
    os_layout="$("$LSBLK_BIN" -nrpo MOUNTPOINTS,NAME -- "$resolved")" || fail "cannot inspect $role OS mount relationships"
    if grep -Eq '(^|[[:space:]])(/|/boot|/boot/efi|\[SWAP\])([[:space:]]|$)' <<<"$os_layout"; then fail "$role target backs an OS or swap filesystem"; fi
    base="${resolved##*/}"
    if [[ -d "$SYS_BLOCK_ROOT/$base/holders" ]]; then
        for holder in "$SYS_BLOCK_ROOT/$base/holders"/*; do [[ ! -e "$holder" ]] || fail "$role target has active holders"; done
    fi
    pvs_output="$("$PVS_BIN" --noheadings -o pv_name 2>/dev/null)" || fail 'failed to inspect LVM physical volumes'
    if grep -Fxq "$resolved" <<<"$pvs_output"; then fail "$role target is an LVM physical volume"; fi
    assert_no_raid "$resolved" "$role"
    set +e; "$FUSER_BIN" -s "$resolved"; status=$?; set -e
    case "$status" in 1) ;; 0) fail "$role target is in use" ;; *) fail 'failed to inspect open-device users' ;; esac
    "$SMARTCTL_BIN" -H "$resolved" >/dev/null || fail "$role target lacks passing health evidence"
    printf '%s\n' "$resolved"
}

signature_state() {
    local output
    output="$("$WIPEFS_BIN" --no-act --json -- "$1")" || fail 'signature inspection failed'
    python3 -c 'import json,sys; x=json.load(sys.stdin); s=x.get("signatures",[]); print("none" if not s else ";".join(sorted("%s@%s"%(i.get("type","unknown"),i.get("offset","unknown")) for i in s)))' <<<"$output"
}

approved_half_signatures() {
    local state="$1" signature saw_gpt=false
    [[ "$state" != none ]] || return 0
    IFS=';' read -r -a signatures <<<"$state"
    for signature in "${signatures[@]}"; do
        case "$signature" in
            gpt@*) saw_gpt=true ;;
            PMBR@*) ;;
            *) return 1 ;;
        esac
    done
    [[ "$saw_gpt" == true ]]
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

evidence() {
    local one_path="$1" half_path="$2" one half one_model one_size half_model half_size one_sig half_sig
    one="$(stable_device "$one_path" 1TB)"; half="$(stable_device "$half_path" 512GB)"
    [[ "$one" != "$half" ]] || fail 'both roles resolve to the same disk'
    one_model="$("$LSBLK_BIN" -dnro MODEL -- "$one" | tr -s ' ' | sed 's/^ //;s/ $//')"; one_size="$("$LSBLK_BIN" -bdnro SIZE -- "$one")"
    half_model="$("$LSBLK_BIN" -dnro MODEL -- "$half" | tr -s ' ' | sed 's/^ //;s/ $//')"; half_size="$("$LSBLK_BIN" -bdnro SIZE -- "$half")"
    [[ "$one_size" =~ ^[0-9]+$ && "$one_size" -ge 900000000000 && "$one_size" -le 1100000000000 ]] || fail '1TB target size is outside the approved range'
    [[ "$half_size" =~ ^[0-9]+$ && "$half_size" -ge 450000000000 && "$half_size" -le 550000000000 ]] || fail '512GB target size is outside the approved range'
    [[ -n "$one_model" && -n "$half_model" ]] || fail 'target model is unavailable'
    one_sig="$(signature_state "$one")"; half_sig="$(signature_state "$half")"
    [[ "$one_sig" == none ]] || fail '1TB target has an unapproved signature'
    approved_half_signatures "$half_sig" || fail '512GB target has an unapproved signature'
    printf '%s\n' \
      'C1_STORAGE_PLAN_VERSION=1' "1TB_PATH=$one_path" "1TB_DEVICE=$one" "1TB_MODEL=$one_model" "1TB_SIZE=$one_size" "1TB_SIGNATURES=$one_sig" \
      '1TB_ACTION=erase-gpt;gpt-single-xfs-c1_containers' '1TB_MOUNT=/srv/containers' \
      "512GB_PATH=$half_path" "512GB_DEVICE=$half" "512GB_MODEL=$half_model" "512GB_SIZE=$half_size" "512GB_SIGNATURES=$half_sig" \
      '512GB_ACTION=erase-gpt;gpt-single-xfs-c1_librefs' '512GB_MOUNT=/srv/librefs' \
      'OS_DISK_EXCLUDED=true' 'ROLLBACK=formatting-cannot-recover-existing-content'
}

make_plan() {
    local body digest
    body="$(evidence "$1" "$2")"
    digest="$(printf '%s\n' "$body" | "$SHA256_BIN" | cut -d' ' -f1)"
    printf '%s\nPLAN_SHA256=%s\n' "$body" "$digest"
}

assert_mount() {
    local target="$1" uuid="$2" source options
    "$MOUNTPOINT_BIN" -q "$target" || fail "$target is not mounted"
    source="$("$FINDMNT_BIN" -n -o UUID,FSTYPE,OPTIONS --target "$target")" || fail "cannot inspect $target"
    [[ "$source" == "$uuid xfs "* || "$source" == "$uuid xfs,"* ]] || fail "$target has wrong UUID or filesystem"
    options="${source#*xfs }"; [[ ",$options," == *,rw,* ]] || fail "$target is not read-write"
    "$XFS_INFO_BIN" "$target" | grep -Eq 'ftype=1' || fail "$target XFS lacks ftype=1"
}

atomic_state_file() {
    local path="$1" mode="$2"
    python3 -c '
import os,sys,tempfile
path=sys.argv[1]
mode=int(sys.argv[2],8)
data=sys.stdin.buffer.read()
os.makedirs(os.path.dirname(path),mode=0o700,exist_ok=True)
fd,tmp=tempfile.mkstemp(prefix=".c1-state-",dir=os.path.dirname(path))
try:
 os.fchmod(fd,mode)
 with os.fdopen(fd,"wb") as f:
  f.write(data)
  f.flush()
  os.fsync(f.fileno())
 os.replace(tmp,path)
 dfd=os.open(os.path.dirname(path),os.O_DIRECTORY)
 os.fsync(dfd)
 os.close(dfd)
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
    local plan="$1" prefix="$2" role="$3" path expected model size resolved kind actual_model actual_size
    local root_source root_disk base holder os_layout pvs_output status
    path="$(plan_value "$plan" "${prefix}_PATH")"
    expected="$(plan_value "$plan" "${prefix}_DEVICE")"
    model="$(plan_value "$plan" "${prefix}_MODEL")"
    size="$(plan_value "$plan" "${prefix}_SIZE")"
    [[ "$path" == "$BY_ID_ROOT"/* && "$path" != *-part* && -L "$path" ]] \
        || fail "$role saved stable path is no longer valid"
    resolved="$("$REALPATH_BIN" -e -- "$path")" || fail "$role stable path cannot be resolved"
    [[ "$resolved" == "$expected" && "$resolved" == "$DEV_ROOT"/* ]] \
        || fail "$role stable path no longer resolves to the approved device"
    kind="$("$LSBLK_BIN" -dnro TYPE -- "$resolved")" || fail "cannot inspect $role device type"
    [[ "$kind" == disk ]] || fail "$role approved target is no longer a whole disk"
    actual_model="$("$LSBLK_BIN" -dnro MODEL -- "$resolved" | tr -s ' ' | sed 's/^ //;s/ $//')"
    actual_size="$("$LSBLK_BIN" -bdnro SIZE -- "$resolved")"
    [[ "$actual_model" == "$model" && "$actual_size" == "$size" ]] \
        || fail "$role model or size changed since approval"
    root_source="$("$FINDMNT_BIN" -n -o SOURCE /)" || fail 'cannot identify root filesystem source'
    root_disk="$("$LSBLK_BIN" -s -dnro PATH -- "$root_source" | tail -n 1)" \
        || fail 'cannot identify root backing disk'
    [[ "$resolved" != "$root_disk" ]] || fail "$role target backs the root filesystem"
    os_layout="$("$LSBLK_BIN" -nrpo MOUNTPOINTS,NAME -- "$resolved")" \
        || fail "cannot inspect $role OS mount relationships"
    if grep -Eq '(^|[[:space:]])(/|/boot|/boot/efi|\[SWAP\])([[:space:]]|$)' <<<"$os_layout"; then
        fail "$role target backs an OS or swap filesystem"
    fi
    base="${resolved##*/}"
    if [[ -d "$SYS_BLOCK_ROOT/$base/holders" ]]; then
        for holder in "$SYS_BLOCK_ROOT/$base/holders"/*; do
            [[ ! -e "$holder" ]] || fail "$role target has active holders"
        done
    fi
    pvs_output="$("$PVS_BIN" --noheadings -o pv_name 2>/dev/null)" \
        || fail 'failed to inspect LVM physical volumes'
    if grep -Fxq "$resolved" <<<"$pvs_output"; then
        fail "$role target is an LVM physical volume"
    fi
    assert_no_raid "$resolved" "$role"
    "$SMARTCTL_BIN" -H "$resolved" >/dev/null \
        || fail "$role target lacks passing health evidence"
}

partition_path() {
    local device="$1" part
    part="${device}p1"
    [[ -e "$part" ]] || part="${device}1"
    if [[ -n "$BLOCK_DEVICE_TEST_BIN" ]]; then
        "$BLOCK_DEVICE_TEST_BIN" "$part" || fail "partition for $device did not appear"
    else
        [[ -b "$part" ]] || fail "partition for $device did not appear"
    fi
    printf '%s\n' "$part"
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
 with os.fdopen(fd,"w") as f:
  f.writelines(lines)
  f.flush()
  os.fsync(f.fileno())
 os.chmod(tmp,0o644)
 os.replace(tmp,path)
 dfd=os.open(os.path.dirname(path) or ".",os.O_DIRECTORY)
 os.fsync(dfd)
 os.close(dfd)
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
path,mount,uuid=sys.argv[1:]
rows=[]
for line in open(path):
 s=line.strip()
 if not s or s.startswith("#"):
  continue
 fields=s.split()
 if len(fields)>1 and fields[1]==mount:
  rows.append(fields)
ok=(len(rows)==1 and rows[0][0]==f"UUID={uuid}" and rows[0][2]=="xfs"
 and rows[0][3]=="defaults,noatime" and rows[0][4:6]==["0","2"])
raise SystemExit(0 if ok else 1)
PY
}

finish_pending() {
    local device="$1" label="$2" mount_path="$3" pending="$STATE_DIR/${label}.pending"
    local complete="$STATE_DIR/${label}.uuid" uuid part actual_uuid
    [[ -r "$pending" && ! -e "$complete" ]] || fail "$label pending state is invalid"
    IFS= read -r uuid <"$pending"
    [[ "$uuid" =~ ^[[:alnum:]-]+$ ]] || fail "$label pending UUID is invalid"
    part="$(partition_path "$device")"
    actual_uuid="$("$BLKID_BIN" -s UUID -o value "$part")"
    [[ "$actual_uuid" == "$uuid" ]] || fail "$label pending filesystem UUID changed"
    "$INSTALL_BIN" -d -m 0755 "$mount_path"
    if ! "$MOUNTPOINT_BIN" -q "$mount_path"; then
        "$MOUNT_BIN" "$part" "$mount_path" || fail "failed to mount $label filesystem"
    fi
    assert_mount "$mount_path" "$uuid"
    commit_fstab "$mount_path" "$uuid"
    assert_fstab_entry "$mount_path" "$uuid" || fail "$label fstab entry verification failed"
    mv -f "$pending" "$complete"
}

provision_one() {
    local device="$1" label="$2" mount_path="$3" initial_signatures="$4"
    local part uuid mountpoints
    "$INSTALL_BIN" -d -m 0700 "$STATE_DIR"
    if [[ "$initial_signatures" == *gpt@* ]]; then
        [[ -e "$STATE_DIR/${label}.gpt.before" ]] \
            || "$SGDISK_BIN" --backup="$STATE_DIR/${label}.gpt.before" "$device" \
            || fail "failed to save pre-write GPT metadata for $device"
    else
        [[ -e "$STATE_DIR/${label}.no-gpt.before" ]] \
            || printf 'no GPT signature was present in the approved plan\n' \
                | atomic_state_file "$STATE_DIR/${label}.no-gpt.before" 0600
    fi
    if [[ ! -e "$STATE_DIR/${label}.signatures.before.json" ]]; then
        "$WIPEFS_BIN" --no-act --json -- "$device" \
            | atomic_state_file "$STATE_DIR/${label}.signatures.before.json" 0600
    fi
    mountpoints="$("$LSBLK_BIN" -nrpo MOUNTPOINTS -- "$device")" \
        || fail "cannot inspect $label mounts before formatting"
    [[ -z "${mountpoints//[[:space:]]/}" ]] \
        || fail "$label has an unexpected mount before formatting"
    "$SGDISK_BIN" --zap-all "$device"
    "$SGDISK_BIN" --clear --new=1:1MiB:0 --typecode=1:8300 --change-name=1:"$label" "$device"
    "$PARTPROBE_BIN" "$device"
    "$UDEVADM_BIN" settle
    part="$(partition_path "$device")"
    "$MKFS_XFS_BIN" -f -m crc=1,reflink=1 -n ftype=1 -L "$label" "$part"
    uuid="$("$BLKID_BIN" -s UUID -o value "$part")"
    [[ "$uuid" =~ ^[[:alnum:]-]+$ ]] || fail 'new filesystem UUID is invalid'
    printf '%s\n' "$uuid" | atomic_state_file "$STATE_DIR/${label}.pending" 0600
    finish_pending "$device" "$label" "$mount_path"
}

provision_role() {
    local device="$1" label="$2" mount_path="$3" initial_signatures="$4"
    local complete="$STATE_DIR/${label}.uuid" pending="$STATE_DIR/${label}.pending" uuid
    if [[ -r "$complete" ]]; then
        [[ ! -e "$pending" ]] || fail "$label has both complete and pending state"
        IFS= read -r uuid <"$complete"
        [[ "$uuid" =~ ^[[:alnum:]-]+$ ]] || fail "$label installed UUID is invalid"
        assert_mount "$mount_path" "$uuid"
        assert_fstab_entry "$mount_path" "$uuid" || fail "$label fstab entry verification failed"
        return
    fi
    if [[ -r "$pending" ]]; then
        finish_pending "$device" "$label" "$mount_path"
        return
    fi
    provision_one "$device" "$label" "$mount_path" "$initial_signatures"
}

verify_installed() {
    local one_uuid half_uuid
    [[ -r "$STATE_DIR/c1_containers.uuid" && -r "$STATE_DIR/c1_librefs.uuid" ]] \
        || fail 'installed filesystem UUID state is missing'
    IFS= read -r one_uuid <"$STATE_DIR/c1_containers.uuid"
    IFS= read -r half_uuid <"$STATE_DIR/c1_librefs.uuid"
    [[ "$one_uuid" =~ ^[[:alnum:]-]+$ && "$half_uuid" =~ ^[[:alnum:]-]+$ ]] \
        || fail 'installed filesystem UUID state is invalid'
    assert_mount /srv/containers "$one_uuid"
    assert_mount /srv/librefs "$half_uuid"
    assert_fstab_entry /srv/containers "$one_uuid" \
        || fail 'container-tier fstab entry verification failed'
    assert_fstab_entry /srv/librefs "$half_uuid" \
        || fail 'libreFS-tier fstab entry verification failed'
    [[ "$("$STAT_BIN" -c '%u:%g:%a' /srv/containers/docker)" == 0:0:711 ]] \
        || fail 'Docker data-root directory state mismatch'
    [[ "$("$STAT_BIN" -c '%u:%g:%a' /srv/containers/containerd)" == 0:0:711 ]] \
        || fail 'containerd root directory state mismatch'
    [[ "$("$STAT_BIN" -c '%u:%g:%a' /srv/librefs/data)" == 1000:1000:750 ]] \
        || fail 'libreFS data directory state mismatch'
    printf 'c1 storage mounts, fstab, filesystems, and directories match installed state\n'
}

apply_plan() {
    [[ "$("$ID_BIN" -u)" == 0 ]] || fail 'apply requires root'
    local one_path="$1" half_path="$2" reviewed="$3" current approval expected one half body
    local one_sig half_sig stored="$STATE_DIR/approved-plan"
    [[ "$reviewed" =~ ^[0-9a-f]{64}$ ]] || fail 'reviewed plan digest is invalid'
    "$INSTALL_BIN" -d -m 0700 "$STATE_DIR"
    if [[ -r "$stored" ]]; then
        current="$(cat "$stored")"
        [[ "$(plan_value "$current" PLAN_SHA256)" == "$reviewed" ]] \
            || fail 'persisted approved plan digest differs from invocation'
        [[ "$(plan_value "$current" 1TB_PATH)" == "$one_path" \
           && "$(plan_value "$current" 512GB_PATH)" == "$half_path" ]] \
            || fail 'persisted approved plan paths differ from invocation'
        body="${current%$'\n'PLAN_SHA256=*}"
        [[ "$(printf '%s\n' "$body" | "$SHA256_BIN" | cut -d' ' -f1)" == "$reviewed" ]] \
            || fail 'persisted approved plan content failed digest verification'
    else
        current="$(make_plan "$one_path" "$half_path")"
        [[ "$(plan_value "$current" PLAN_SHA256)" == "$reviewed" ]] \
            || fail 'reviewed plan digest does not match immediate evidence'
    fi
    IFS= read -r -d '' approval || true
    expected="APPROVE C1 STORAGE
1TB=$one_path
512GB=$half_path
PLAN_SHA256=$reviewed
1TB_SIGNATURES=$(plan_value "$current" 1TB_SIGNATURES)
512GB_SIGNATURES=$(plan_value "$current" 512GB_SIGNATURES)
ACKNOWLEDGE_WIPE=ERASE APPROVED TARGETS ONLY"
    [[ "$approval" == "$expected" ]] \
        || fail 'approval input is not byte-identical to the reviewed plan binding'
    if [[ ! -e "$stored" ]]; then
        printf '%s\n' "$current" | atomic_state_file "$stored" 0600
    fi
    verify_saved_identity "$current" 1TB 1TB
    verify_saved_identity "$current" 512GB 512GB
    one="$(plan_value "$current" 1TB_DEVICE)"
    half="$(plan_value "$current" 512GB_DEVICE)"
    one_sig="$(plan_value "$current" 1TB_SIGNATURES)"
    half_sig="$(plan_value "$current" 512GB_SIGNATURES)"
    provision_role "$one" c1_containers /srv/containers "$one_sig"
    "$INSTALL_BIN" -d -m 0711 -o root -g root \
        /srv/containers/docker /srv/containers/containerd
    provision_role "$half" c1_librefs /srv/librefs "$half_sig"
    "$INSTALL_BIN" -d -m 0750 -o 1000 -g 1000 /srv/librefs/data
    verify_installed >/dev/null
    "$SYSTEMCTL_BIN" enable --now fstrim.timer
    printf 'c1 storage apply completed or safely resumed; verification passed\n'
}

[[ $# -ge 1 ]] || usage
case "$1" in
 check) [[ $# == 3 ]] || usage; evidence "$2" "$3" >/dev/null; printf 'c1 storage targets pass read-only checks\n' ;;
 plan) [[ $# == 3 ]] || usage; make_plan "$2" "$3" ;;
 apply) [[ $# == 4 ]] || usage; apply_plan "$2" "$3" "$4" ;;
 verify) [[ $# == 1 ]] || usage; verify_installed ;;
 *) usage ;;
esac
