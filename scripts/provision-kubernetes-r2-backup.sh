#!/usr/bin/env bash
set -euo pipefail

fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
for command in bao curl jq mc mktemp; do
    command -v "$command" >/dev/null 2>&1 || fail "$command is required"
done
[[ -n "${BAO_ADDR:-}" && -n "${BAO_TOKEN:-}" ]] || fail 'run through scripts/with-openbao-runtime.sh'
readonly record='platform/kubernetes/kopiur-system/r2'
if bao kv get -mount=kv "$record" >/dev/null 2>&1; then
    fail "$record already exists; rotate it through a separate reviewed transaction"
fi

IFS= read -r -p 'Cloudflare account ID: ' account_id
IFS= read -r -p 'Private R2 bucket name: ' bucket
IFS= read -r -s -p 'Dedicated R2 S3 access key ID: ' access_key; printf '\n'
IFS= read -r -s -p 'Dedicated R2 S3 secret access key: ' secret_key; printf '\n'
IFS= read -r -s -p 'Cloudflare API token with R2 bucket configuration edit: ' api_token; printf '\n'
[[ "$account_id" =~ ^[a-f0-9]{32}$ ]] || fail 'Cloudflare account ID must be 32 lowercase hexadecimal characters'
[[ "$bucket" =~ ^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$ ]] || fail 'R2 bucket name is malformed'
[[ ${#access_key} -ge 20 && ${#secret_key} -ge 32 && ${#api_token} -ge 32 ]] || fail 'R2 credentials are malformed'
endpoint="${account_id}.r2.cloudflarestorage.com"
api="https://api.cloudflare.com/client/v4/accounts/$account_id/r2/buckets/$bucket"
work="$(mktemp -d)"
chmod 0700 "$work"
created_record=false
cleanup() {
    rc=$?
    if (( rc != 0 )) && [[ "$created_record" == true ]]; then
        bao kv metadata delete -mount=kv "$record" >/dev/null 2>&1 || true
    fi
    unset access_key secret_key api_token
    rm -rf "$work"
    exit "$rc"
}
trap cleanup EXIT
printf '%s' "$access_key" >"$work/access-key"
printf '%s' "$secret_key" >"$work/secret-key"
printf '%s' "$bucket" >"$work/bucket"
printf '%s' "$endpoint" >"$work/endpoint"
printf 'header = "Authorization: Bearer %s"\nheader = "Content-Type: application/json"\n' "$api_token" >"$work/curl.conf"
chmod 0600 "$work/access-key" "$work/secret-key" "$work/bucket" "$work/endpoint" "$work/curl.conf"
mkdir -m 0700 "$work/mc"
{
    printf '%s\n' "https://$endpoint" "$access_key" "$secret_key"
} | jq -Rn '{version:"10",aliases:{r2:{url:input,accessKey:input,secretKey:input,api:"S3v4",path:"auto"}}}' >"$work/mc/config.json"
chmod 0600 "$work/mc/config.json"
unset access_key secret_key api_token
mc --config-dir "$work/mc" stat "r2/$bucket" >/dev/null
! mc --config-dir "$work/mc" ls r2 >/dev/null 2>&1 || fail 'R2 S3 token can enumerate buckets and is not bucket-scoped'
printf 'r2-lock-probe' >"$work/probe"
mc --config-dir "$work/mc" cp "$work/probe" "r2/$bucket/primary/.lock-probe" >/dev/null
mc --config-dir "$work/mc" rm "r2/$bucket/primary/.lock-probe" >/dev/null

curl --config "$work/curl.conf" --fail --silent --show-error "$api" >"$work/bucket.json"
jq -e '.success == true and .result.name == $bucket' --arg bucket "$bucket" "$work/bucket.json" >/dev/null
curl --config "$work/curl.conf" --fail --silent --show-error "$api/lifecycle" >"$work/lifecycle.json"
jq -e '.success == true and ((.result.rules // []) | length == 0)' "$work/lifecycle.json" >/dev/null \
    || fail 'R2 bucket has lifecycle rules; remove them before locking the Kopia prefix'
curl --config "$work/curl.conf" --fail --silent --show-error "$api/lock" >"$work/lock-before.json"
jq -e '.success == true and (((.result.rules // []) | length == 0) or ((.result.rules // []) == [{id:"kopia-primary-30d",enabled:true,prefix:"primary/",condition:{type:"Age",maxAgeSeconds:2592000}}]))' "$work/lock-before.json" >/dev/null \
    || fail 'R2 bucket has unreviewed lock rules; refusing to replace them'

jq -n --rawfile access "$work/access-key" --rawfile secret "$work/secret-key" \
    --rawfile bucket "$work/bucket" --rawfile endpoint "$work/endpoint" \
    '{data:{AWS_ACCESS_KEY_ID:$access,AWS_SECRET_ACCESS_KEY:$secret,R2_BUCKET:$bucket,R2_ENDPOINT:$endpoint},options:{cas:0}}' \
    | bao write "kv/data/$record" - >/dev/null
created_record=true
jq -n '{rules:[{id:"kopia-primary-30d",enabled:true,prefix:"primary/",condition:{type:"Age",maxAgeSeconds:2592000}}]}' >"$work/lock.json"
curl --config "$work/curl.conf" --fail --silent --show-error --request PUT \
    --data-binary @"$work/lock.json" "$api/lock" >"$work/lock-after.json"
jq -e '.success == true and .result.rules == [{id:"kopia-primary-30d",enabled:true,prefix:"primary/",condition:{type:"Age",maxAgeSeconds:2592000}}]' "$work/lock-after.json" >/dev/null
bao kv get -mount=kv -format=json "$record" >"$work/record.json"
jq -e '.data.data | keys | sort == ["AWS_ACCESS_KEY_ID","AWS_SECRET_ACCESS_KEY","R2_BUCKET","R2_ENDPOINT"] and all(.[]; type == "string" and length > 0)' "$work/record.json" >/dev/null
created_record=false
printf 'Private R2 Kopia destination verified with no lifecycle deletion and a 30-day primary-prefix lock\n'
