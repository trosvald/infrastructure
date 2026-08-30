#!/usr/bin/env bash
set -euo pipefail

PYTHON_BIN="${PYTHON_BIN:-python3}"
DOCKER_BIN="${DOCKER_BIN:-docker}"
FETCHER="${FETCHER:-/usr/local/libexec/fetch-wildcard-certificate.py}"
INSTALLER="${INSTALLER:-/usr/local/libexec/install-certificate.py}"
TOKEN_FILE="${TOKEN_FILE:-/opt/monitoring/secrets/wildcard-reader-c0.token}"
TARGET="${TARGET:-/var/lib/monosense-monitoring/tls}"
target_before="$(readlink "$TARGET/current" 2>/dev/null || true)"
target_changed=false

fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
[[ "$(id -u)" == 0 ]] || fail 'c0 wildcard update requires root'
[[ -x "$FETCHER" && -x "$INSTALLER" ]] || fail 'wildcard installer assets are missing'
rollback() {
    if [[ "$target_changed" == true ]]; then
        "$PYTHON_BIN" "$INSTALLER" rollback --target "$TARGET" >/dev/null 2>&1 || true
        for container in gatus-c0 vector-c0; do
            "$DOCKER_BIN" restart "$container" >/dev/null 2>&1 || true
        done
    fi
}
trap rollback ERR
"$PYTHON_BIN" "$FETCHER" --token-file "$TOKEN_FILE" --target "$TARGET" \
    --uid 65534 --gid 65534
if [[ "$(readlink "$TARGET/current" 2>/dev/null || true)" != "$target_before" ]]; then
    target_changed=true
fi
if "$DOCKER_BIN" inspect vector-c0 >/dev/null 2>&1; then
    "$DOCKER_BIN" exec vector-c0 vector validate --no-environment /etc/vector/vector.yaml >/dev/null
fi
for container in gatus-c0 vector-c0; do
    if "$DOCKER_BIN" inspect "$container" >/dev/null 2>&1; then
        "$DOCKER_BIN" restart "$container" >/dev/null
    fi
done
trap - ERR
printf '%s\n' 'c0 wildcard certificate generation validated and activated'
