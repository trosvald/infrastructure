#!/usr/bin/env bash
set -euo pipefail

DOCKER_BIN="${DOCKER_BIN:-docker}"
CURL_BIN="${CURL_BIN:-curl}"
JQ_BIN="${JQ_BIN:-jq}"
GIT_BIN="${GIT_BIN:-git}"
SYSTEMCTL_BIN="${SYSTEMCTL_BIN:-systemctl}"
SLEEP_BIN="${SLEEP_BIN:-sleep}"
STAT_BIN="${STAT_BIN:-stat}"
CONTROLLER_GATE="${CONTROLLER_GATE:-/usr/local/sbin/check-c1-doco-controller}"
DATA_ROOT="${DATA_ROOT:-/var/lib/docker/volumes/doco-cd-c1-data/_data}"
API_SECRET_FILE="${API_SECRET_FILE:-/opt/doco-cd/secrets/api_secret}"
readonly DOCKER_BIN CURL_BIN JQ_BIN GIT_BIN SYSTEMCTL_BIN SLEEP_BIN STAT_BIN
readonly CONTROLLER_GATE DATA_ROOT API_SECRET_FILE
readonly CONTAINER=librefs-c1 SERVICE=librefs-c1.service
readonly REMOTE_URL=https://github.com/trosvald/infrastructure.git
readonly REPOSITORY_ROOT="$DATA_ROOT/github.com/trosvald/infrastructure"
source_name="c1-librefs-rematerialize-$$"
source_root="$DATA_ROOT/$source_name"
cache_root="$DATA_ROOT/data/$source_name"
config="$source_root/docker/c1/.doco-cd.rotation.yaml"

service_stopped=false
prior_container_preserved=false
normalization_verified=false
fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
cleanup() {
    local rc=$?
    trap - EXIT
    rm -rf "$source_root" "$cache_root"
    if [[ "$service_stopped" == true && "$prior_container_preserved" == false \
       && "$normalization_verified" == false ]] \
       && "$DOCKER_BIN" container inspect "$CONTAINER" >/dev/null 2>&1; then
        "$DOCKER_BIN" rm -f "$CONTAINER" >/dev/null 2>&1 \
            || printf 'ERROR: failed to remove unverified rematerialized container\n' >&2
    elif [[ "$service_stopped" == true ]] \
       && [[ "$prior_container_preserved" == true || "$normalization_verified" == true ]] \
       && "$DOCKER_BIN" container inspect "$CONTAINER" >/dev/null 2>&1; then
        "$SYSTEMCTL_BIN" start "$SERVICE" >/dev/null 2>&1 \
            || printf 'ERROR: failed to restore systemd ownership after rematerialization failure\n' >&2
    fi
    exit "$rc"
}
trap cleanup EXIT

[[ "${FAKE_UID:-$(id -u)}" == 0 ]] || fail 'must run as root'
[[ -f "$API_SECRET_FILE" ]] || fail 'Doco API secret file is missing'
[[ -d "$REPOSITORY_ROOT/.git" ]] || fail 'Doco main repository checkout is missing'
[[ ! -L "$API_SECRET_FILE" ]] || fail 'Doco API secret file must not be a symlink'
[[ "$("$STAT_BIN" -c '%U:%G:%a' "$API_SECRET_FILE")" == root:root:600 ]] \
    || fail 'Doco API secret file must be root:root mode 0600'
container_present=false
if "$DOCKER_BIN" container inspect "$CONTAINER" >/dev/null 2>&1; then
    container_present=true
fi

IFS= read -r api_secret <"$API_SECRET_FILE"
prior_container_preserved="$container_present"
[[ -n "$api_secret" && "$api_secret" != *[$'\t\r\n ']* ]] \
    || fail 'Doco API secret file is invalid'
if [[ "$container_present" == true ]]; then
    "$CONTROLLER_GATE" >/dev/null \
        || fail 'Doco controller/provider preflight failed before libreFS mutation'
fi

poll() {
    local payload="$1" response job_id
    exec 3<<<"header = \"x-api-key: $api_secret\""
    response="$(
        printf '%s\n' "$payload" \
            | "$CURL_BIN" --silent --show-error --fail-with-body --proto '=http' \
                --config /dev/fd/3 --header 'Content-Type: application/json' \
                --request POST --data-binary @- \
                'http://127.0.0.1:8080/v1/api/poll/run?wait=true'
    )" || fail 'Doco poll request failed'
    exec 3<&-
    job_id="$("$JQ_BIN" -er '.job_id' <<<"$response")" \
        || fail 'Doco poll returned no job identifier'
    unset response
    exec 3<<<"header = \"x-api-key: $api_secret\""
    "$CURL_BIN" --silent --show-error --fail-with-body --proto '=http' \
        --config /dev/fd/3 "http://127.0.0.1:8080/v1/api/run/$job_id" \
        | "$JQ_BIN" -e '.content.status == "succeeded"' >/dev/null \
        || fail 'Doco poll did not succeed'
    exec 3<&-
    unset job_id
}
wait_healthy() {
    local attempt
    for attempt in $(seq 1 60); do
        if [[ "$("$DOCKER_BIN" inspect "$CONTAINER" \
            --format '{{if .State.Health}}{{.State.Health.Status}}{{end}}' 2>/dev/null)" == healthy ]]; then
            return 0
        fi
        "$SLEEP_BIN" 1
    done
    return 1
}

rm -rf "$source_root" "$cache_root"
"$GIT_BIN" clone --quiet --no-hardlinks "$REPOSITORY_ROOT" "$source_root"
"$GIT_BIN" -C "$source_root" checkout --quiet -b c1-librefs-rematerialize origin/main
cat >"$config" <<'YAML'
---
name: librefs-c1
working_dir: ./docker/c1/librefs
compose_files:
  - compose.yml
force_recreate: true
external_secrets:
  LIBREFS_ROOT_USER: kv:kv:docker/c1/librefs:root_user
  LIBREFS_ROOT_PASSWORD: kv:kv:docker/c1/librefs:root_password
YAML
chmod 0600 "$config"
"$GIT_BIN" -C "$source_root" add docker/c1/.doco-cd.rotation.yaml
"$GIT_BIN" -C "$source_root" -c user.name=c1-librefs-rematerialize \
    -c user.email=local-only.invalid commit --quiet \
    -m 'local-only libreFS credential rematerialization'
revision="$("$GIT_BIN" -C "$source_root" rev-parse HEAD)"
local_payload="$(
    "$JQ_BIN" -cn --arg url "file:///data/$source_name" --arg reference "$revision" \
        '[{url:$url,reference:$reference,target:"rotation",interval:"180s",watch:false}]'
)"
unset revision

"$SYSTEMCTL_BIN" stop "$SERVICE"
service_stopped=true
if [[ "$container_present" == true ]]; then
    "$DOCKER_BIN" rm -f "$CONTAINER" >/dev/null \
        || fail 'failed to remove the prior stateless libreFS container'
    prior_container_preserved=false
fi
poll "$local_payload"
unset local_payload
"$DOCKER_BIN" container inspect "$CONTAINER" >/dev/null 2>&1 \
    || fail 'Doco did not recreate libreFS'

remote_payload='[{"url":"https://github.com/trosvald/infrastructure.git","reference":"refs/heads/main","interval":"180s","watch":false}]'
poll "$remote_payload"
unset remote_payload api_secret
wait_healthy || fail 'rematerialized libreFS container did not become healthy'
[[ "$("$DOCKER_BIN" inspect "$CONTAINER" --format '{{index .Config.Labels "cd.doco.source.url"}}')" == "$REMOTE_URL" ]] \
    || fail 'libreFS Doco provenance did not normalize to the remote source'
normalization_verified=true
"$SYSTEMCTL_BIN" start "$SERVICE" \
    || { normalization_verified=false; fail 'failed to restore libreFS systemd ownership'; }
service_stopped=false
printf 'Doco provider-backed libreFS credential rematerialization passed\n'
