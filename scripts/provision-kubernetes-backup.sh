#!/usr/bin/env bash
set -euo pipefail

fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
for command in bao jq mc openssl mktemp; do
    command -v "$command" >/dev/null 2>&1 || fail "$command is required"
done
[[ -n "${BAO_ADDR:-}" && -n "${BAO_TOKEN:-}" ]] || fail 'run through scripts/with-openbao-runtime.sh'
[[ "${BAO_SKIP_VERIFY:-false}" != true && "${BAO_TLS_SERVER_NAME:-}" != -* ]] \
    || fail 'OpenBao TLS verification bypasses are forbidden'

readonly endpoint='https://s3.monosense.io:443'
readonly bucket='kubernetes-backups'
readonly prefix='primary'
readonly record='platform/kubernetes/kopiur-system/kopiur'
work="$(mktemp -d)"
chmod 0700 "$work"
created_user=false
created_policy=false
created_bucket=false
created_record=false
cleanup() {
    rc=$?
    if (( rc != 0 )); then
        [[ "$created_record" == false ]] || bao kv metadata delete -mount=kv "$record" >/dev/null 2>&1 || true
        [[ "$created_user" == false ]] || mc --config-dir "$work/mc" admin user remove local "$(<"$work/access-key")" >/dev/null 2>&1 || true
        [[ "$created_policy" == false ]] || mc --config-dir "$work/mc" admin policy remove local kubernetes-backups >/dev/null 2>&1 || true
        [[ "$created_bucket" == false ]] || mc --config-dir "$work/mc" rb --force "local/$bucket" >/dev/null 2>&1 || true
    fi
    rm -rf "$work"
    exit "$rc"
}
trap cleanup EXIT

if bao kv get -mount=kv "$record" >/dev/null 2>&1; then
    fail "$record already exists; rotate it through a separate reviewed transaction"
fi
bao kv get -mount=kv -format=json docker/c1/librefs >"$work/root.json"
chmod 0600 "$work/root.json"
jq -e '.data.data | keys | sort == ["root_password","root_user"] and all(.[]; type == "string" and length > 0)' "$work/root.json" >/dev/null 

openssl rand -hex 16 >"$work/access-key"
openssl rand -hex 32 >"$work/secret-key"
openssl rand -hex 32 >"$work/kopia-password"
chmod 0600 "$work"/*-key "$work/kopia-password"
mkdir -m 0700 "$work/mc"
root_user="$(jq -r '.data.data.root_user' "$work/root.json")"
root_password="$(jq -r '.data.data.root_password' "$work/root.json")"
mc --config-dir "$work/mc" alias set local "$endpoint" "$root_user" "$root_password" >/dev/null
unset root_user root_password
mc --config-dir "$work/mc" ready local >/dev/null
! mc --config-dir "$work/mc" admin user info local "$(<"$work/access-key")" >/dev/null 2>&1 \
    || fail 'generated libreFS access key unexpectedly exists'
! mc --config-dir "$work/mc" admin policy info local kubernetes-backups >/dev/null 2>&1 \
    || fail 'libreFS kubernetes-backups policy already exists'
! mc --config-dir "$work/mc" stat "local/$bucket" >/dev/null 2>&1 \
    || fail 'libreFS kubernetes-backups bucket already exists without its OpenBao record'

cat >"$work/policy.json" <<JSON
{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Action":["s3:GetBucketLocation"],"Resource":["arn:aws:s3:::$bucket"]},{"Effect":"Allow","Action":["s3:ListBucket"],"Resource":["arn:aws:s3:::$bucket"],"Condition":{"StringLike":{"s3:prefix":["$prefix","$prefix/*"]}}},{"Effect":"Allow","Action":["s3:GetObject","s3:PutObject","s3:DeleteObject"],"Resource":["arn:aws:s3:::$bucket/$prefix/*"]}]}
JSON
chmod 0600 "$work/policy.json"
mc --config-dir "$work/mc" mb "local/$bucket" >/dev/null
created_bucket=true
{
    cat "$work/access-key"
    cat "$work/secret-key"
} | mc --config-dir "$work/mc" admin user add local >/dev/null
created_user=true
mc --config-dir "$work/mc" admin policy create local kubernetes-backups "$work/policy.json" >/dev/null
created_policy=true
mc --config-dir "$work/mc" admin policy attach local kubernetes-backups --user "$(<"$work/access-key")" >/dev/null
mc --config-dir "$work/mc" stat "local/$bucket" >/dev/null

bao kv put -mount=kv "$record" \
    AWS_ACCESS_KEY_ID="$(<"$work/access-key")" \
    AWS_SECRET_ACCESS_KEY="$(<"$work/secret-key")" \
    KOPIA_PASSWORD="$(<"$work/kopia-password")" >/dev/null
created_record=true
bao kv get -mount=kv -format=json "$record" >"$work/record.json"
jq -e '.data.data | keys | sort == ["AWS_ACCESS_KEY_ID","AWS_SECRET_ACCESS_KEY","KOPIA_PASSWORD"] and all(.[]; type == "string" and length >= 32)' "$work/record.json" >/dev/null
created_record=false
created_user=false
created_policy=false
created_bucket=false
printf 'Scoped TLS libreFS Kubernetes backup identity and bucket created\n'
