#!/usr/bin/env bash
set -euo pipefail
umask 077
readonly TOKEN_FILE="${TOKEN_FILE:-/opt/doco-cd/secrets/openbao-token}" CURL_BIN="${CURL_BIN:-curl}" PYTHON_BIN="${PYTHON_BIN:-python3}"
readonly URL="${OPENBAO_URL:-https://vault.monosense.io:8200}" MIN_TTL="${MIN_TTL:-21600}"
[[ "$(id -u)" == 0 ]] || { printf 'ERROR: token gate requires root\n' >&2; exit 1; }
[[ -f "$TOKEN_FILE" && ! -L "$TOKEN_FILE" && "$(stat -c '%U:%G:%a' "$TOKEN_FILE")" == root:root:600 ]] || { printf 'ERROR: token file custody mismatch\n' >&2; exit 1; }
IFS= read -r token <"$TOKEN_FILE"; [[ -n "$token" && "$token" != *[[:space:]]* ]] || exit 1
exec 3<<<"header = \"X-Vault-Token: $token\""; unset token
"$CURL_BIN" --silent --show-error --fail-with-body --proto '=https' --tlsv1.2 --config /dev/fd/3 "$URL/v1/auth/token/lookup-self" |
  "$PYTHON_BIN" -c 'import json,sys; d=json.load(sys.stdin)["data"]; ttl=d["ttl"]; ok=d["renewable"] is True and isinstance(ttl,int) and ttl>int(sys.argv[1]); print(f"OpenBao c1 token gate passed ttl={ttl} renewable=true") if ok else None; raise SystemExit(0 if ok else 1)' "$MIN_TTL"
