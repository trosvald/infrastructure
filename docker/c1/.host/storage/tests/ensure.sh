#!/usr/bin/env bash
set -euo pipefail
readonly HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT="$HERE/../ensure.sh"
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin" "$work/by-id" "$work/dev" "$work/state" "$work/sys/disk-one/holders" "$work/sys/disk-half/holders"
touch "$work/dev/disk-one" "$work/dev/disk-half" "$work/fstab"
ln -s "$work/dev/disk-one" "$work/by-id/canary-one"; ln -s "$work/dev/disk-half" "$work/by-id/canary-half"
cat >"$work/bin/fake" <<'FAKE'
#!/usr/bin/env bash
set -eu
name="${0##*/}"; printf '%s %s\n' "$name" "$*" >>"$FAKE_LOG"
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
   if [[ "${FAIL:-}" != model ]]; then
    if [[ "$dev" == *one ]]; then echo CANARY_ONE_MODEL; else echo CANARY_HALF_MODEL; fi
   fi
  elif [[ "$args" == *' SIZE '* ]]; then
   if [[ "$dev" == *one ]]; then
    if [[ "${FAIL:-}" == onesize ]]; then echo 1; else echo 1000000000000; fi
   else
    if [[ "${FAIL:-}" == halfsize ]]; then echo 1; else echo 500000000000; fi
   fi
  elif [[ "$args" == *' -s '* ]]; then
   if [[ "${FAIL:-}" == root ]]; then echo "$FAKE_DEV/disk-one"; else echo "$FAKE_DEV/os-root"; fi
  elif [[ "${FAIL:-}" == children ]]; then
   printf '%s\n%s-part\n' "$dev" "$dev"
  else
   echo "$dev"
  fi ;;
 findmnt) if [[ "$*" == *' -o SOURCE '* ]]; then echo "$FAKE_DEV/os-root"; else echo 'canary-uuid xfs rw,noatime'; fi ;;
 wipefs) if [[ "${FAIL:-}" == signature-one && "$*" == *disk-one* ]]; then echo '{"signatures":[{"type":"ext4","offset":"0x1"}]}'; elif [[ "${FAIL:-}" == signature-half && "$*" == *disk-half* ]]; then echo '{"signatures":[{"type":"ext4","offset":"0x1"}]}'; elif [[ "$*" == *disk-half* ]]; then echo '{"signatures":[{"type":"gpt","offset":"0x200"},{"type":"gpt","offset":"0xffff"},{"type":"PMBR","offset":"0x1fe"}]}'; else echo '{"signatures":[]}'; fi ;;
 smartctl) [[ "${FAIL:-}" != health ]] ;;
 pvs) [[ "${FAIL:-}" == lvm ]] && printf '%s\n%s\n' "$FAKE_DEV/disk-one" "$FAKE_DEV/disk-half" || true ;;
 mdadm) if [[ "${FAIL:-}" == raid ]]; then echo 'MD_UUID=safe-canary-array'; exit 0; elif [[ "${FAIL:-}" == mdadm-gpt ]]; then exit 0; else exit 1; fi ;;
 fuser) [[ "${FAIL:-}" == use ]] ;;
 sha256sum) command sha256sum ;;
 id) [[ "${FAIL:-}" == nonroot ]] && echo 1000 || echo 0 ;;
 install) if [[ "$*" == *"$FAKE_STATE"* ]]; then mkdir -p "$FAKE_STATE"; fi ;;
 stat) if [[ "${@: -1}" == */data ]]; then echo 1000:1000:750; else echo 0:0:711; fi ;;
 blkid) echo canary-uuid ;;
 mountpoint)
  target="${@: -1}"
  [[ -e "$FAKE_STATE/mounted-${target##*/}" ]]
  ;;
 xfs_info) echo 'naming =version 2 bsize=4096 ascii-ci=0, ftype=1' ;;
 mount)
  [[ "${FAIL:-}" != mount-fail ]] || exit 85
  target="${@: -1}"
  touch "$FAKE_STATE/mounted-${target##*/}"
  ;;
 block-test|sgdisk|partprobe|udevadm|mkfs.xfs|systemctl) : ;;
 *) exit 90 ;;
esac
FAKE
chmod +x "$work/bin/fake"
for name in realpath lsblk findmnt wipefs smartctl pvs mdadm fuser sha256sum id install stat blkid mountpoint xfs_info block-test sgdisk partprobe udevadm mkfs.xfs mount systemctl; do ln -s fake "$work/bin/$name"; done
export FAKE_LOG="$work/log" FAKE_DEV="$work/dev" FAKE_STATE="$work/state"
common=(BY_ID_ROOT="$work/by-id" DEV_ROOT="$work/dev" SYS_BLOCK_ROOT="$work/sys" STATE_DIR="$work/state" FSTAB="$work/fstab"
 REALPATH_BIN="$work/bin/realpath" LSBLK_BIN="$work/bin/lsblk" FINDMNT_BIN="$work/bin/findmnt" WIPEFS_BIN="$work/bin/wipefs"
 SMARTCTL_BIN="$work/bin/smartctl" PVS_BIN="$work/bin/pvs" MDADM_BIN="$work/bin/mdadm" FUSER_BIN="$work/bin/fuser" SHA256_BIN="$work/bin/sha256sum"
 ID_BIN="$work/bin/id" STAT_BIN="$work/bin/stat" INSTALL_BIN="$work/bin/install" BLKID_BIN="$work/bin/blkid" MOUNTPOINT_BIN="$work/bin/mountpoint" XFS_INFO_BIN="$work/bin/xfs_info"
 BLOCK_DEVICE_TEST_BIN="$work/bin/block-test" SGDISK_BIN="$work/bin/sgdisk" PARTPROBE_BIN="$work/bin/partprobe" UDEVADM_BIN="$work/bin/udevadm"
 MKFS_XFS_BIN="$work/bin/mkfs.xfs" MOUNT_BIN="$work/bin/mount" SYSTEMCTL_BIN="$work/bin/systemctl")
run() { env "${common[@]}" FAIL="${1:-}" "$SCRIPT" "${@:2}"; }
must_fail() { if run "$@" >/dev/null 2>&1; then printf 'expected storage failure: %s\n' "$*" >&2; exit 1; fi; }
one="$work/by-id/canary-one"; half="$work/by-id/canary-half"
run '' check "$one" "$half" >/dev/null
run mdadm-gpt check "$one" "$half" >/dev/null
plan1="$(run '' plan "$one" "$half")"; plan2="$(run '' plan "$one" "$half")"; [[ "$plan1" == "$plan2" ]]
digest="${plan1##*PLAN_SHA256=}"
[[ "$digest" =~ ^[0-9a-f]{64}$ ]]; [[ "$plan1" == *'OS_DISK_EXCLUDED=true'* ]]; [[ "$plan1" == *'512GB_SIGNATURES=PMBR@0x1fe;gpt@0x200;gpt@0xffff'* ]]
for failure in type children mounted osmount root lvm raid use health signature-one signature-half onesize halfsize model; do must_fail "$failure" check "$one" "$half"; done
touch "$work/sys/disk-one/holders/canary-holder"; must_fail '' check "$one" "$half"; rm "$work/sys/disk-one/holders/canary-holder"
must_fail '' check relative "$half"; must_fail '' check "$one" "$one"; must_fail nonroot apply "$one" "$half" "$digest"
must_fail '' verify
: >"$work/log"; must_fail '' apply "$one" "$half" "$digest" <<<"NO"
! grep -Eq 'sgdisk --zap-all|mkfs.xfs -f' "$work/log"
approval="APPROVE C1 STORAGE
1TB=$one
512GB=$half
PLAN_SHA256=$digest
1TB_SIGNATURES=none
512GB_SIGNATURES=PMBR@0x1fe;gpt@0x200;gpt@0xffff
ACKNOWLEDGE_WIPE=ERASE APPROVED TARGETS ONLY"
fstab_before="$(cat "$work/fstab")"
if printf '%s' "$approval" | run mount-fail apply "$one" "$half" "$digest" >/dev/null 2>&1; then
    printf 'expected mount failure during resumable apply\n' >&2
    exit 1
fi
[[ "$(cat "$work/fstab")" == "$fstab_before" ]]
[[ -s "$work/state/c1_containers.pending" ]]
printf '%s' "$approval" | run '' apply "$one" "$half" "$digest" >/dev/null
run '' verify >/dev/null
mkfs_count="$(grep -c 'mkfs.xfs -f' "$work/log")"
printf '%s' "$approval" | run '' apply "$one" "$half" "$digest" >/dev/null
[[ "$(grep -c 'mkfs.xfs -f' "$work/log")" == "$mkfs_count" ]]
grep -F 'sgdisk --zap-all' "$work/log" >/dev/null
grep -F 'mkfs.xfs -f -m crc=1,reflink=1 -n ftype=1' "$work/log" >/dev/null
printf 'c1 storage check, plan, approval, apply, and rejection tests passed\n'
