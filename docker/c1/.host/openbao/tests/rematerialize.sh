#!/usr/bin/env bash
set -euo pipefail
readonly HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT="$HERE/../rematerialize-librefs-credentials.sh"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin" "$work/data/github.com/trosvald/infrastructure/.git"
printf '%s\n' 'c1-safe-api-secret-canary-abcdefghijklmnopqrstuvwxyz' >"$work/api-secret"
printf '%s\n' present >"$work/container-state"
mkdir -p "$work/data/durable"
printf '%s\n' preserve >"$work/data/durable/sentinel"

cat >"$work/bin/docker" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
case "$1:$2" in
    container:inspect) [[ -f "$CONTAINER_STATE" ]] ;;
    rm:-f)
        [[ "${RM_FAIL:-false}" != true ]] || exit 22
        rm -f "$CONTAINER_STATE"
        ;;
    inspect:librefs-c1)
        if [[ "$*" == *'State.Health.Status'* ]]; then
            if [[ "${HEALTH_FAIL:-false}" == true ]]; then
                printf '%s\n' starting
            elif [[ "${HEALTH_DELAY:-false}" == true && ! -f "$HEALTH_STATE" ]]; then
                printf '%s\n' delayed >"$HEALTH_STATE"
                printf '%s\n' starting
            else
                printf '%s\n' healthy
            fi
        elif [[ "$*" == *'cd.doco.source.url'* ]]; then
            printf '%s\n' "${PROVENANCE_VALUE:-https://github.com/trosvald/infrastructure.git}"
        else
            exit 20
        fi
        ;;
    *) exit 21 ;;
esac
FAKE
cat >"$work/bin/git" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
if [[ "$1" == clone ]]; then
    destination="${@: -1}"
    mkdir -p "$destination/docker/c1"
elif [[ "$*" == *'rev-parse HEAD'* ]]; then
    printf '%040d\n' 1
fi
FAKE
cat >"$work/bin/systemctl" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$SYSTEMCTL_LOG"
FAKE
cat >"$work/bin/controller-gate" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' checked >>"$GATE_LOG"
[[ "${GATE_FAIL:-false}" != true ]]
FAKE
cat >"$work/bin/stat" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "${STAT_RESULT:-root:root:600}"
FAKE
cat >"$work/bin/curl" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$CURL_LOG"
config=''
previous=''
for argument in "$@"; do
    if [[ "$previous" == --config ]]; then config="$argument"; break; fi
    previous="$argument"
done
[[ -n "$config" ]]
[[ "$(cat "$config")" == 'header = "x-api-key: c1-safe-api-secret-canary-abcdefghijklmnopqrstuvwxyz"' ]]
if [[ "${CURL_FAIL:-false}" == true ]]; then exit 22; fi
if [[ "$*" == *'/v1/api/poll/run?wait=true'* ]]; then
    payload="$(cat)"
    printf '%s\n' "$payload" >>"$PAYLOAD_LOG"
    if [[ "${REMOTE_FAIL:-false}" == true && "$payload" == *'https://github.com/trosvald/infrastructure.git'* ]]; then
        exit 22
    fi
    if [[ "$payload" == *'file:///data/c1-librefs-rematerialize-'* ]]; then
        source_name="${payload#*file:///data/}"
        source_name="${source_name%%\"*}"
        mkdir -p "$DATA_ROOT/data/$source_name"
        printf '%s\n' present >"$CONTAINER_STATE"
    fi
    printf '%s\n' '{"job_id":"safe-job-id"}'
elif [[ "$*" == *'/v1/api/run/safe-job-id'* ]]; then
    if [[ "${STATUS_FAIL:-false}" == true ]]; then
        printf '%s\n' '{"content":{"status":"failed"}}'
    else
        printf '%s\n' '{"content":{"status":"succeeded"}}'
    fi
else
    exit 23
fi
FAKE
chmod +x "$work/bin/"*

run() {
    PATH="$work/bin:$PATH" FAKE_UID="${FAKE_UID:-0}" \
        DOCKER_BIN="$work/bin/docker" CURL_BIN="$work/bin/curl" GIT_BIN="$work/bin/git" \
        SYSTEMCTL_BIN="$work/bin/systemctl" SLEEP_BIN=true STAT_BIN="$work/bin/stat" \
        CONTROLLER_GATE="$work/bin/controller-gate" DATA_ROOT="$work/data" \
        API_SECRET_FILE="$work/api-secret" CONTAINER_STATE="$work/container-state" \
        HEALTH_STATE="$work/health-state" SYSTEMCTL_LOG="$work/systemctl.log" \
        GATE_LOG="$work/gate.log" PAYLOAD_LOG="$work/payload.log" CURL_LOG="$work/curl.log" \
        CURL_FAIL="${CURL_FAIL:-false}" GATE_FAIL="${GATE_FAIL:-false}" \
        REMOTE_FAIL="${REMOTE_FAIL:-false}" RM_FAIL="${RM_FAIL:-false}" \
        STATUS_FAIL="${STATUS_FAIL:-false}" STAT_RESULT="${STAT_RESULT:-root:root:600}" \
        HEALTH_DELAY="${HEALTH_DELAY:-false}" HEALTH_FAIL="${HEALTH_FAIL:-false}" \
        PROVENANCE_VALUE="${PROVENANCE_VALUE:-https://github.com/trosvald/infrastructure.git}" \
        "$SCRIPT"
}
must_fail() {
    if run >/dev/null 2>&1; then
        printf 'expected credential rematerialization failure\n' >&2
        exit 1
    fi
}

HEALTH_DELAY=true
export HEALTH_DELAY
output="$(run)"
unset HEALTH_DELAY
[[ "$output" == 'Doco provider-backed libreFS credential rematerialization passed' ]]
[[ "$(sed -n '$=' "$work/payload.log")" == 2 ]]
grep -F '"target":"rotation"' "$work/payload.log" >/dev/null
grep -F 'https://github.com/trosvald/infrastructure.git' "$work/payload.log" >/dev/null
[[ "$(cat "$work/systemctl.log")" == $'stop librefs-c1.service\nstart librefs-c1.service' ]]
[[ "$(cat "$work/gate.log")" == checked ]]
[[ "$(grep -c '/v1/api/run/safe-job-id' "$work/curl.log")" == 2 ]]
[[ -f "$work/container-state" && -f "$work/health-state" ]]
[[ "$(cat "$work/data/durable/sentinel")" == preserve ]]
! compgen -G "$work/data/data/c1-librefs-rematerialize-*" >/dev/null

printf '%s\n' present >"$work/container-state"
rm -f "$work/systemctl.log"
FAKE_UID=1000
export FAKE_UID
must_fail
unset FAKE_UID
! test -e "$work/systemctl.log"

printf '%s\n' present >"$work/container-state"
rm -f "$work/systemctl.log"
GATE_FAIL=true
export GATE_FAIL
must_fail
unset GATE_FAIL
! test -e "$work/systemctl.log"
printf '%s\n' present >"$work/container-state"
rm -f "$work/systemctl.log"
STAT_RESULT=root:root:644
export STAT_RESULT
must_fail
unset STAT_RESULT
! test -e "$work/systemctl.log"

mv "$work/api-secret" "$work/api-secret.real"
ln -s "$work/api-secret.real" "$work/api-secret"
must_fail
rm -f "$work/api-secret"
mv "$work/api-secret.real" "$work/api-secret"
! test -e "$work/systemctl.log"

printf '%s\n' present >"$work/container-state"
rm -f "$work/systemctl.log" "$work/payload.log"
RM_FAIL=true
export RM_FAIL
must_fail
unset RM_FAIL
[[ -f "$work/container-state" ]]
[[ "$(cat "$work/systemctl.log")" == $'stop librefs-c1.service\nstart librefs-c1.service' ]]

rm -f "$work/systemctl.log" "$work/payload.log"
CURL_FAIL=true
export CURL_FAIL
must_fail
unset CURL_FAIL
[[ ! -f "$work/container-state" ]]
[[ "$(cat "$work/systemctl.log")" == 'stop librefs-c1.service' ]]

rm -f "$work/systemctl.log" "$work/payload.log"
output="$(run)"
[[ "$output" == 'Doco provider-backed libreFS credential rematerialization passed' ]]
[[ -f "$work/container-state" ]]
[[ "$(cat "$work/systemctl.log")" == $'stop librefs-c1.service\nstart librefs-c1.service' ]]
printf '%s\n' present >"$work/container-state"
rm -f "$work/systemctl.log" "$work/payload.log" "$work/curl.log"
STATUS_FAIL=true
export STATUS_FAIL
must_fail
unset STATUS_FAIL
[[ ! -f "$work/container-state" ]]
[[ "$(cat "$work/systemctl.log")" == 'stop librefs-c1.service' ]]
[[ "$(grep -c '/v1/api/run/safe-job-id' "$work/curl.log")" == 1 ]]

rm -f "$work/systemctl.log" "$work/payload.log" "$work/curl.log"
output="$(run)"
[[ "$output" == 'Doco provider-backed libreFS credential rematerialization passed' ]]
[[ -f "$work/container-state" ]]
[[ "$(cat "$work/systemctl.log")" == $'stop librefs-c1.service\nstart librefs-c1.service' ]]

printf '%s\n' present >"$work/container-state"
rm -f "$work/systemctl.log" "$work/payload.log"
REMOTE_FAIL=true
export REMOTE_FAIL
must_fail
unset REMOTE_FAIL
[[ "$(cat "$work/systemctl.log")" == 'stop librefs-c1.service' ]]
[[ ! -f "$work/container-state" ]]
[[ "$(cat "$work/data/durable/sentinel")" == preserve ]]
! compgen -G "$work/data/data/c1-librefs-rematerialize-*" >/dev/null

rm -f "$work/systemctl.log" "$work/payload.log"
output="$(run)"
[[ "$output" == 'Doco provider-backed libreFS credential rematerialization passed' ]]

printf '%s\n' present >"$work/container-state"
rm -f "$work/systemctl.log" "$work/payload.log"
HEALTH_FAIL=true
export HEALTH_FAIL
must_fail
unset HEALTH_FAIL
[[ "$(cat "$work/systemctl.log")" == 'stop librefs-c1.service' ]]
[[ ! -f "$work/container-state" ]]

rm -f "$work/systemctl.log" "$work/payload.log"
output="$(run)"
[[ "$output" == 'Doco provider-backed libreFS credential rematerialization passed' ]]

printf '%s\n' present >"$work/container-state"
rm -f "$work/systemctl.log" "$work/payload.log"
PROVENANCE_VALUE=https://invalid.example
export PROVENANCE_VALUE
must_fail
unset PROVENANCE_VALUE
[[ "$(cat "$work/systemctl.log")" == 'stop librefs-c1.service' ]]
[[ ! -f "$work/container-state" ]]

rm -f "$work/systemctl.log" "$work/payload.log"
output="$(run)"
[[ "$output" == 'Doco provider-backed libreFS credential rematerialization passed' ]]
printf 'c1 Doco credential rematerialization tests passed\n'
