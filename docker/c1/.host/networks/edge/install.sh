#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_BIN="${INSTALL_BIN:-install}"; CMP_BIN="${CMP_BIN:-cmp}"; ID_BIN="${ID_BIN:-id}"
SYSTEMCTL_BIN="${SYSTEMCTL_BIN:-systemctl}"
LOCAL_SBIN="${LOCAL_SBIN:-/usr/local/sbin}"; SYSTEMD_ROOT="${SYSTEMD_ROOT:-/etc/systemd/system}"
INTERFACES_DIR="${INTERFACES_DIR:-/etc/network/interfaces.d}"
fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
verify() {
    "$CMP_BIN" -s "$HERE/ensure.sh" "$LOCAL_SBIN/ensure-c1-edge-networks" || fail 'installed EDGE network helper differs'
    "$CMP_BIN" -s "$HERE/c1-edge-networks.service" "$SYSTEMD_ROOT/c1-edge-networks.service" || fail 'installed EDGE network unit differs'
    "$CMP_BIN" -s "$HERE/interfaces.d/c1-edge" "$INTERFACES_DIR/c1-edge" || fail 'installed EDGE VLAN stanza differs'
    "$CMP_BIN" -s "$HERE/ensure-forgejo-egress.sh" "$LOCAL_SBIN/ensure-c1-forgejo-egress" || fail 'installed Forgejo egress helper differs'
    "$CMP_BIN" -s "$HERE/c1-forgejo-egress.service" "$SYSTEMD_ROOT/c1-forgejo-egress.service" || fail 'installed Forgejo egress unit differs'
}
[[ $# == 1 && "$1" =~ ^(check|apply)$ ]] || fail 'usage: install.sh {check|apply}'
if [[ "$1" == check ]]; then verify; exit; fi
[[ "$($ID_BIN -u)" == 0 ]] || fail 'EDGE prerequisite installation requires root'
for pair in \
    "$HERE/ensure.sh:$LOCAL_SBIN/ensure-c1-edge-networks" \
    "$HERE/c1-edge-networks.service:$SYSTEMD_ROOT/c1-edge-networks.service" \
    "$HERE/ensure-forgejo-egress.sh:$LOCAL_SBIN/ensure-c1-forgejo-egress" \
    "$HERE/c1-forgejo-egress.service:$SYSTEMD_ROOT/c1-forgejo-egress.service" \
    "$HERE/interfaces.d/c1-edge:$INTERFACES_DIR/c1-edge"; do
    source=${pair%%:*}; destination=${pair#*:}
    [[ ! -e "$destination" && ! -L "$destination" ]] || { [[ -f "$destination" && ! -L "$destination" ]] && "$CMP_BIN" -s "$source" "$destination" || fail "refusing conflicting $destination"; }
done
"$INSTALL_BIN" -d -o root -g root -m 0755 "$LOCAL_SBIN" "$SYSTEMD_ROOT" "$INTERFACES_DIR"
"$INSTALL_BIN" -o root -g root -m 0755 "$HERE/ensure.sh" "$LOCAL_SBIN/ensure-c1-edge-networks"
"$INSTALL_BIN" -o root -g root -m 0644 "$HERE/c1-edge-networks.service" "$SYSTEMD_ROOT/c1-edge-networks.service"
"$INSTALL_BIN" -o root -g root -m 0755 "$HERE/ensure-forgejo-egress.sh" "$LOCAL_SBIN/ensure-c1-forgejo-egress"
"$INSTALL_BIN" -o root -g root -m 0644 "$HERE/c1-forgejo-egress.service" "$SYSTEMD_ROOT/c1-forgejo-egress.service"
"$INSTALL_BIN" -o root -g root -m 0644 "$HERE/interfaces.d/c1-edge" "$INTERFACES_DIR/c1-edge"
verify
"$SYSTEMCTL_BIN" daemon-reload
"$SYSTEMCTL_BIN" enable c1-edge-networks.service c1-forgejo-egress.service
printf 'EDGE assets installed; activate bond0.2515 during the reviewed host network window before starting the unit\n'
