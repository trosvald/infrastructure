#!/usr/bin/env bash
set -euo pipefail

readonly HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT="$HERE/../check-doco-controller.sh"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin"
api_file="$work/api-secret"
printf '%s\n' 'c1-safe-api-secret-canary-abcdefghijklmnopqrstuvwxyz' >"$api_file"
chmod 0600 "$api_file"

cat >"$work/bin/id" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "${FAKE_UID:-0}"
FAKE
cat >"$work/bin/stat" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "${STAT_RESULT:-root:root:600}"
FAKE
cat >"$work/bin/sleep" <<'FAKE'
#!/usr/bin/env bash
exit 0
FAKE
cat >"$work/bin/docker" <<'FAKE'
#!/usr/bin/env bash
set -eu
printf '%s\n' "$*" >>"$DOCKER_LOG"
[[ "${DOCKER_FAIL:-false}" != true ]] || exit 1
if [[ "$1" == inspect ]]; then
    if [[ "${UNHEALTHY:-false}" == true ]]; then printf '%s\n' starting; else printf '%s\n' healthy; fi
    exit
fi
exit 2
FAKE
cat >"$work/bin/curl" <<'FAKE'
#!/usr/bin/env bash
set -eu
printf '%s\n' "$*" >>"$CURL_LOG"
[[ "${CURL_FAIL:-false}" != true ]] || exit 22
if [[ "$*" == *'raw.githubusercontent.com/trosvald/infrastructure/main/docker/c1/librefs/.doco-cd.yaml'* ]]; then
    [[ "${APP_MISSING:-false}" != true ]] || exit 22
    if [[ "${BAD_MAPPING:-false}" == true ]]; then
        printf '%s\n' 'name: librefs-c1'
        printf '%s\n' 'not_external_secrets:'
        printf '%s\n' '  LIBREFS_ROOT_USER: kv:kv:docker/c1/librefs:root_user'
        printf '%s\n' '  LIBREFS_ROOT_PASSWORD: kv:kv:docker/c1/librefs:root_password'
    else
        printf '%s\n' 'name: librefs-c1'
        printf '%s\n' 'external_secrets:'
        printf '%s\n' '  LIBREFS_ROOT_USER: kv:kv:docker/c1/librefs:root_user'
        printf '%s\n' '  LIBREFS_ROOT_PASSWORD: kv:kv:docker/c1/librefs:root_password'
    fi
    exit
fi
config=
previous=
for argument in "$@"; do
    if [[ "$previous" == --config ]]; then config="$argument"; break; fi
    previous="$argument"
done
[[ -n "$config" ]]
header="$(cat "$config")"
[[ "$header" == 'header = "x-api-key: c1-safe-api-secret-canary-abcdefghijklmnopqrstuvwxyz"' ]] || exit 23
if [[ "$*" == *'/v1/api/poll/run?wait=true'* ]]; then
    cat >/dev/null
    if [[ "${BAD_JOB:-false}" == true ]]; then printf '%s\n' '{"data":"poll jobs complete"}'; else printf '%s\n' '{"data":"poll jobs complete","job_id":"safe-job-id"}'; fi
elif [[ "$*" == *'/v1/api/run/safe-job-id'* ]]; then
    if [[ "${FAILED_RUN:-false}" == true ]]; then printf '%s\n' '{"data":{"status":"failed"}}'; else printf '%s\n' '{"data":{"status":"succeeded"}}'; fi
else
    exit 24
fi
FAKE
chmod +x "$work/bin/"*
export DOCKER_LOG="$work/docker.log" CURL_LOG="$work/curl.log"

run() {
    PATH="$work/bin:$PATH" API_SECRET_FILE="$api_file" \
        DOCKER_BIN="$work/bin/docker" CURL_BIN="$work/bin/curl" SLEEP_BIN="$work/bin/sleep" \
        FAKE_UID="${FAKE_UID:-0}" STAT_RESULT="${STAT_RESULT:-root:root:600}" \
        DOCKER_FAIL="${DOCKER_FAIL:-false}" UNHEALTHY="${UNHEALTHY:-false}" \
        CURL_FAIL="${CURL_FAIL:-false}" BAD_JOB="${BAD_JOB:-false}" FAILED_RUN="${FAILED_RUN:-false}" \
        APP_MISSING="${APP_MISSING:-false}" BAD_MAPPING="${BAD_MAPPING:-false}" \
        REQUIRE_PROVIDER_CANARY="${REQUIRE_PROVIDER_CANARY:-true}" "$SCRIPT"
}
must_fail() {
    if run >/dev/null 2>&1; then
        printf 'expected controller gate failure\n' >&2
        exit 1
    fi
}

output="$(run)"
[[ "$output" == 'Doco controller health and OpenBao-backed poll canary passed' ]]
[[ "$output" != *'c1-safe-api-secret-canary'* ]]
! grep -F 'c1-safe-api-secret-canary' "$CURL_LOG" >/dev/null
grep -F '/v1/api/poll/run?wait=true' "$CURL_LOG" >/dev/null
grep -F '/v1/api/run/safe-job-id' "$CURL_LOG" >/dev/null

for variable in FAKE_UID STAT_RESULT DOCKER_FAIL UNHEALTHY CURL_FAIL APP_MISSING BAD_MAPPING BAD_JOB FAILED_RUN; do
    case "$variable" in
        FAKE_UID) value=1000 ;;
        STAT_RESULT) value=root:root:644 ;;
        *) value=true ;;
    esac
    printf -v "$variable" '%s' "$value"
    export "$variable"
    must_fail
    unset "$variable"
done

APP_MISSING=true
REQUIRE_PROVIDER_CANARY=false
export APP_MISSING REQUIRE_PROVIDER_CANARY
run >/dev/null
unset APP_MISSING REQUIRE_PROVIDER_CANARY

mv "$api_file" "$work/real-api-secret"
ln -s "$work/real-api-secret" "$api_file"
must_fail
printf 'c1 Doco controller provider gate tests passed\n'
