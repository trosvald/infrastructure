#!/usr/bin/env bash
set -euo pipefail

FINDMNT_BIN="${FINDMNT_BIN:-findmnt}"
XFS_INFO_BIN="${XFS_INFO_BIN:-xfs_info}"
XFS_QUOTA_BIN="${XFS_QUOTA_BIN:-xfs_quota}"
INSTALL_BIN="${INSTALL_BIN:-install}"
STAT_BIN="${STAT_BIN:-stat}"
ID_BIN="${ID_BIN:-id}"
STATE_DIR="${STATE_DIR:-/var/lib/c1-storage}"
PROJECTS_FILE="${PROJECTS_FILE:-/etc/projects}"
PROJID_FILE="${PROJID_FILE:-/etc/projid}"
MOUNT="${MOUNT:-/srv/applications}"
ROOT="${ROOT:-$MOUNT/apps/forgejo}"
readonly MOUNT ROOT

fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
[[ "$("$ID_BIN" -u)" == 0 ]] || fail 'Forgejo quota helper must run as root'
[[ $# -le 1 && "${1:-apply}" =~ ^(check|apply)$ ]] || fail 'usage: ensure-forgejo-quotas.sh [check|apply]'
mode="${1:-apply}"

uuid_file="$STATE_DIR/c1_applications.uuid"
[[ -f "$uuid_file" && ! -L "$uuid_file" ]] || fail 'applications UUID state is missing or unsafe'
IFS= read -r expected_uuid <"$uuid_file"
[[ "$expected_uuid" =~ ^[[:alnum:]-]+$ ]] || fail 'applications UUID state is invalid'
read -r source actual_uuid fstype options < <("$FINDMNT_BIN" -n -o SOURCE,UUID,FSTYPE,OPTIONS --target "$MOUNT")
[[ -n "$source" && "$actual_uuid" == "$expected_uuid" && "$fstype" == xfs ]] || fail 'applications mount identity changed'
root_source="$("$FINDMNT_BIN" -n -o SOURCE --target /)"
[[ "$source" != "$root_source" ]] || fail 'applications storage resolves to the root filesystem'
[[ ",$options," == *,rw,* && ",$options," == *,noatime,* && ",$options," == *,prjquota,* ]] || fail 'applications mount requires rw,noatime,prjquota'
"$XFS_INFO_BIN" "$MOUNT" | grep -Eq 'ftype=1' || fail 'applications XFS lacks ftype=1'

paths=(
    "$ROOT"
    "$ROOT/app"
    "$ROOT/postgres"
    "$ROOT/app/repositories"
    "$ROOT/app/lfs"
    "$ROOT/app/packages"
    "$ROOT/app/attachments"
    "$ROOT/app/avatars"
    "$ROOT/app/archives"
    "$ROOT/app/sessions"
    "$ROOT/app/queues"
    "$ROOT/app/ssh"
    "$ROOT/staging"
    "$ROOT/logs"
    "$ROOT/logs/forgejo"
    "$ROOT/logs/postgres"
    "$ROOT/logs/backup"
)
for path in "${paths[@]}"; do
    [[ ! -L "$path" ]] || fail "symlink bind source is prohibited: $path"
done

if [[ "$mode" == apply ]]; then
    "$INSTALL_BIN" -d -m 0755 -o root -g root "$MOUNT/apps" "$ROOT" "$ROOT/logs"
    "$INSTALL_BIN" -d -m 0750 -o 1000 -g 1000 \
        "$ROOT/app" "$ROOT/app/repositories" "$ROOT/app/lfs" "$ROOT/app/packages" \
        "$ROOT/app/attachments" "$ROOT/app/avatars" "$ROOT/app/archives" \
        "$ROOT/app/sessions" "$ROOT/app/queues" "$ROOT/app/ssh" \
        "$ROOT/staging" "$ROOT/logs/forgejo" "$ROOT/logs/backup"
    "$INSTALL_BIN" -d -m 0700 -o 70 -g 70 "$ROOT/postgres" "$ROOT/logs/postgres"
    python3 - "$PROJECTS_FILE" "$PROJID_FILE" "$ROOT" <<'PY'
import os, sys, tempfile
projects, projid, root = sys.argv[1:]
managed_ids = {"251501", "251502", "251503"}
managed_names = {"forgejo-app", "forgejo-postgres", "forgejo-staging"}
project_rows = {
    f"251501:{root}/app\n",
    f"251502:{root}/postgres\n",
    f"251503:{root}/staging\n",
}
projid_rows = {
    "forgejo-app:251501\n",
    "forgejo-postgres:251502\n",
    "forgejo-staging:251503\n",
}
def update(path, rows, reject):
    old = open(path, encoding="utf-8").readlines() if os.path.exists(path) else []
    kept = [line for line in old if not reject(line.strip())]
    directory = os.path.dirname(path) or "."
    fd, tmp = tempfile.mkstemp(prefix=".c1-quota-", dir=directory, text=True)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as stream:
            stream.writelines(kept + sorted(rows))
            stream.flush()
            os.fsync(stream.fileno())
        os.chmod(tmp, 0o644)
        os.replace(tmp, path)
        dfd = os.open(directory, os.O_DIRECTORY)
        os.fsync(dfd)
        os.close(dfd)
    except BaseException:
        try: os.unlink(tmp)
        except OSError: pass
        raise
update(projects, project_rows, lambda line: line.split(":", 1)[0] in managed_ids)
update(projid, projid_rows, lambda line: line.split(":", 1)[0] in managed_names)
PY
    for project in forgejo-app forgejo-postgres forgejo-staging; do
        "$XFS_QUOTA_BIN" -x -c "project -s $project" "$MOUNT"
    done
    "$XFS_QUOTA_BIN" -x -c 'limit -p bsoft=190g bhard=200g forgejo-app' "$MOUNT"
    "$XFS_QUOTA_BIN" -x -c 'limit -p bsoft=45g bhard=50g forgejo-postgres' "$MOUNT"
    "$XFS_QUOTA_BIN" -x -c 'limit -p bsoft=22g bhard=25g forgejo-staging' "$MOUNT"
fi

expected=(
    "0:0:755:$ROOT"
    "1000:1000:750:$ROOT/app"
    "70:70:700:$ROOT/postgres"
    "1000:1000:750:$ROOT/staging"
)
for item in "${expected[@]}"; do
    IFS=: read -r uid gid permissions path <<<"$item"
    [[ -d "$path" && ! -L "$path" ]] || fail "required bind source is absent or unsafe: $path"
    [[ "$("$STAT_BIN" -c '%u:%g:%a' "$path")" == "$uid:$gid:$permissions" ]] || fail "bind source ownership or mode drift: $path"
done
for row in \
    "251501:$ROOT/app" \
    "251502:$ROOT/postgres" \
    "251503:$ROOT/staging"; do
    grep -Fx "$row" "$PROJECTS_FILE" >/dev/null || fail "missing project mapping: $row"
done
for row in 'forgejo-app:251501' 'forgejo-postgres:251502' 'forgejo-staging:251503'; do
    grep -Fx "$row" "$PROJID_FILE" >/dev/null || fail "missing project name mapping: $row"
done
printf 'Forgejo bind sources and XFS project quotas match the reviewed contract\n'
