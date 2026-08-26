#!/usr/bin/env bash
set -euo pipefail
umask 077

readonly API_SECRET_FILE="${API_SECRET_FILE:-/opt/doco-cd/secrets/api_secret}"
readonly DOCKER_BIN="${DOCKER_BIN:-docker}" CURL_BIN="${CURL_BIN:-curl}"
readonly PYTHON_BIN="${PYTHON_BIN:-python3}" SLEEP_BIN="${SLEEP_BIN:-sleep}"
readonly DOCO_URL="${DOCO_URL:-http://127.0.0.1:8080}"
readonly REQUIRE_PROVIDER_CANARY="${REQUIRE_PROVIDER_CANARY:-true}"
readonly APP_CONFIG_URL="https://raw.githubusercontent.com/trosvald/infrastructure/main/docker/c1/librefs/.doco-cd.yaml"

fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
[[ "$(id -u)" == 0 ]] || fail 'controller gate requires root'
[[ -f "$API_SECRET_FILE" && ! -L "$API_SECRET_FILE" \
   && "$(stat -c '%U:%G:%a' "$API_SECRET_FILE")" == root:root:600 ]] \
    || fail 'Doco API secret custody mismatch'
IFS= read -r api_secret <"$API_SECRET_FILE"
[[ "$REQUIRE_PROVIDER_CANARY" == true || "$REQUIRE_PROVIDER_CANARY" == false ]] \
    || fail 'REQUIRE_PROVIDER_CANARY must be true or false'
[[ -n "$api_secret" && "$api_secret" != *[[:space:]]* ]] \
    || fail 'invalid Doco API secret file'

healthy=false
for _ in $(seq 1 90); do
    status="$($DOCKER_BIN inspect doco-cd-c1 \
        --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' \
        2>/dev/null || true)"
    if [[ "$status" == healthy ]]; then
        healthy=true
        break
    fi
    "$SLEEP_BIN" 1
done
[[ "$healthy" == true ]] || fail 'Doco controller did not become healthy'

if [[ "$REQUIRE_PROVIDER_CANARY" == true ]]; then
    app_config="$(
        "$CURL_BIN" --silent --show-error --fail-with-body --proto '=https' --tlsv1.2 \
            "$APP_CONFIG_URL"
    )" || fail 'provider-backed c1 app is absent from public main'
    "$PYTHON_BIN" -c '
import sys
actual=[
 line.rstrip()
 for line in sys.stdin.read().splitlines()
 if line.strip() and line.strip()!="---"
]
expected=[
 "name: librefs-c1",
 "external_secrets:",
 "  LIBREFS_ROOT_USER: kv:kv:docker/c1/librefs:root_user",
 "  LIBREFS_ROOT_PASSWORD: kv:kv:docker/c1/librefs:root_password",
]
raise SystemExit(0 if actual==expected else 1)
' <<<"$app_config" || fail 'public main lacks the exact active provider-backed c1 app'
    unset app_config
fi
exec 3<<<"header = \"x-api-key: $api_secret\""
poll_response="$(
    printf '%s\n' '[{"url":"https://github.com/trosvald/infrastructure.git","reference":"refs/heads/main","interval":"180s","watch":false}]' \
        | "$CURL_BIN" --silent --show-error --fail-with-body --proto '=http' \
            --config /dev/fd/3 --header 'Content-Type: application/json' \
            --request POST --data-binary @- "$DOCO_URL/v1/api/poll/run?wait=true"
)" || fail 'Doco provider canary poll request failed'
exec 3<&-
job_id="$(
    "$PYTHON_BIN" -c '
import json,sys
x=json.load(sys.stdin)
job=x.get("job_id") or x.get("jobId")
if not isinstance(job,str) or not job: raise SystemExit(1)
print(job)
' <<<"$poll_response"
)" || fail 'Doco provider canary poll returned no job identifier'
unset poll_response

exec 3<<<"header = \"x-api-key: $api_secret\""
unset api_secret
run_response="$(
    "$CURL_BIN" --silent --show-error --fail-with-body --proto '=http' \
        --config /dev/fd/3 "$DOCO_URL/v1/api/run/$job_id"
)" || fail 'Doco provider canary run lookup failed'
exec 3<&-
unset job_id
"$PYTHON_BIN" -c '
import json,sys
x=json.load(sys.stdin)
data=x.get("data",x)
status=data.get("status") if isinstance(data,dict) else None
raise SystemExit(0 if status=="succeeded" else 1)
' <<<"$run_response" || fail 'Doco provider canary poll did not succeed'
unset run_response
printf 'Doco controller health and OpenBao-backed poll canary passed\n'
