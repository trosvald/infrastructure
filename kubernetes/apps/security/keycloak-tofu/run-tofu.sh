#!/bin/sh
set -eu
umask 077

mode="${1:-}"
case "$mode" in
    plan|apply|drift) ;;
    *) printf 'usage: %s <plan|apply|drift>\n' "$0" >&2; exit 2 ;;
esac

secret_dir=/run/secrets
for name in state_encryption_passphrase tofu_admin_client_secret keycloak_ca_certificate \
    human_admin_username human_admin_email human_admin_initial_password \
    ceph_client_secret alertmanager_client_secret victorialogs_client_secret memini_client_secret \
    grafana_client_secret librefs_access_key_id librefs_secret_access_key; do
    test -s "$secret_dir/$name" || { printf 'required secret %s is absent\n' "$name" >&2; exit 1; }
done

export AWS_ACCESS_KEY_ID="$(cat "$secret_dir/librefs_access_key_id")"
export AWS_SECRET_ACCESS_KEY="$(cat "$secret_dir/librefs_secret_access_key")"
export AWS_REGION=us-east-1
export TF_VAR_state_encryption_passphrase="$(cat "$secret_dir/state_encryption_passphrase")"
export TF_VAR_tofu_admin_client_secret="$(cat "$secret_dir/tofu_admin_client_secret")"
export TF_VAR_keycloak_ca_certificate="$(cat "$secret_dir/keycloak_ca_certificate")"
export TF_VAR_human_admin_username="$(cat "$secret_dir/human_admin_username")"
export TF_VAR_human_admin_email="$(cat "$secret_dir/human_admin_email")"
export TF_VAR_human_admin_initial_password="$(cat "$secret_dir/human_admin_initial_password")"
export TF_VAR_ceph_client_secret="$(cat "$secret_dir/ceph_client_secret")"
export TF_VAR_alertmanager_client_secret="$(cat "$secret_dir/alertmanager_client_secret")"
export TF_VAR_victorialogs_client_secret="$(cat "$secret_dir/victorialogs_client_secret")"
export TF_VAR_memini_client_secret="$(cat "$secret_dir/memini_client_secret")"
export TF_VAR_grafana_client_secret="$(cat "$secret_dir/grafana_client_secret")"

work="$(mktemp -d /workspace/keycloak-tofu.XXXXXX)"
trap 'rm -rf "$work"' EXIT INT TERM
repository="$work/repository"
git -c credential.helper= clone --no-tags --filter=blob:none https://git.monosense.io/trosvald/infrastructure.git "$repository" >/dev/null 2>&1
git -C "$repository" checkout --detach "${FORGEJO_SHA:?FORGEJO_SHA is required}" >/dev/null 2>&1
cd "$repository/kubernetes/apps/security/keycloak-tofu/tofu"
tofu init -input=false -lockfile=readonly >/dev/null

plan="$work/keycloak.tfplan"
log="$work/plan.log"
set +e
tofu plan -input=false -lock-timeout=10m -detailed-exitcode -out="$plan" >"$log" 2>&1
plan_rc=$?
set -e
case "$plan_rc" in
    0) printf 'Keycloak OpenTofu plan: no changes\n' ;;
    2)
        grep -E '^  # [^ ]+ (will|must)|^Plan:' "$log" || true
        ;;
    *)
        printf 'Keycloak OpenTofu plan failed; sensitive output withheld\n' >&2
        exit 1
        ;;
esac

case "$mode" in
    plan)
        exit 0
        ;;
    drift)
        test "$plan_rc" -eq 0 || { printf 'Keycloak configuration drift detected\n' >&2; exit 1; }
        ;;
    apply)
        test "${FORGEJO_REF_NAME:-}" = main || { printf 'apply requires protected main\n' >&2; exit 1; }
        test "$plan_rc" -eq 2 || exit 0
        tofu apply -input=false -auto-approve "$plan" >/dev/null
        tofu plan -input=false -lock-timeout=10m -detailed-exitcode >"$log" 2>&1 || rc=$?
        test "${rc:-0}" -eq 0 || { printf 'post-apply plan is not clean\n' >&2; exit 1; }
        printf 'Keycloak reviewed saved plan applied; post-apply plan is clean\n'
        ;;
esac
