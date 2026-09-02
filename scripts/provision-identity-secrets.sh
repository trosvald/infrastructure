#!/usr/bin/env bash
set -euo pipefail

fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
for command in bao curl jq mc mktemp openssl tofu; do
    command -v "$command" >/dev/null 2>&1 || fail "$command is required"
done
[[ -n "${BAO_ADDR:-}" && -n "${BAO_TOKEN:-}" ]] || fail 'run through scripts/with-openbao-runtime.sh'
[[ "${BAO_SKIP_VERIFY:-false}" != true ]] || fail 'OpenBao TLS verification bypasses are forbidden'

readonly keycloak_record='platform/kubernetes/security/keycloak'
readonly bootstrap_record='platform/kubernetes/security/keycloak-bootstrap'
readonly tofu_record='platform/kubernetes/security/keycloak-tofu'
readonly r2_record='platform/kubernetes/kopiur-system/r2'
readonly bucket='kubernetes-keycloak-tofu'
readonly endpoint='https://s3.monosense.io:443'
work="$(mktemp -d)"
chmod 0700 "$work"
created_bucket=false
created_user=false
created_policy=false
created_keycloak=false
created_tofu=false
created_bootstrap=false
cleanup() {
    rc=$?
    if (( rc != 0 )); then
        [[ "$created_tofu" == false ]] || bao kv metadata delete -mount=kv "$tofu_record" >/dev/null 2>&1 || true
        [[ "$created_bootstrap" == false ]] || bao kv metadata delete -mount=kv "$bootstrap_record" >/dev/null 2>&1 || true
        [[ "$created_keycloak" == false ]] || bao kv metadata delete -mount=kv "$keycloak_record" >/dev/null 2>&1 || true
        [[ "$created_user" == false ]] || mc --config-dir "$work/mc" admin user remove local "$(<"$work/access")" >/dev/null 2>&1 || true
        [[ "$created_policy" == false ]] || mc --config-dir "$work/mc" admin policy remove local keycloak-tofu >/dev/null 2>&1 || true
        [[ "$created_bucket" == false ]] || mc --config-dir "$work/mc" rb --force "local/$bucket" >/dev/null 2>&1 || true
    fi
    rm -rf "$work"
    exit "$rc"
}
trap cleanup EXIT

for record in "$keycloak_record" "$bootstrap_record" "$tofu_record"; do
    ! bao kv get -mount=kv "$record" >/dev/null 2>&1 \
        || fail "$record already exists; rotate it through a separate reviewed transaction"
done
read -r -p 'Human administrator username: ' human_username
read -r -p 'Human administrator email: ' human_email
[[ "$human_username" =~ ^[a-z][a-z0-9._-]{2,31}$ ]] || fail 'human administrator username is malformed'
[[ "$human_email" =~ ^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$ ]] || fail 'human administrator email is malformed'
read -r -s -p 'Repository-scoped ephemeral Forgejo runner registration token: ' runner_token; printf '\n'
[[ ${#runner_token} -ge 24 ]] || fail 'Forgejo runner registration token is malformed'
read -r -s -p 'Cloudflare API token with R2 bucket lock edit: ' api_token; printf '\n'
[[ ${#api_token} -ge 32 ]] || fail 'Cloudflare API token is malformed'

bao kv get -mount=kv -format=json docker/c1/librefs >"$work/librefs.json"
bao kv get -mount=kv -format=json "$r2_record" >"$work/r2.json"
jq -e '.data.data | keys | sort == ["root_password","root_user"]' "$work/librefs.json" >/dev/null
jq -e '.data.data | keys | sort == ["AWS_ACCESS_KEY_ID","AWS_SECRET_ACCESS_KEY","R2_BUCKET","R2_ENDPOINT"]' "$work/r2.json" >/dev/null
openssl rand -hex 16 >"$work/access"
openssl rand -hex 32 >"$work/secret"
for name in bootstrap-password tofu-admin-client human-password state-passphrase ceph-client alertmanager-client victorialogs-client memini-client grafana-client ceph-cookie alertmanager-cookie victorialogs-cookie memini-cookie; do
    openssl rand -base64 48 | tr -d '\n' >"$work/$name"
done
printf '%s' "$runner_token" >"$work/runner-token"
unset runner_token
bao read -field=certificate pki-kubernetes/cert/ca >"$work/kubernetes-ca.pem"
chmod 0600 "$work"/*

mkdir -m 0700 "$work/mc" "$work/r2-mc" "$work/provider-mirror"
mc --config-dir "$work/mc" alias set local "$endpoint" \
    "$(jq -r '.data.data.root_user' "$work/librefs.json")" \
    "$(jq -r '.data.data.root_password' "$work/librefs.json")" >/dev/null
! mc --config-dir "$work/mc" stat "local/$bucket" >/dev/null 2>&1 \
    || fail "$bucket already exists without its OpenBao record"
cat >"$work/policy.json" <<JSON
{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Action":["s3:GetBucketLocation"],"Resource":["arn:aws:s3:::$bucket"]},{"Effect":"Allow","Action":["s3:ListBucket"],"Resource":["arn:aws:s3:::$bucket"],"Condition":{"StringLike":{"s3:prefix":["state","state/*","providers","providers/*"]}}},{"Effect":"Allow","Action":["s3:GetObject","s3:PutObject","s3:DeleteObject"],"Resource":["arn:aws:s3:::$bucket/state/*"]},{"Effect":"Allow","Action":["s3:GetObject"],"Resource":["arn:aws:s3:::$bucket/providers/*"]}]}
JSON
mc --config-dir "$work/mc" mb "local/$bucket" >/dev/null
created_bucket=true
mc --config-dir "$work/mc" version enable "local/$bucket" >/dev/null
{ cat "$work/access"; cat "$work/secret"; } | mc --config-dir "$work/mc" admin user add local >/dev/null
created_user=true
mc --config-dir "$work/mc" admin policy create local keycloak-tofu "$work/policy.json" >/dev/null
created_policy=true
mc --config-dir "$work/mc" admin policy attach local keycloak-tofu --user "$(<"$work/access")" >/dev/null
(
    cd kubernetes/apps/security/keycloak-tofu/tofu
    tofu providers mirror "$work/provider-mirror"
)
mc --config-dir "$work/mc" cp --recursive "$work/provider-mirror/" "local/$bucket/providers/" >/dev/null

r2_endpoint="$(jq -r '.data.data.R2_ENDPOINT' "$work/r2.json")"
r2_bucket="$(jq -r '.data.data.R2_BUCKET' "$work/r2.json")"
account_id="${r2_endpoint%%.*}"
[[ "$account_id" =~ ^[a-f0-9]{32}$ ]] || fail 'R2 endpoint does not contain a valid account ID'
printf 'header = "Authorization: Bearer %s"\nheader = "Content-Type: application/json"\n' "$api_token" >"$work/curl.conf"
unset api_token
r2_api="https://api.cloudflare.com/client/v4/accounts/$account_id/r2/buckets/$r2_bucket"
curl --config "$work/curl.conf" --fail --silent --show-error "$r2_api/lock" >"$work/lock-before.json"
jq -e '.success == true and (.result.rules | map(.id) | sort) == ["kopia-primary-30d","postgres-30d"]' "$work/lock-before.json" >/dev/null \
    || fail 'R2 lock rules differ from the reviewed database/storage baseline'
jq '.result.rules + [{id:"keycloak-tofu-30d",enabled:true,prefix:"keycloak-tofu/",condition:{type:"Age",maxAgeSeconds:2592000}}] | {rules:.}' "$work/lock-before.json" >"$work/lock.json"
curl --config "$work/curl.conf" --fail --silent --show-error --request PUT --data-binary @"$work/lock.json" "$r2_api/lock" | jq -e '.success == true' >/dev/null

jq -n \
    --arg ceph_client_id ceph --rawfile ceph_client_secret "$work/ceph-client" --rawfile ceph_cookie_secret "$work/ceph-cookie" \
    --arg alertmanager_client_id alertmanager --rawfile alertmanager_client_secret "$work/alertmanager-client" --rawfile alertmanager_cookie_secret "$work/alertmanager-cookie" \
    --arg vlogs_client_id victorialogs --rawfile vlogs_client_secret "$work/victorialogs-client" --rawfile vlogs_cookie_secret "$work/victorialogs-cookie" \
    --arg memini_client_id memini --rawfile memini_client_secret "$work/memini-client" --rawfile memini_cookie_secret "$work/memini-cookie" \
    '{data:{$ceph_client_id,$ceph_client_secret,$ceph_cookie_secret,$alertmanager_client_id,$alertmanager_client_secret,$alertmanager_cookie_secret,$vlogs_client_id,$vlogs_client_secret,$vlogs_cookie_secret,$memini_client_id,$memini_client_secret,$memini_cookie_secret},options:{cas:0}}' \
    | bao write "kv/data/$keycloak_record" - >/dev/null
created_keycloak=true
jq -n \
    --arg bootstrap_admin_username bootstrap-admin \
    --rawfile bootstrap_admin_password "$work/bootstrap-password" \
    '{data:{$bootstrap_admin_username,$bootstrap_admin_password},options:{cas:0}}' \
    | bao write "kv/data/$bootstrap_record" - >/dev/null
created_bootstrap=true
jq -n \
    --rawfile tofu_admin_client_secret "$work/tofu-admin-client" \
    --arg human_admin_username "$human_username" --arg human_admin_email "$human_email" --rawfile human_admin_initial_password "$work/human-password" \
    --rawfile state_encryption_passphrase "$work/state-passphrase" --rawfile keycloak_ca_certificate "$work/kubernetes-ca.pem" \
    --rawfile ceph_client_secret "$work/ceph-client" --rawfile alertmanager_client_secret "$work/alertmanager-client" \
    --rawfile victorialogs_client_secret "$work/victorialogs-client" --rawfile memini_client_secret "$work/memini-client" \
    --rawfile grafana_client_secret "$work/grafana-client" --rawfile runner_registration_token "$work/runner-token" \
    --rawfile librefs_access_key_id "$work/access" --rawfile librefs_secret_access_key "$work/secret" \
    --arg r2_access_key_id "$(jq -r '.data.data.AWS_ACCESS_KEY_ID' "$work/r2.json")" \
    --arg r2_secret_access_key "$(jq -r '.data.data.AWS_SECRET_ACCESS_KEY' "$work/r2.json")" \
    --arg r2_endpoint "https://$r2_endpoint" --arg r2_bucket "$r2_bucket" --arg credentials_rotated_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{data:{$tofu_admin_client_secret,$human_admin_username,$human_admin_email,$human_admin_initial_password,$state_encryption_passphrase,$keycloak_ca_certificate,$ceph_client_secret,$alertmanager_client_secret,$victorialogs_client_secret,$memini_client_secret,$grafana_client_secret,$runner_registration_token,$librefs_access_key_id,$librefs_secret_access_key,$r2_access_key_id,$r2_secret_access_key,$r2_endpoint,$r2_bucket,$credentials_rotated_at},options:{cas:0}}' \
    | bao write "kv/data/$tofu_record" - >/dev/null
created_tofu=true
created_keycloak=false
created_tofu=false
created_bootstrap=false
created_bucket=false
created_user=false
created_policy=false
printf 'Identity clients, ephemeral runner, encrypted versioned state, provider mirror, and immutable R2 prefix created\n'
