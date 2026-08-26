#!/usr/bin/env bash
set -euo pipefail

readonly HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT="$HERE/../ensure.sh"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin" "$work/by-id" "$work/dev" "$work/state" \
    "$work/sys/disk-one/holders" "$work/sys/disk-onep1/holders" "$work/sys/disk-onep2/holders"
touch "$work/dev/disk-one" "$work/fstab"
ln -s "$work/dev/disk-one" "$work/by-id/canary-one"

cat >"$work/bin/fake" <<'FAKE'
#!/usr/bin/env bash
set -eu
name="${0##*/}"
printf '%s %s\n' "$name" "$*" >>"$FAKE_LOG"
case "$name" in
 realpath) readlink "${@: -1}" ;;
 lsblk)
  args=" $* "; dev="${@: -1}"
  if [[ "$args" == *' TYPE '* ]]; then
   if [[ "${FAIL:-}" == type ]]; then echo part; else echo disk; fi
  elif [[ "$args" == *' MOUNTPOINTS,NAME '* ]]; then
   if [[ "${FAIL:-}" == osmount ]]; then printf '/boot %s\n' "$dev"; fi
  elif [[ "$args" == *' MOUNTPOINTS '* ]]; then
   if [[ "${FAIL:-}" == mounted ]]; then echo /mnt; fi
  elif [[ "$args" == *' MODEL '* ]]; then
   if [[ "${FAIL:-}" != model ]]; then echo CANARY_ONE_MODEL; fi
  elif [[ "$args" == *' LOG-SEC '* ]]; then echo 512
  elif [[ "$args" == *' SIZE '* ]]; then
   if [[ "${FAIL:-}" == onesize ]]; then echo 1; else echo 1000204886016; fi
  elif [[ "$args" == *' -s '* ]]; then
   if [[ "${FAIL:-}" == root ]]; then echo "$FAKE_DEV/disk-one"; else echo "$FAKE_DEV/os-root"; fi
  elif [[ "${FAIL:-}" == children ]]; then printf '%s\n%s1\n' "$dev" "$dev"
  elif [[ -e "$FAKE_STATE/layout" || -e "$FAKE_STATE/partial-layout" ]]; then printf '%s\n%sp1\n%sp2\n' "$dev" "$dev" "$dev"
  else echo "$dev"
  fi ;;
 findmnt)
  if [[ "$*" == *' -o SOURCE '* && "$*" == *'/var/lib/docker'* && "${FAIL:-}" == docker-other ]]; then echo "$FAKE_DEV/other"
  elif [[ "$*" == *' -o SOURCE '* && "$*" == *'/var/lib/containerd'* && "${FAIL:-}" == containerd-other ]]; then echo "$FAKE_DEV/other"
  elif [[ "$*" == *' -o SOURCE '* ]]; then echo "$FAKE_DEV/os-root"
  elif [[ "$*" == *' -o UUID,FSTYPE,OPTIONS '* && "$*" == *'/srv/librefs'* ]]; then echo 'canary-librefs-uuid xfs rw,noatime'
  elif [[ "$*" == *' -o UUID,FSTYPE,OPTIONS '* && "$*" == *'/srv/applications'* ]]; then echo 'canary-applications-uuid xfs rw,noatime'
  else exit 91
  fi ;;
 wipefs) if [[ "${FAIL:-}" == signature || ( "${FAIL:-}" == partial-signature && "${@: -1}" == *p1 ) ]]; then echo '{"signatures":[{"type":"ext4","offset":"0x1"}]}'; else echo '{"signatures":[]}'; fi ;;
 smartctl) [[ "${FAIL:-}" != health ]] ;;
 nvme)
  if [[ "${FAIL:-}" == media-errors ]]; then media=941; else media=0; fi
  if [[ "${FAIL:-}" == critical-warning ]]; then critical=1; else critical=0; fi
  if [[ "${FAIL:-}" == spare-low ]]; then spare=4; else spare=100; fi
  printf '{"critical_warning":%s,"media_errors":%s,"avail_spare":%s,"spare_thresh":5,"percent_used":13,"num_err_log_entries":0}\n' \
   "$critical" "$media" "$spare"
  ;;
 pvs) if [[ "${FAIL:-}" == lvm ]]; then printf '%s\n' "$FAKE_DEV/disk-one"; elif [[ "${FAIL:-}" == partial-lvm ]]; then printf '%s\n' "$FAKE_DEV/disk-onep1"; fi ;;
 mdadm) if [[ "${FAIL:-}" == raid || ( "${FAIL:-}" == partial-raid && "${@: -1}" == *p1 ) ]]; then echo 'MD_UUID=safe-canary-array'; exit 0; elif [[ "${FAIL:-}" == mdadm-gpt ]]; then exit 0; else exit 1; fi ;;
 fuser) if [[ "${FAIL:-}" == use || ( "${FAIL:-}" == partial-use && "${@: -1}" == *p1 ) ]]; then exit 0; else exit 1; fi ;;
 sha256sum) command sha256sum ;;
 id) if [[ "${FAIL:-}" == nonroot ]]; then echo 1000; else echo 0; fi ;;
 stat) if [[ "${@: -1}" == /srv/librefs/data ]]; then echo 1000:1000:750; else echo 0:0:755; fi ;;
 install) if [[ "$*" == *"$FAKE_STATE"* ]]; then mkdir -p "$FAKE_STATE"; fi ;;
 sfdisk)
  [[ -e "$FAKE_STATE/layout" || -e "$FAKE_STATE/partial-layout" ]] || exit 1
  if [[ "${FAIL:-}" == layout-drift || -e "$FAKE_STATE/partial-layout" ]]; then p2_start=$((P2_START+2048)); else p2_start="$P2_START"; fi
  if [[ "${FAIL:-}" == layout-type ]]; then p2_type='E6D6D379-F507-44C2-A23C-238F2A3DF928'; else p2_type='0FC63DAF-8483-4772-8E79-3D69D8477DE4'; fi
  printf '{"partitiontable":{"label":"gpt","unit":"sectors","partitions":[{"start":%s,"size":%s,"name":"c1_librefs","type":"0FC63DAF-8483-4772-8E79-3D69D8477DE4"},{"start":%s,"size":%s,"name":"c1_applications","type":"%s"}]}}\n' \
   "$P1_START" "$P1_SIZE" "$p2_start" "$P2_SIZE" "$p2_type"
  ;;
 sgdisk)
  if [[ "$*" == *'--clear'* && "${FAIL:-}" == sgdisk-partial ]]; then
   touch "$FAKE_STATE/partial-layout"
   exit 86
  fi
  if [[ "$*" == *'--clear'* ]]; then
   rm -f "$FAKE_STATE/partial-layout"
   touch "$FAKE_STATE/layout"
  fi
  ;;
 block-test|partprobe|udevadm|systemctl) : ;;
 mkfs.xfs) [[ "${FAIL:-}" != mkfs-fail ]] ;;
 blkid)
  part="${@: -1}"
  if [[ "$*" == *'-s TYPE'* ]]; then
   if [[ "${FAIL:-}" == unexpected-fs ]]; then echo ext4; fi
  elif [[ "$*" == *'-s LABEL'* ]]; then
   if [[ "$part" == *1 ]]; then echo c1_librefs; else echo c1_applications; fi
  elif [[ "$part" == *1 ]]; then echo canary-librefs-uuid
  else echo canary-applications-uuid
  fi ;;
 mountpoint)
  target="${@: -1}"
  [[ -e "$FAKE_STATE/mounted-${target##*/}" ]]
  ;;
 mount)
  [[ "${FAIL:-}" != mount-fail ]] || exit 85
  target="${@: -1}"
  touch "$FAKE_STATE/mounted-${target##*/}"
  ;;
 xfs_info) echo 'naming =version 2 bsize=4096 ascii-ci=0, ftype=1' ;;
 *) exit 90 ;;
esac
FAKE
chmod +x "$work/bin/fake"
for name in realpath lsblk findmnt wipefs smartctl nvme pvs mdadm fuser sha256sum id stat install sfdisk sgdisk block-test partprobe udevadm systemctl mkfs.xfs blkid mountpoint mount xfs_info; do
    ln -s fake "$work/bin/$name"
done

export FAKE_LOG="$work/log" FAKE_DEV="$work/dev" FAKE_STATE="$work/state"
common=(
 BY_ID_ROOT="$work/by-id" DEV_ROOT="$work/dev" SYS_BLOCK_ROOT="$work/sys"
 STATE_DIR="$work/state" FSTAB="$work/fstab" REALPATH_BIN="$work/bin/realpath"
 LSBLK_BIN="$work/bin/lsblk" FINDMNT_BIN="$work/bin/findmnt" WIPEFS_BIN="$work/bin/wipefs"
 SMARTCTL_BIN="$work/bin/smartctl" NVME_BIN="$work/bin/nvme" PVS_BIN="$work/bin/pvs"
 MDADM_BIN="$work/bin/mdadm" FUSER_BIN="$work/bin/fuser" SHA256_BIN="$work/bin/sha256sum" ID_BIN="$work/bin/id"
 STAT_BIN="$work/bin/stat" INSTALL_BIN="$work/bin/install" SFDISK_BIN="$work/bin/sfdisk"
 SGDISK_BIN="$work/bin/sgdisk" BLOCK_DEVICE_TEST_BIN="$work/bin/block-test"
 PARTPROBE_BIN="$work/bin/partprobe" UDEVADM_BIN="$work/bin/udevadm"
 SYSTEMCTL_BIN="$work/bin/systemctl" MKFS_XFS_BIN="$work/bin/mkfs.xfs"
 BLKID_BIN="$work/bin/blkid" MOUNTPOINT_BIN="$work/bin/mountpoint"
 MOUNT_BIN="$work/bin/mount" XFS_INFO_BIN="$work/bin/xfs_info"
)
run() { env "${common[@]}" FAIL="${1:-}" "$SCRIPT" "${@:2}"; }
must_fail() {
    if run "$@" >/dev/null 2>&1; then
        printf 'expected storage failure: %s\n' "$*" >&2
        exit 1
    fi
}

one="$work/by-id/canary-one"
run '' check "$one" >/dev/null
run mdadm-gpt check "$one" >/dev/null
plan1="$(run '' plan "$one")"
plan2="$(run '' plan "$one")"
[[ "$plan1" == "$plan2" ]]
digest="${plan1##*PLAN_SHA256=}"
[[ "$digest" =~ ^[0-9a-f]{64}$ ]]
[[ "$plan1" == *'OS_DISK_EXCLUDED=true'* ]]
[[ "$plan1" == *'512GB_EXCLUDED=true'* ]]
[[ "$plan1" == *'DOCKER_ROOTS_REMAIN_OS=true'* ]]
[[ "$plan1" != *'512GB_PATH='* ]]
P1_START="$(sed -n 's/^PART1_START=//p' <<<"$plan1")"
[[ "$plan1" == *'1TB_HEALTH_CRITICAL_WARNING=0'* ]]
[[ "$plan1" == *'1TB_HEALTH_MEDIA_ERRORS=0'* ]]
P1_END="$(sed -n 's/^PART1_END=//p' <<<"$plan1")"
P2_START="$(sed -n 's/^PART2_START=//p' <<<"$plan1")"
P2_END="$(sed -n 's/^PART2_END=//p' <<<"$plan1")"
P1_SIZE=$((P1_END-P1_START+1))
P2_SIZE=$((P2_END-P2_START+1))
export P1_START P1_SIZE P2_START P2_SIZE
(( P1_SIZE > 0 && P2_SIZE > 0 ))
(( P1_SIZE > P2_SIZE ? P1_SIZE-P2_SIZE < 4096 : P2_SIZE-P1_SIZE < 4096 ))

for failure in type children mounted osmount root lvm raid use health media-errors critical-warning spare-low signature onesize model; do
    must_fail "$failure" check "$one"
done
touch "$work/sys/disk-one/holders/canary-holder"
must_fail '' check "$one"
rm "$work/sys/disk-one/holders/canary-holder"
must_fail '' check relative
must_fail nonroot apply "$one" "$digest"
must_fail '' verify
: >"$work/log"
must_fail '' apply "$one" "$digest" <<<"NO"
! grep -Eq 'sgdisk --zap-all|mkfs.xfs -f' "$work/log"

approval="APPROVE C1 STORAGE
1TB=$one
PLAN_SHA256=$digest
1TB_SIGNATURES=none
PARTITION_LAYOUT=50% LIBREFS + 50% APPLICATIONS
ACKNOWLEDGE_WIPE=ERASE APPROVED 1TB TARGET ONLY"
printf '%s\n' "$plan1" >"$work/state/approved-plan"
for changed in signature mounted use media-errors; do
    : >"$work/log"
    if printf '%s' "$approval" | run "$changed" apply "$one" "$digest" >/dev/null 2>&1; then
        printf 'expected changed-evidence rejection: %s\n' "$changed" >&2
        exit 1
    fi
    ! grep -F 'sgdisk --zap-all' "$work/log" >/dev/null
done
rm "$work/state/approved-plan"
if printf '%s' "$approval" | run sgdisk-partial apply "$one" "$digest" >/dev/null 2>&1; then
    printf 'expected partial GPT creation failure\n' >&2
    exit 1
fi
[[ -s "$work/state/layout.pending" ]]
! grep -F 'mkfs.xfs -f' "$work/log" >/dev/null
for changed in partial-signature partial-lvm partial-raid partial-use mounted model onesize root \
    media-errors critical-warning spare-low; do
    : >"$work/log"
    if printf '%s' "$approval" | run "$changed" apply "$one" "$digest" >/dev/null 2>&1; then
        printf 'expected partial-layout state rejection: %s\n' "$changed" >&2
        exit 1
    fi
    ! grep -F 'sgdisk --zap-all' "$work/log" >/dev/null
done
touch "$work/sys/disk-onep1/holders/canary-holder"
: >"$work/log"
if printf '%s' "$approval" | run '' apply "$one" "$digest" >/dev/null 2>&1; then
    printf 'expected partial-layout holder rejection\n' >&2
    exit 1
fi
! grep -F 'sgdisk --zap-all' "$work/log" >/dev/null
rm "$work/sys/disk-onep1/holders/canary-holder"
pending_digest="$(cat "$work/state/layout.pending")"
printf '%s\n' 'wrong-digest' >"$work/state/layout.pending"
: >"$work/log"
if printf '%s' "$approval" | run '' apply "$one" "$digest" >/dev/null 2>&1; then
    printf 'expected partial-layout digest rejection\n' >&2
    exit 1
fi
! grep -F 'sgdisk --zap-all' "$work/log" >/dev/null
printf '%s\n' "$pending_digest" >"$work/state/layout.pending"
if printf '%s' "$approval" | run unexpected-fs apply "$one" "$digest" >/dev/null 2>&1; then
    printf 'expected unexpected-filesystem rejection\n' >&2
    exit 1
fi
! grep -F 'mkfs.xfs -f' "$work/log" >/dev/null
fstab_before="$(cat "$work/fstab")"
if printf '%s' "$approval" | run mount-fail apply "$one" "$digest" >/dev/null 2>&1; then
    printf 'expected mount failure during resumable apply\n' >&2
    exit 1
fi
[[ "$(cat "$work/fstab")" == "$fstab_before" ]]
if [[ ! -s "$work/state/c1_librefs.pending" ]]; then
    printf 'expected c1_librefs pending marker after mount failure\n' >&2
    exit 1
fi
printf '%s' "$approval" | run '' apply "$one" "$digest" >/dev/null
run '' verify >/dev/null
mkfs_count="$(grep -c 'mkfs.xfs -f' "$work/log")"
printf '%s' "$approval" | run '' apply "$one" "$digest" >/dev/null
[[ "$(grep -c 'mkfs.xfs -f' "$work/log")" == "$mkfs_count" ]]
sgdisk_count="$(grep -c '^sgdisk ' "$work/log")"
must_fail layout-drift verify
must_fail layout-type verify
must_fail docker-other verify
must_fail containerd-other verify
[[ "$(grep -c '^sgdisk ' "$work/log")" == "$sgdisk_count" ]]
[[ "$(grep -c 'mkfs.xfs -f' "$work/log")" == 2 ]]
grep -F -- "--new=1:$P1_START:$P1_END --typecode=1:8300 --change-name=1:c1_librefs" \
    "$work/log" >/dev/null
grep -F -- "--new=2:$P2_START:$P2_END --typecode=2:8300 --change-name=2:c1_applications" \
    "$work/log" >/dev/null
printf 'c1 split-storage check, plan, approval, resume, and verification tests passed\n'
