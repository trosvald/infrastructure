#!/usr/bin/env bash
set -euo pipefail

readonly HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_BIN="${INSTALL_BIN:-install}"
CMP_BIN="${CMP_BIN:-cmp}"
ID_BIN="${ID_BIN:-id}"
SYSTEMCTL_BIN="${SYSTEMCTL_BIN:-systemctl}"
SYSTEMD_ROOT="${SYSTEMD_ROOT:-/etc/systemd/system}"
LOCAL_SBIN="${LOCAL_SBIN:-/usr/local/sbin}"
readonly INSTALL_BIN CMP_BIN ID_BIN SYSTEMCTL_BIN SYSTEMD_ROOT LOCAL_SBIN

fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
verify_file() {
    local source="$1" destination="$2"
    [[ -f "$destination" && ! -L "$destination" ]] \
        || fail "required installed file is absent: $destination"
    "$CMP_BIN" -s "$source" "$destination" \
        || fail "installed file differs from reviewed source: $destination"
}
refuse_conflict() {
    local source="$1" destination="$2"
    [[ ! -e "$destination" && ! -L "$destination" ]] && return 0
    [[ -f "$destination" && ! -L "$destination" ]] \
        || fail "refusing non-regular destination: $destination"
    "$CMP_BIN" -s "$source" "$destination" \
        || fail "refusing to overwrite existing configuration: $destination"
}
verify_all() {
    verify_file "$HERE/assert-mount.sh" "$LOCAL_SBIN/assert-c1-mount"
    verify_file "$HERE/templates/c1-librefs-storage.service" \
        "$SYSTEMD_ROOT/c1-librefs-storage.service"
    verify_file "$HERE/templates/c1-applications-storage.service" \
        "$SYSTEMD_ROOT/c1-applications-storage.service"
    verify_file "$HERE/../systemd/manage-librefs.sh" "$LOCAL_SBIN/manage-c1-librefs"
    verify_file "$HERE/../systemd/librefs-c1.service" "$SYSTEMD_ROOT/librefs-c1.service"
    printf 'c1 storage assertion assets match reviewed sources\n'
}
apply_all() {
    [[ "$($ID_BIN -u)" == 0 ]] || fail 'storage asset installation requires root'
    refuse_conflict "$HERE/assert-mount.sh" "$LOCAL_SBIN/assert-c1-mount"
    refuse_conflict "$HERE/templates/c1-librefs-storage.service" \
        "$SYSTEMD_ROOT/c1-librefs-storage.service"
    refuse_conflict "$HERE/templates/c1-applications-storage.service" \
        "$SYSTEMD_ROOT/c1-applications-storage.service"
    refuse_conflict "$HERE/../systemd/manage-librefs.sh" "$LOCAL_SBIN/manage-c1-librefs"
    refuse_conflict "$HERE/../systemd/librefs-c1.service" "$SYSTEMD_ROOT/librefs-c1.service"
    "$INSTALL_BIN" -d -o root -g root -m 0755 "$LOCAL_SBIN" "$SYSTEMD_ROOT"
    "$INSTALL_BIN" -o root -g root -m 0755 "$HERE/assert-mount.sh" \
        "$LOCAL_SBIN/assert-c1-mount"
    "$INSTALL_BIN" -o root -g root -m 0644 "$HERE/templates/c1-librefs-storage.service" \
        "$SYSTEMD_ROOT/c1-librefs-storage.service"
    "$INSTALL_BIN" -o root -g root -m 0644 "$HERE/templates/c1-applications-storage.service" \
        "$SYSTEMD_ROOT/c1-applications-storage.service"
    "$INSTALL_BIN" -o root -g root -m 0755 "$HERE/../systemd/manage-librefs.sh" \
        "$LOCAL_SBIN/manage-c1-librefs"
    "$INSTALL_BIN" -o root -g root -m 0644 "$HERE/../systemd/librefs-c1.service" \
        "$SYSTEMD_ROOT/librefs-c1.service"
    verify_all >/dev/null
    "$SYSTEMCTL_BIN" daemon-reload
    "$SYSTEMCTL_BIN" enable c1-librefs-storage.service c1-applications-storage.service \
        librefs-c1.service
    printf 'c1 storage and libreFS startup assets installed; services were not started\n'
}

[[ $# == 1 ]] || fail 'usage: install-storage-assets.sh {check|apply}'
case "$1" in
    check) verify_all ;;
    apply) apply_all ;;
    *) fail 'usage: install-storage-assets.sh {check|apply}' ;;
esac
