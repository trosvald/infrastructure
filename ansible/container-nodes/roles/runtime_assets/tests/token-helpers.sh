#!/usr/bin/env bash
set -euo pipefail

readonly HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly RENEW="$HERE/../files/renew-c1-openbao-token"
readonly GATE="$HERE/../files/check-c1-openbao-token"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin"
token_file="$work/token"
printf '%s\n' 'c1-safe-canary-token' >"$token_file"
chmod 0600 "$token_file"

cat >"$work/bin/id" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "${FAKE_UID:-0}"
FAKE
cat >"$work/bin/stat" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "${STAT_RESULT:-root:root:600}"
FAKE
cat >"$work/bin/date" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' '2026-08-26T00:00:00Z'
FAKE
cat >"$work/bin/curl" <<'FAKE'
#!/usr/bin/env bash
set -eu
printf '%s\n' "$*" >>"$CURL_LOG"
[[ "${CURL_FAIL:-false}" != true ]] || exit 22
config=
previous=
for argument in "$@"; do
    if [[ "$previous" == --config ]]; then config="$argument"; break; fi
    previous="$argument"
done
[[ -n "$config" ]]
header="$(cat "$config")"
[[ "$header" == 'header = "X-Vault-Token: c1-safe-canary-token"' ]] || exit 23
if [[ "$*" == *renew-self* ]]; then
    if [[ "${BAD_RESPONSE:-false}" == true ]]; then
        printf '%s\n' '{"auth":{"lease_duration":1,"renewable":false,"client_token":"c1-safe-canary-token"}}'
    else
        printf '%s\n' '{"auth":{"lease_duration":86400,"renewable":true,"client_token":"c1-safe-canary-token"}}'
    fi
elif [[ "$*" == *lookup-self* ]]; then
    if [[ "${BAD_RESPONSE:-false}" == true ]]; then
        printf '%s\n' '{"data":{"ttl":1,"renewable":false}}'
    else
        printf '%s\n' '{"data":{"ttl":86400,"renewable":true}}'
    fi
else
    exit 24
fi
FAKE
chmod +x "$work/bin/id" "$work/bin/stat" "$work/bin/date" "$work/bin/curl"

export CURL_LOG="$work/curl.log"
run_renew() {
    PATH="$work/bin:$PATH" TOKEN_FILE="$token_file" CURL_BIN="$work/bin/curl" \
        CURL_FAIL="${CURL_FAIL:-false}" BAD_RESPONSE="${BAD_RESPONSE:-false}" \
        STAT_RESULT="${STAT_RESULT:-root:root:600}" FAKE_UID="${FAKE_UID:-0}" \
        "$RENEW"
}
run_gate() {
    PATH="$work/bin:$PATH" TOKEN_FILE="$token_file" CURL_BIN="$work/bin/curl" \
        CURL_FAIL="${CURL_FAIL:-false}" BAD_RESPONSE="${BAD_RESPONSE:-false}" \
        STAT_RESULT="${STAT_RESULT:-root:root:600}" FAKE_UID="${FAKE_UID:-0}" \
        "$GATE"
}
must_fail() {
    if "$@" >/dev/null 2>&1; then
        printf 'expected OpenBao helper failure\n' >&2
        exit 1
    fi
}

output="$(run_renew)"
[[ "$output" == *'ttl=86400 renewable=true'* ]]
[[ "$output" != *'c1-safe-canary-token'* ]]
output="$(run_gate)"
[[ "$output" == *'ttl=86400 renewable=true'* ]]
[[ "$output" != *'c1-safe-canary-token'* ]]
! grep -F 'c1-safe-canary-token' "$CURL_LOG" >/dev/null

grep -F -- "--proto =https" "$CURL_LOG" >/dev/null
grep -F 'auth/token/renew-self' "$CURL_LOG" >/dev/null
grep -F 'auth/token/lookup-self' "$CURL_LOG" >/dev/null

CURL_FAIL=true; export CURL_FAIL; must_fail run_renew; must_fail run_gate; unset CURL_FAIL
BAD_RESPONSE=true; export BAD_RESPONSE; must_fail run_renew; must_fail run_gate; unset BAD_RESPONSE
STAT_RESULT=root:root:644; export STAT_RESULT; must_fail run_renew; must_fail run_gate; unset STAT_RESULT
FAKE_UID=1000; export FAKE_UID; must_fail run_renew; must_fail run_gate; unset FAKE_UID

printf '%s\n' 'invalid token value' >"$token_file"
must_fail run_renew
must_fail run_gate
printf '%s\n' 'c1-safe-canary-token' >"$token_file"
chmod 0600 "$token_file"
mv "$token_file" "$work/real-token"
ln -s "$work/real-token" "$token_file"
must_fail run_renew
must_fail run_gate

printf 'c1 OpenBao renewal and TTL helper tests passed\n'
