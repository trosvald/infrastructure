#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT HUP INT TERM
mkdir -p "$work/bin" "$work/state" "$work/mount"
printf 'canary-applications-uuid\n' >"$work/state/c1_applications.uuid"
: >"$work/projects"; : >"$work/projid"
cat >"$work/bin/findmnt" <<'SH'
#!/usr/bin/env bash
if [[ "$*" == *'SOURCE,UUID,FSTYPE,OPTIONS'* ]]; then
    printf '/dev/canary canary-applications-uuid xfs rw,noatime,%s\n' "${QUOTA_OPTION:-prjquota}"
else printf '/dev/root\n'; fi
SH
cat >"$work/bin/install" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
for value in "$@"; do [[ "$value" == /* ]] && mkdir -p "$value"; done
SH
cat >"$work/bin/stat" <<'SH'
#!/usr/bin/env bash
case "${@: -1}" in
*/postgres) echo 70:70:700;;
*/app|*/staging) echo 1000:1000:750;;
*) echo 0:0:755;;
esac
SH
cat >"$work/bin/xfs_quota" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${CALLS:?}"
SH
cat >"$work/bin/xfs_info" <<'SH'
#!/usr/bin/env bash
printf '%s\n' 'naming =version 2 bsize=4096 ascii-ci=0, ftype=1'
SH
cat >"$work/bin/id" <<'SH'
#!/usr/bin/env bash
echo 0
SH
chmod +x "$work/bin"/*
run() {
    CALLS="$work/calls" MOUNT="$work/mount" ROOT="$work/mount/apps/forgejo" \
    STATE_DIR="$work/state" PROJECTS_FILE="$work/projects" PROJID_FILE="$work/projid" \
    FINDMNT_BIN="$work/bin/findmnt" INSTALL_BIN="$work/bin/install" STAT_BIN="$work/bin/stat" \
    XFS_QUOTA_BIN="$work/bin/xfs_quota" XFS_INFO_BIN="$work/bin/xfs_info" ID_BIN="$work/bin/id" \
    "$root/ensure-forgejo-quotas.sh" "$@"
}
run apply >/dev/null
run check >/dev/null
[[ "$(grep -c 'project -s' "$work/calls")" -eq 3 ]]
grep -F 'bhard=200g forgejo-app' "$work/calls" >/dev/null
grep -F "251501:$work/mount/apps/forgejo/app" "$work/projects" >/dev/null
if QUOTA_OPTION=noquota run check >/dev/null 2>&1; then
    echo 'missing prjquota was accepted' >&2; exit 1
fi
ln -s "$work/elsewhere" "$work/mount/apps/forgejo/staging-link"
rm -rf "$work/mount/apps/forgejo/staging"
ln -s "$work/elsewhere" "$work/mount/apps/forgejo/staging"
if run check >/dev/null 2>&1; then
    echo 'symlink staging source was accepted' >&2; exit 1
fi
printf 'Forgejo quota prerequisite tests passed\n'
