#!/usr/bin/env bash
set -euo pipefail

fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
for command in bao jq mktemp openssl python3 sha256sum; do
    command -v "$command" >/dev/null 2>&1 || fail "$command is required"
done
[[ -n "${BAO_ADDR:-}" && -n "${BAO_TOKEN:-}" ]] || fail 'run through scripts/with-openbao-runtime.sh'
[[ "${BAO_SKIP_VERIFY:-false}" != true ]] || fail 'OpenBao TLS verification bypasses are forbidden'
: "${MINIMAX_API_KEY:?set MINIMAX_API_KEY}"
: "${CODEX_AUTH_JSON:?set CODEX_AUTH_JSON to the reviewed Codex OAuth JSON file}"
[[ -f "$CODEX_AUTH_JSON" && ! -L "$CODEX_AUTH_JSON" ]] || fail 'CODEX_AUTH_JSON must be a regular non-symlink file'
jq -e 'type == "object" and ((.refresh_token // .tokens.refresh_token // "") | length > 20)' "$CODEX_AUTH_JSON" >/dev/null \
    || fail 'Codex OAuth JSON lacks a refresh token'

readonly llmkube_record=platform/kubernetes/ai/llmkube
readonly memini_record=platform/kubernetes/ai/memini
readonly litellm_record=platform/kubernetes/ai/litellm
readonly codex_record=platform/kubernetes/ai/codex-adapter
work="$(mktemp -d)"
chmod 0700 "$work"
created=()
cleanup() {
    rc=$?
    if (( rc != 0 )); then
        for record in "${created[@]}"; do
            bao kv metadata delete -mount=kv "$record" >/dev/null 2>&1 || true
        done
    fi
    rm -rf "$work"
    exit "$rc"
}
trap cleanup EXIT
for record in "$llmkube_record" "$memini_record" "$litellm_record" "$codex_record"; do
    ! bao kv get -mount=kv "$record" >/dev/null 2>&1 \
        || fail "$record already exists; rotate it through a separate reviewed transaction"
done

for name in embedding forgejo-memini codex-memini operator-memini litellm-master litellm-ui memini-virtual forgejo-virtual; do
    openssl rand -hex 32 >"$work/$name"
done
chmod 0600 "$work"/*
sha256sum "$work/forgejo-memini" | cut -d' ' -f1 >"$work/forgejo-hash"
sha256sum "$work/codex-memini" | cut -d' ' -f1 >"$work/codex-hash"
sha256sum "$work/operator-memini" | cut -d' ' -f1 >"$work/operator-hash"
rotated_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
rotation_due_at="$(python3 -c 'from datetime import datetime,timedelta,timezone; print((datetime.now(timezone.utc)+timedelta(days=90)).strftime("%Y-%m-%dT%H:%M:%SZ"))')"

jq -n --rawfile embedding_api_key "$work/embedding" --arg credentials_rotated_at "$rotated_at" \
    '{data:{$embedding_api_key,$credentials_rotated_at},options:{cas:0}}' \
    | bao write "kv/data/$llmkube_record" - >/dev/null
created+=("$llmkube_record")
jq -n --rawfile forgejo_api_key "$work/forgejo-memini" --rawfile forgejo_api_key_hash "$work/forgejo-hash" \
    --rawfile codex_api_key "$work/codex-memini" --rawfile codex_api_key_hash "$work/codex-hash" \
    --rawfile operator_api_key "$work/operator-memini" --rawfile operator_api_key_hash "$work/operator-hash" \
    --arg credentials_rotated_at "$rotated_at" \
    '{data:{$forgejo_api_key,$forgejo_api_key_hash,$codex_api_key,$codex_api_key_hash,$operator_api_key,$operator_api_key_hash,$credentials_rotated_at},options:{cas:0}}' \
    | bao write "kv/data/$memini_record" - >/dev/null
created+=("$memini_record")
jq -n --arg minimax_api_key "$MINIMAX_API_KEY" --rawfile breakglass_master_key "$work/litellm-master" \
    --arg ui_username litellm-admin --rawfile ui_password "$work/litellm-ui" \
    --rawfile memini_virtual_key "$work/memini-virtual" --rawfile forgejo_virtual_key "$work/forgejo-virtual" \
    --arg credentials_rotated_at "$rotated_at" --arg rotation_due_at "$rotation_due_at" \
    '{data:{$minimax_api_key,$breakglass_master_key,$ui_username,$ui_password,$memini_virtual_key,$forgejo_virtual_key,$credentials_rotated_at,$rotation_due_at},options:{cas:0}}' \
    | bao write "kv/data/$litellm_record" - >/dev/null
created+=("$litellm_record")
jq -n --rawfile auth_json "$CODEX_AUTH_JSON" --arg credentials_rotated_at "$rotated_at" \
    '{data:{$auth_json,$credentials_rotated_at},options:{cas:0}}' \
    | bao write "kv/data/$codex_record" - >/dev/null
created+=("$codex_record")

for record in "$llmkube_record" "$memini_record" "$litellm_record" "$codex_record"; do
    bao kv get -mount=kv -format=json "$record" | jq -e '.data.data | all(.[]; type == "string" and length > 0)' >/dev/null
 done
created=()
printf 'AI runtime records provisioned; retrieve consumer keys only through their exact OpenBao identities\n'
