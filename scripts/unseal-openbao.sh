#!/usr/bin/env bash
set -euo pipefail

readonly SSH_BIN="${SSH_BIN:-ssh}"
readonly CURL_BIN="${CURL_BIN:-curl}"
readonly SSH_TARGET="${OPENBAO_SSH_TARGET:-monosense@10.25.10.20}"
readonly BAO_ADDRESS="${OPENBAO_ADDRESS:-10.25.13.34}"
readonly TTY_DEVICE="${TTY_DEVICE:-/dev/tty}"

fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
health_code() {
    "$CURL_BIN" --resolve "vault.monosense.io:8200:$BAO_ADDRESS" \
        --silent --show-error --output /dev/null --write-out '%{http_code}' \
        https://vault.monosense.io:8200/v1/sys/health
}

[[ $# == 0 ]] || fail 'usage: just openbao-unseal'
[[ -r "$TTY_DEVICE" && -w "$TTY_DEVICE" ]] || fail 'OpenBao unseal requires an interactive terminal'
code="$(health_code)"
case "$code" in
    200)
        printf '%s\n' 'OpenBao is already active and unsealed'
        exit 0
        ;;
    503) ;;
    501) fail 'OpenBao is not initialized; do not use the unseal workflow' ;;
    *) fail "unexpected OpenBao health response: HTTP $code" ;;
esac

container_id="$($SSH_BIN "$SSH_TARGET" 'sudo docker ps --filter label=com.docker.compose.project=openbao-c0 --filter label=com.docker.compose.service=openbao --filter status=running --quiet --no-trunc')"
[[ "$container_id" =~ ^[0-9a-f]{64}$ ]] || fail 'expected exactly one running OpenBao container'

printf '%s\n' 'Enter two distinct offline shares at the two hidden OpenBao prompts.'
for share_number in 1 2; do
    printf 'Share %d of 2:\n' "$share_number"
    "$SSH_BIN" -tt "$SSH_TARGET" "sudo docker exec -it $container_id bao operator unseal" <"$TTY_DEVICE"
done

code="$(health_code)"
[[ "$code" == 200 ]] || fail "OpenBao remained unavailable after threshold unseal: HTTP $code"
printf '%s\n' 'OpenBao is active, unsealed, and serving HTTP 200'
