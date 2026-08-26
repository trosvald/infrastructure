#!/usr/bin/env bash
set -euo pipefail
umask 077
readonly TOKEN_FILE="${TOKEN_FILE:-/opt/doco-cd/secrets/openbao-token}"
readonly CURL_BIN="${CURL_BIN:-curl}" PYTHON_BIN="${PYTHON_BIN:-python3}"
readonly URL="${OPENBAO_URL:-https://vault.monosense.io:8200}"
[[ "$(id -u)" == 0 ]] || { printf 'ERROR: renewal requires root\n' >&2; exit 1; }
[[ -f "$TOKEN_FILE" && ! -L "$TOKEN_FILE" && "$(stat -c '%U:%G:%a' "$TOKEN_FILE")" == root:root:600 ]] || { printf 'ERROR: token file custody mismatch\n' >&2; exit 1; }
IFS= read -r token <"$TOKEN_FILE"; [[ -n "$token" && "$token" != *[[:space:]]* ]] || { printf 'ERROR: invalid token file\n' >&2; exit 1; }
exec 3<<<"header = \"X-Vault-Token: $token\""
unset token
summary="$(
  "$CURL_BIN" --silent --show-error --fail-with-body --proto '=https' --tlsv1.2 --config /dev/fd/3 --request POST "$URL/v1/auth/token/renew-self" |
    "$PYTHON_BIN" -c '
import json,sys
try:
 x=json.load(sys.stdin); a=x["auth"]; ttl=a["lease_duration"]; renewable=a["renewable"]
 valid=isinstance(ttl,int) and ttl>21600 and renewable is True
except (KeyError,TypeError,ValueError): valid=False
if not valid: raise SystemExit(1)
print(f"ttl={ttl} renewable=true")
' )" || { printf 'ERROR: OpenBao renewal request or response validation failed\n' >&2; exit 1; }
exec 3<&-
printf 'OpenBao c1 token renewed %s at %s\n' "$summary" "$(date -u +%FT%TZ)"
