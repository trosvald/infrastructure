#!/usr/bin/env bash
set -euo pipefail

PYTHON_BIN="${PYTHON_BIN:-python3}"
DOCKER_BIN="${DOCKER_BIN:-docker}"
SYSTEMCTL_BIN="${SYSTEMCTL_BIN:-systemctl}"
FETCHER="${FETCHER:-/usr/local/libexec/fetch-wildcard-certificate.py}"
INSTALLER="${INSTALLER:-/usr/local/libexec/install-certificate.py}"
TOKEN_FILE="${TOKEN_FILE:-/opt/edge/secrets/wildcard-reader-c1.token}"
EDGE_TARGET="${EDGE_TARGET:-/srv/applications/apps/edge/tls}"
LIBREFS_TARGET="${LIBREFS_TARGET:-/srv/librefs/certs}"

fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
[[ "$(id -u)" == 0 ]] || fail 'c1 wildcard update requires root'
[[ -x "$FETCHER" && -x "$INSTALLER" ]] || fail 'wildcard installer assets are missing'

rollback() {
    "$PYTHON_BIN" "$INSTALLER" rollback --target "$EDGE_TARGET" >/dev/null 2>&1 || true
    "$PYTHON_BIN" "$INSTALLER" rollback --target "$LIBREFS_TARGET" >/dev/null 2>&1 || true
}
trap rollback ERR
"$PYTHON_BIN" "$FETCHER" --token-file "$TOKEN_FILE" --target "$EDGE_TARGET" \
    --uid 99 --gid 99 --combined
"$PYTHON_BIN" "$FETCHER" --token-file "$TOKEN_FILE" --target "$LIBREFS_TARGET" \
    --uid 1000 --gid 1000 --minio
if "$DOCKER_BIN" inspect haproxy-c1 >/dev/null 2>&1; then
    "$DOCKER_BIN" exec haproxy-c1 haproxy -c -f /usr/local/etc/haproxy/haproxy.cfg >/dev/null
    "$DOCKER_BIN" kill --signal HUP haproxy-c1 >/dev/null
fi
if "$DOCKER_BIN" inspect librefs-c1 >/dev/null 2>&1; then
    "$SYSTEMCTL_BIN" restart librefs-c1.service
fi
trap - ERR
printf '%s\n' 'c1 wildcard certificate generation validated and activated'
