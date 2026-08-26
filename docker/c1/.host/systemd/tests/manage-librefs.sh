#!/usr/bin/env bash
set -euo pipefail

readonly HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT="$HERE/../manage-librefs.sh"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
cat >"$work/docker" <<'FAKE'
#!/usr/bin/env bash
set -eu
printf '%s\n' "$*" >>"$DOCKER_LOG"
if [[ "$1 $2" == 'container inspect' ]]; then
    [[ "${PRESENT:-false}" == true ]] || exit 1
    exit
fi
if [[ "$1" == inspect ]]; then
    [[ "${INSPECT_FAIL:-false}" != true ]] || exit 2
    printf '%s\n' "${STATUS:-exited}"
    exit
fi
if [[ "$1" == start ]]; then [[ "${START_FAIL:-false}" != true ]] || exit 3; exit; fi
if [[ "$1" == stop ]]; then [[ "${STOP_FAIL:-false}" != true ]] || exit 4; exit; fi
exit 5
FAKE
chmod +x "$work/docker"
export DOCKER_LOG="$work/calls"
run() {
    PRESENT="${PRESENT:-false}" STATUS="${STATUS:-exited}" \
        INSPECT_FAIL="${INSPECT_FAIL:-false}" START_FAIL="${START_FAIL:-false}" \
        STOP_FAIL="${STOP_FAIL:-false}" DOCKER_BIN="$work/docker" "$SCRIPT" "$1" >/dev/null
}
must_fail() { if run "$@" 2>/dev/null; then printf 'expected libreFS manager failure\n' >&2; exit 1; fi; }

: >"$DOCKER_LOG"; run start; ! grep -F 'start librefs-c1' "$DOCKER_LOG" >/dev/null
: >"$DOCKER_LOG"; PRESENT=true STATUS=exited run start; grep -Fx 'start librefs-c1' "$DOCKER_LOG" >/dev/null
: >"$DOCKER_LOG"; PRESENT=true STATUS=running run start; ! grep -F 'start librefs-c1' "$DOCKER_LOG" >/dev/null
: >"$DOCKER_LOG"; PRESENT=true STATUS=running run stop; grep -Fx 'stop --time 60 librefs-c1' "$DOCKER_LOG" >/dev/null
: >"$DOCKER_LOG"; PRESENT=true STATUS=exited run stop; ! grep -F 'stop --time' "$DOCKER_LOG" >/dev/null
PRESENT=true INSPECT_FAIL=true; export PRESENT INSPECT_FAIL; must_fail start; unset PRESENT INSPECT_FAIL
PRESENT=true START_FAIL=true; export PRESENT START_FAIL; must_fail start; unset PRESENT START_FAIL
PRESENT=true STATUS=running STOP_FAIL=true; export PRESENT STATUS STOP_FAIL; must_fail stop; unset PRESENT STATUS STOP_FAIL
printf 'c1 mount-gated libreFS manager tests passed\n'
