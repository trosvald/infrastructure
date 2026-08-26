#!/usr/bin/env bash
set -euo pipefail
[[ $# == 2 ]] || { printf 'Usage: %s <librefs|applications> <mount-path>\n' "$0" >&2; exit 64; }
readonly ROLE="$1" TARGET="$2" STATE_DIR="${STATE_DIR:-/var/lib/c1-storage}"
case "$ROLE:$TARGET" in
    librefs:/srv/librefs) label=c1_librefs ;;
    applications:/srv/applications) label=c1_applications ;;
    *) printf 'ERROR: unapproved mount role/path\n' >&2; exit 1 ;;
esac
uuid_file="$STATE_DIR/$label.uuid"
[[ -r "$uuid_file" ]] || { printf 'ERROR: missing root-owned UUID assertion for %s\n' "$ROLE" >&2; exit 1; }
uuid="$(cat "$uuid_file")"; [[ "$uuid" =~ ^[[:alnum:]-]+$ ]] || exit 1
mountpoint -q "$TARGET" || { printf 'ERROR: %s is not a mount\n' "$TARGET" >&2; exit 1; }
read -r actual_uuid fstype options < <(findmnt -n -o UUID,FSTYPE,OPTIONS --target "$TARGET")
[[ "$actual_uuid" == "$uuid" && "$fstype" == xfs && ",$options," == *,rw,* ]] || { printf 'ERROR: %s mount identity/state mismatch\n' "$TARGET" >&2; exit 1; }
xfs_info "$TARGET" | grep -Eq 'ftype=1' || { printf 'ERROR: %s lacks XFS ftype=1\n' "$TARGET" >&2; exit 1; }
if [[ "$ROLE" == librefs ]]; then
    [[ -d "$TARGET/data" && "$(stat -c '%u:%g:%a' "$TARGET/data")" == 1000:1000:750 ]] || { printf 'ERROR: libreFS data directory state mismatch\n' >&2; exit 1; }
else
    [[ "$(stat -c '%u:%g:%a' "$TARGET")" == 0:0:755 ]] || { printf 'ERROR: applications mount root state mismatch\n' >&2; exit 1; }
fi
