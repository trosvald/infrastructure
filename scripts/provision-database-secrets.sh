#!/usr/bin/env bash
set -euo pipefail

fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
for command in bao curl jq mc mktemp openssl; do
    command -v "$command" >/dev/null 2>&1 || fail "$command is required"
done
[[ -n "${BAO_ADDR:-}" && -n "${BAO_TOKEN:-}" ]] || fail 'run through scripts/with-openbao-runtime.sh'
[[ "${BAO_SKIP_VERIFY:-false}" != true && "${BAO_TLS_SERVER_NAME:-}" != -* ]] \
    || fail 'OpenBao TLS verification bypasses are forbidden'

readonly postgres_record='platform/kubernetes/database/cloudnative-pg'
readonly dragonfly_record='platform/kubernetes/database/dragonfly'
readonly r2_record='platform/kubernetes/kopiur-system/r2'
readonly endpoint='https://s3.monosense.io:443'
readonly local_bucket='kubernetes-postgres'
work="$(mktemp -d)"
chmod 0700 "$work"
created_user=false
created_policy=false
created_bucket=false
created_postgres_record=false
created_dragonfly_record=false
cleanup() {
    rc=$?
    if (( rc != 0 )); then
        [[ "$created_dragonfly_record" == false ]] || bao kv metadata delete -mount=kv "$dragonfly_record" >/dev/null 2>&1 || true
        [[ "$created_postgres_record" == false ]] || bao kv metadata delete -mount=kv "$postgres_record" >/dev/null 2>&1 || true
        [[ "$created_user" == false ]] || mc --config-dir "$work/local-mc" admin user remove local "$(<"$work/local-access")" >/dev/null 2>&1 || true
        [[ "$created_policy" == false ]] || mc --config-dir "$work/local-mc" admin policy remove local kubernetes-postgres >/dev/null 2>&1 || true
        [[ "$created_bucket" == false ]] || mc --config-dir "$work/local-mc" rb --force "local/$local_bucket" >/dev/null 2>&1 || true
    fi
    rm -rf "$work"
    exit "$rc"
}
trap cleanup EXIT

for record in "$postgres_record" "$dragonfly_record"; do
    ! bao kv get -mount=kv "$record" >/dev/null 2>&1 \
        || fail "$record already exists; rotate it through a separate reviewed transaction"
done
bao kv get -mount=kv -format=json docker/c1/librefs >"$work/librefs.json"
bao kv get -mount=kv -format=json "$r2_record" >"$work/r2.json"
chmod 0600 "$work/librefs.json" "$work/r2.json"
jq -e '.data.data | keys | sort == ["root_password","root_user"] and all(.[]; type == "string" and length > 0)' "$work/librefs.json" >/dev/null
jq -e '.data.data | keys | sort == ["AWS_ACCESS_KEY_ID","AWS_SECRET_ACCESS_KEY","R2_BUCKET","R2_ENDPOINT"] and all(.[]; type == "string" and length > 0)' "$work/r2.json" >/dev/null

IFS= read -r -s -p 'Cloudflare API token with R2 bucket configuration edit: ' api_token; printf '\n'
[[ ${#api_token} -ge 32 ]] || fail 'Cloudflare API token is malformed'
r2_endpoint="$(jq -r '.data.data.R2_ENDPOINT' "$work/r2.json")"
r2_bucket="$(jq -r '.data.data.R2_BUCKET' "$work/r2.json")"
r2_access="$(jq -r '.data.data.AWS_ACCESS_KEY_ID' "$work/r2.json")"
r2_secret="$(jq -r '.data.data.AWS_SECRET_ACCESS_KEY' "$work/r2.json")"
account_id="${r2_endpoint%%.*}"
[[ "$account_id" =~ ^[a-f0-9]{32}$ ]] || fail 'R2 endpoint does not contain a valid Cloudflare account ID'
r2_api="https://api.cloudflare.com/client/v4/accounts/$account_id/r2/buckets/$r2_bucket"
printf 'header = "Authorization: Bearer %s"\nheader = "Content-Type: application/json"\n' "$api_token" >"$work/curl.conf"
chmod 0600 "$work/curl.conf"
unset api_token

openssl rand -hex 16 >"$work/local-access"
openssl rand -hex 32 >"$work/local-secret"
for name in keycloak-a keycloak-b litellm-a litellm-b forgejo-a forgejo-b dragonfly-keycloak-a dragonfly-keycloak-b dragonfly-litellm-a dragonfly-litellm-b; do
    openssl rand -hex 32 >"$work/$name"
done
chmod 0600 "$work"/local-access "$work"/local-secret "$work"/keycloak-* "$work"/litellm-* "$work"/forgejo-* "$work"/dragonfly-*

mkdir -m 0700 "$work/local-mc" "$work/r2-mc"
root_user="$(jq -r '.data.data.root_user' "$work/librefs.json")"
root_password="$(jq -r '.data.data.root_password' "$work/librefs.json")"
mc --config-dir "$work/local-mc" alias set local "$endpoint" "$root_user" "$root_password" >/dev/null
unset root_user root_password
mc --config-dir "$work/local-mc" ready local >/dev/null
! mc --config-dir "$work/local-mc" stat "local/$local_bucket" >/dev/null 2>&1 \
    || fail "$local_bucket already exists without its OpenBao record"
cat >"$work/policy.json" <<JSON
{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Action":["s3:GetBucketLocation"],"Resource":["arn:aws:s3:::$local_bucket"]},{"Effect":"Allow","Action":["s3:ListBucket"],"Resource":["arn:aws:s3:::$local_bucket"],"Condition":{"StringLike":{"s3:prefix":["primary","primary/*"]}}},{"Effect":"Allow","Action":["s3:GetObject","s3:PutObject","s3:DeleteObject"],"Resource":["arn:aws:s3:::$local_bucket/primary/*"]}]}
JSON
chmod 0600 "$work/policy.json"
mc --config-dir "$work/local-mc" mb "local/$local_bucket" >/dev/null
created_bucket=true
{ cat "$work/local-access"; cat "$work/local-secret"; } \
    | mc --config-dir "$work/local-mc" admin user add local >/dev/null
created_user=true
mc --config-dir "$work/local-mc" admin policy create local kubernetes-postgres "$work/policy.json" >/dev/null
created_policy=true
mc --config-dir "$work/local-mc" admin policy attach local kubernetes-postgres --user "$(<"$work/local-access")" >/dev/null

{
    printf '%s\n' "https://$r2_endpoint" "$r2_access" "$r2_secret"
} | jq -Rn '{version:"10",aliases:{r2:{url:input,accessKey:input,secretKey:input,api:"S3v4",path:"auto"}}}' >"$work/r2-mc/config.json"
chmod 0600 "$work/r2-mc/config.json"
unset r2_access r2_secret
! mc --config-dir "$work/r2-mc" ls "r2/$r2_bucket/postgres" >/dev/null 2>&1 \
    || fail 'R2 postgres prefix already exists without its OpenBao records'
printf 'postgres-lock-probe' >"$work/probe"
mc --config-dir "$work/r2-mc" cp "$work/probe" "r2/$r2_bucket/postgres/.lock-probe" >/dev/null
mc --config-dir "$work/r2-mc" rm "r2/$r2_bucket/postgres/.lock-probe" >/dev/null

curl --config "$work/curl.conf" --fail --silent --show-error "$r2_api/lock" >"$work/lock-before.json"
jq -e '.success == true and ((.result.rules // []) == [{id:"kopia-primary-30d",enabled:true,prefix:"primary/",condition:{type:"Age",maxAgeSeconds:2592000}}])' "$work/lock-before.json" >/dev/null \
    || fail 'R2 bucket lock rules differ from the reviewed Kopia baseline'
jq -n '{rules:[{id:"kopia-primary-30d",enabled:true,prefix:"primary/",condition:{type:"Age",maxAgeSeconds:2592000}},{id:"postgres-30d",enabled:true,prefix:"postgres/",condition:{type:"Age",maxAgeSeconds:2592000}}]}' >"$work/lock.json"
curl --config "$work/curl.conf" --fail --silent --show-error --request PUT --data-binary @"$work/lock.json" "$r2_api/lock" >"$work/lock-after.json"
jq -e '.success == true and .result.rules == [{id:"kopia-primary-30d",enabled:true,prefix:"primary/",condition:{type:"Age",maxAgeSeconds:2592000}},{id:"postgres-30d",enabled:true,prefix:"postgres/",condition:{type:"Age",maxAgeSeconds:2592000}}]' "$work/lock-after.json" >/dev/null

jq -n \
    --rawfile keycloak_a_password "$work/keycloak-a" --rawfile keycloak_b_password "$work/keycloak-b" \
    --rawfile litellm_a_password "$work/litellm-a" --rawfile litellm_b_password "$work/litellm-b" \
    --rawfile librefs_access_key_id "$work/local-access" --rawfile librefs_secret_access_key "$work/local-secret" \
    --arg r2_access_key_id "$(jq -r '.data.data.AWS_ACCESS_KEY_ID' "$work/r2.json")" \
    --arg r2_secret_access_key "$(jq -r '.data.data.AWS_SECRET_ACCESS_KEY' "$work/r2.json")" \
    --arg r2_endpoint "https://$r2_endpoint" --arg r2_bucket "$r2_bucket" \
    '{data:{$keycloak_a_password,$keycloak_b_password,$litellm_a_password,$litellm_b_password,$librefs_access_key_id,$librefs_secret_access_key,$r2_access_key_id,$r2_secret_access_key,$r2_endpoint,$r2_bucket},options:{cas:0}}' \
    | bao write "kv/data/$postgres_record" - >/dev/null
created_postgres_record=true
jq -n \
    --rawfile forgejo_a_password "$work/forgejo-a" --rawfile forgejo_b_password "$work/forgejo-b" \
    --rawfile keycloak_a_password "$work/dragonfly-keycloak-a" --rawfile keycloak_b_password "$work/dragonfly-keycloak-b" \
    --rawfile litellm_a_password "$work/dragonfly-litellm-a" --rawfile litellm_b_password "$work/dragonfly-litellm-b" \
    '{data:{$forgejo_a_password,$forgejo_b_password,$keycloak_a_password,$keycloak_b_password,$litellm_a_password,$litellm_b_password},options:{cas:0}}' \
    | bao write "kv/data/$dragonfly_record" - >/dev/null
created_dragonfly_record=true

bao kv get -mount=kv -format=json "$postgres_record" >"$work/postgres.json"
bao kv get -mount=kv -format=json "$dragonfly_record" >"$work/dragonfly.json"
jq -e '.data.data | keys | sort == ["keycloak_a_password","keycloak_b_password","librefs_access_key_id","librefs_secret_access_key","litellm_a_password","litellm_b_password","r2_access_key_id","r2_bucket","r2_endpoint","r2_secret_access_key"] and all(.[]; type == "string" and length > 0)' "$work/postgres.json" >/dev/null
jq -e '.data.data | keys | sort == ["forgejo_a_password","forgejo_b_password","keycloak_a_password","keycloak_b_password","litellm_a_password","litellm_b_password"] and all(.[]; type == "string" and length >= 64)' "$work/dragonfly.json" >/dev/null
created_dragonfly_record=false
created_postgres_record=false
created_user=false
created_policy=false
created_bucket=false
printf 'Database credentials, scoped libreFS backup identity, and immutable R2 mirror prefix created\n'
