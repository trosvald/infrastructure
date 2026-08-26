#!/usr/bin/env bash
set -euo pipefail

DOCKER_BIN="${DOCKER_BIN:-docker}"
readonly DOCKER_BIN CONTAINER=librefs-c1
fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
[[ $# == 1 && ( "$1" == start || "$1" == stop ) ]] \
    || fail 'usage: manage-librefs.sh {start|stop}'
if ! "$DOCKER_BIN" container inspect "$CONTAINER" >/dev/null 2>&1; then
    printf 'libreFS container is not deployed; nothing to %s\n' "$1"
    exit 0
fi
status="$("$DOCKER_BIN" inspect "$CONTAINER" --format '{{.State.Status}}')" \
    || fail 'failed to inspect libreFS container state'
case "$1:$status" in
    start:running) printf 'libreFS container is already running\n' ;;
    start:*) "$DOCKER_BIN" start "$CONTAINER" >/dev/null \
        || fail 'failed to start libreFS container' ;;
    stop:running) "$DOCKER_BIN" stop --time 60 "$CONTAINER" >/dev/null \
        || fail 'failed to stop libreFS container' ;;
    stop:*) printf 'libreFS container is already stopped\n' ;;
esac
