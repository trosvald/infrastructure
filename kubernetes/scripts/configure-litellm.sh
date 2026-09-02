#!/usr/bin/env bash
set -euo pipefail

fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
for command in bao curl jq mktemp sha256sum; do
    command -v "$command" >/dev/null 2>&1 || fail "$command is required"
done
[[ -n "${BAO_ADDR:-}" && -n "${BAO_TOKEN:-}" ]] || fail 'run through scripts/with-openbao-runtime.sh'
[[ "${BAO_SKIP_VERIFY:-false}" != true ]] || fail 'OpenBao TLS verification bypasses are forbidden'
readonly record=platform/kubernetes/ai/litellm
readonly endpoint=https://litellm-admin.internal
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
chmod 0700 "$work"
for key in breakglass_master_key memini_virtual_key forgejo_virtual_key; do
    bao kv get -mount=kv -field="$key" "$record" >"$work/$key"
    chmod 0600 "$work/$key"
done
cat >"$work/curl.conf" <<EOF
silent
show-error
fail
header = "Authorization: Bearer $(<"$work/breakglass_master_key")"
header = "Content-Type: application/json"
EOF
chmod 0600 "$work/curl.conf"

upsert_key() {
    local alias="$1" key_file="$2" model="$3" rpm="$4" tpm="$5" parallel="$6" max_budget="$7" duration="$8"
    jq -n --rawfile key "$key_file" --arg key_alias "$alias" --arg model "$model" \
        --argjson rpm_limit "$rpm" --argjson tpm_limit "$tpm" --argjson max_parallel_requests "$parallel" \
        --argjson max_budget "$max_budget" --arg budget_duration "$duration" \
        '{key:($key|rtrimstr("\n")),key_alias:$key_alias,models:[$model],rpm_limit:$rpm_limit,tpm_limit:$tpm_limit,max_parallel_requests:$max_parallel_requests,max_budget:$max_budget,budget_duration:$budget_duration}' \
        >"$work/$alias.json"
    hash="$(printf '%s' "$(<"$key_file")" | sha256sum | cut -d' ' -f1)"
    existing="$(curl --config "$work/curl.conf" "$endpoint/key/list?page=1&size=100" | jq --arg alias "$alias" -r '.keys[]? | select(.key_alias == $alias) | .token' | head -n1)"
    if [[ -n "$existing" ]]; then
        jq --arg key "$existing" '. + {key:$key}' "$work/$alias.json" >"$work/$alias-update.json"
        curl --config "$work/curl.conf" --request POST --data-binary @"$work/$alias-update.json" "$endpoint/key/update" >/dev/null
    else
        curl --config "$work/curl.conf" --request POST --data-binary @"$work/$alias.json" "$endpoint/key/generate" >/dev/null
    fi
    printf '%s %s\n' "$alias" "$hash" >>"$work/configured"
}

upsert_key memini "$work/memini_virtual_key" memini-chat 20 200000 2 5 30d
# forgejo-codex carries a synthetic per-request unit cost so the 1d budget is an exact 500-request cap.
upsert_key forgejo "$work/forgejo_virtual_key" forgejo-codex 30 1000000 2 500 1d
curl --config "$work/curl.conf" "$endpoint/key/list?page=1&size=100" >"$work/keys.json"
jq -e '[.keys[] | select(.key_alias == "memini" and .rpm_limit == 20 and .tpm_limit == 200000 and .max_parallel_requests == 2)] | length == 1' "$work/keys.json" >/dev/null
jq -e '[.keys[] | select(.key_alias == "forgejo" and .rpm_limit == 30 and .max_parallel_requests == 2)] | length == 1' "$work/keys.json" >/dev/null
printf 'LiteLLM Memini and Forgejo virtual-key quotas configured without exposing key material\n'
