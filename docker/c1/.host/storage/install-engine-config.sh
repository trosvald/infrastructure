#!/usr/bin/env bash
set -euo pipefail

readonly HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_BIN="${INSTALL_BIN:-install}"
CMP_BIN="${CMP_BIN:-cmp}"
ID_BIN="${ID_BIN:-id}"
SYSTEMCTL_BIN="${SYSTEMCTL_BIN:-systemctl}"
SYSTEMD_ROOT="${SYSTEMD_ROOT:-/etc/systemd/system}"
DOCKER_CONFIG_DIR="${DOCKER_CONFIG_DIR:-/etc/docker}"
LOCAL_SBIN="${LOCAL_SBIN:-/usr/local/sbin}"
readonly INSTALL_BIN CMP_BIN ID_BIN SYSTEMCTL_BIN SYSTEMD_ROOT DOCKER_CONFIG_DIR LOCAL_SBIN

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
    verify_file "$HERE/templates/containerd-c1-storage.conf" \
        "$SYSTEMD_ROOT/containerd.service.d/c1-storage.conf"
    verify_file "$HERE/templates/docker-c1-storage.conf" \
        "$SYSTEMD_ROOT/docker.service.d/c1-storage.conf"
    verify_file "$HERE/templates/c1-librefs-storage.service" \
        "$SYSTEMD_ROOT/c1-librefs-storage.service"
    verify_file "$HERE/templates/daemon.json" "$DOCKER_CONFIG_DIR/daemon.json"
    printf 'c1 engine storage configuration matches reviewed sources\n'
}

apply_all() {
    [[ "$($ID_BIN -u)" == 0 ]] || fail 'configuration installation requires root'
    refuse_conflict "$HERE/assert-mount.sh" "$LOCAL_SBIN/assert-c1-mount"
    refuse_conflict "$HERE/templates/containerd-c1-storage.conf" \
        "$SYSTEMD_ROOT/containerd.service.d/c1-storage.conf"
    refuse_conflict "$HERE/templates/docker-c1-storage.conf" \
        "$SYSTEMD_ROOT/docker.service.d/c1-storage.conf"
    refuse_conflict "$HERE/templates/c1-librefs-storage.service" \
        "$SYSTEMD_ROOT/c1-librefs-storage.service"
    refuse_conflict "$HERE/templates/daemon.json" "$DOCKER_CONFIG_DIR/daemon.json"

    "$INSTALL_BIN" -d -o root -g root -m 0755 "$LOCAL_SBIN" \
        "$SYSTEMD_ROOT/containerd.service.d" "$SYSTEMD_ROOT/docker.service.d" \
        "$DOCKER_CONFIG_DIR"
    "$INSTALL_BIN" -o root -g root -m 0755 "$HERE/assert-mount.sh" \
        "$LOCAL_SBIN/assert-c1-mount"
    "$INSTALL_BIN" -o root -g root -m 0644 "$HERE/templates/containerd-c1-storage.conf" \
        "$SYSTEMD_ROOT/containerd.service.d/c1-storage.conf"
    "$INSTALL_BIN" -o root -g root -m 0644 "$HERE/templates/docker-c1-storage.conf" \
        "$SYSTEMD_ROOT/docker.service.d/c1-storage.conf"
    "$INSTALL_BIN" -o root -g root -m 0644 "$HERE/templates/c1-librefs-storage.service" \
        "$SYSTEMD_ROOT/c1-librefs-storage.service"
    "$INSTALL_BIN" -o root -g root -m 0644 "$HERE/templates/daemon.json" \
        "$DOCKER_CONFIG_DIR/daemon.json"
    verify_all >/dev/null
    "$SYSTEMCTL_BIN" daemon-reload
    "$SYSTEMCTL_BIN" enable c1-librefs-storage.service
    printf 'c1 engine storage configuration installed; engines were not started\n'
}

[[ $# == 1 ]] || fail 'usage: install-engine-config.sh {check|apply}'
case "$1" in
    check) verify_all ;;
    apply) apply_all ;;
    *) fail 'usage: install-engine-config.sh {check|apply}' ;;
esac
