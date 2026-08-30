#!/usr/bin/env bash
set -euo pipefail

ID_BIN="${ID_BIN:-id}"
INSTALL_BIN="${INSTALL_BIN:-install}"
STAT_BIN="${STAT_BIN:-stat}"
ROOT="${ROOT:-/srv/applications/apps/edge}"

fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
[[ "$($ID_BIN -u)" == 0 ]] || fail 'edge state helper must run as root'
[[ $# -le 1 && "${1:-apply}" =~ ^(check|apply)$ ]] || fail 'usage: ensure-edge-state.sh [check|apply]'

paths=(crowdsec crowdsec-config geolite letsencrypt logs runtime tls tls/releases)
for child in "${paths[@]}"; do
    [[ ! -L "$ROOT/$child" ]] || fail "symlink state path is prohibited: $ROOT/$child"
done
if [[ "${1:-apply}" == apply ]]; then
    "$INSTALL_BIN" -d -m 0755 -o root -g root "$ROOT" "$ROOT/tls" "$ROOT/tls/releases"
    "$INSTALL_BIN" -d -m 0750 -o 1000 -g 1000 \
        "$ROOT/crowdsec" "$ROOT/crowdsec-config" "$ROOT/geolite" "$ROOT/logs"
    "$INSTALL_BIN" -d -m 0750 -o 99 -g 99 "$ROOT/runtime"
    "$INSTALL_BIN" -d -m 0700 -o root -g root "$ROOT/letsencrypt"
    printf '%s\n' '/run/tls/current/combined.pem git.monosense.io edge-test.monosense.io' >"$ROOT/tls/.crt-list.tmp"
    chown root:root "$ROOT/tls/.crt-list.tmp"
    chmod 0644 "$ROOT/tls/.crt-list.tmp"
    mv -f "$ROOT/tls/.crt-list.tmp" "$ROOT/tls/crt-list.txt"
fi
for expected in \
    "0:0:755:$ROOT" \
    "1000:1000:750:$ROOT/crowdsec" \
    "1000:1000:750:$ROOT/crowdsec-config" \
    "1000:1000:750:$ROOT/geolite" \
    "0:0:700:$ROOT/letsencrypt" \
    "99:99:750:$ROOT/runtime" \
    "1000:1000:750:$ROOT/logs" \
    "0:0:755:$ROOT/tls"; do
    IFS=: read -r uid gid mode path <<<"$expected"
    [[ -d "$path" && ! -L "$path" ]] || fail "required edge state path is absent or unsafe: $path"
    [[ "$($STAT_BIN -c '%u:%g:%a' "$path")" == "$uid:$gid:$mode" ]] || fail "edge state ownership or mode drift: $path"
done
[[ -f "$ROOT/tls/crt-list.txt" && ! -L "$ROOT/tls/crt-list.txt" ]] \
    || fail 'HAProxy certificate list is absent or unsafe'
[[ "$($STAT_BIN -c '%u:%g:%a' "$ROOT/tls/crt-list.txt")" == 0:0:644 ]] \
    || fail 'HAProxy certificate list ownership or mode drift'
[[ "$(<"$ROOT/tls/crt-list.txt")" == '/run/tls/current/combined.pem git.monosense.io edge-test.monosense.io' ]] \
    || fail 'HAProxy certificate list content drift'
printf '%s\n' 'Edge state bind sources match the reviewed contract'
