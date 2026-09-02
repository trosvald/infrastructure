#!/usr/bin/env bash
set -euo pipefail

fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
[[ $# -eq 1 && "$1" =~ ^(inject|cleanup)$ ]] || fail 'usage: bootstrap-keycloak.sh <inject|cleanup>'
for command in bao curl jq kubectl mktemp; do
    command -v "$command" >/dev/null 2>&1 || fail "$command is required"
done
[[ -n "${BAO_TOKEN:-}" ]] || fail 'run through scripts/with-openbao-runtime.sh'
repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
! grep -R -q 'bootstrapAdmin\|keycloak-bootstrap-admin' \
    "$repo_dir/kubernetes/apps/security/keycloak/cluster" \
    || fail 'final Git manifests must not retain the bootstrap Secret or env reference'

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
chmod 0700 "$work"
readonly bootstrap_record=platform/kubernetes/security/keycloak-bootstrap
readonly tofu_record=platform/kubernetes/security/keycloak-tofu
readonly admin_base=https://auth-admin.internal
bao kv get -mount=kv -field=bootstrap_admin_username "$bootstrap_record" >"$work/username"
bao kv get -mount=kv -field=bootstrap_admin_password "$bootstrap_record" >"$work/password"
bao read -field=certificate pki-kubernetes/cert/ca >"$work/ca.pem"
bao kv get -mount=kv -field=tofu_admin_client_secret "$tofu_record" >"$work/tofu-client-secret"
chmod 0600 "$work"/*

admin_login() {
    curl --fail --silent --show-error --cacert "$work/ca.pem" \
        --data-urlencode client_id=admin-cli \
        --data-urlencode grant_type=password \
        --data-urlencode "username@${work}/username" \
        --data-urlencode "password@${work}/password" \
        "$admin_base/realms/master/protocol/openid-connect/token" >"$work/token.json"
    jq -er '.access_token' "$work/token.json" >"$work/access-token"
    printf 'header = "Authorization: Bearer %s"\n' "$(<"$work/access-token")" >"$work/admin-curl.conf"
    chmod 0600 "$work/access-token" "$work/admin-curl.conf"
}

if [[ "$1" == inject ]]; then
    kubectl -n security patch kustomization keycloak --type=merge -p '{"spec":{"suspend":true}}'
    kubectl -n security create secret generic keycloak-bootstrap-admin \
        --from-file=username="$work/username" --from-file=password="$work/password" \
        --dry-run=client -o yaml | kubectl apply -f -
    if ! kubectl -n security get keycloak keycloak \
        -o jsonpath='{.spec.bootstrapAdmin.user.secret}' 2>/dev/null | grep -qx keycloak-bootstrap-admin; then
        kubectl -n security patch keycloak keycloak --type=merge \
            -p '{"spec":{"bootstrapAdmin":{"user":{"secret":"keycloak-bootstrap-admin"}}}}'
    fi
    kubectl -n security wait --for=condition=Ready keycloak/keycloak --timeout=15m
    admin_login

    jq -n --rawfile secret "$work/tofu-client-secret" '{
        clientId:"keycloak-tofu", name:"Keycloak OpenTofu", protocol:"openid-connect",
        enabled:true, publicClient:false, bearerOnly:false, serviceAccountsEnabled:true,
        standardFlowEnabled:false, implicitFlowEnabled:false, directAccessGrantsEnabled:false,
        secret:$secret
    }' >"$work/client.json"
    clients_url="$admin_base/admin/realms/master/clients"
    existing="$(curl --config "$work/admin-curl.conf" --fail --silent --show-error \
        --cacert "$work/ca.pem" "$clients_url?clientId=keycloak-tofu")"
    if [[ "$(jq 'length' <<<"$existing")" == 0 ]]; then
        curl --config "$work/admin-curl.conf" --fail --silent --show-error \
            --cacert "$work/ca.pem" -H 'Content-Type: application/json' \
            --request POST --data-binary @"$work/client.json" "$clients_url"
    elif [[ "$(jq 'length' <<<"$existing")" != 1 ]]; then
        fail 'Keycloak OpenTofu client lookup is ambiguous'
    else
        client_id="$(jq -er '.[0].id' <<<"$existing")"
        curl --config "$work/admin-curl.conf" --fail --silent --show-error \
            --cacert "$work/ca.pem" -H 'Content-Type: application/json' \
            --request PUT --data-binary @"$work/client.json" "$clients_url/$client_id"
    fi
    client_id="$(curl --config "$work/admin-curl.conf" --fail --silent --show-error \
        --cacert "$work/ca.pem" "$clients_url?clientId=keycloak-tofu" | jq -er 'if length == 1 then .[0].id else error("client") end')"
    service_user_id="$(curl --config "$work/admin-curl.conf" --fail --silent --show-error \
        --cacert "$work/ca.pem" "$clients_url/$client_id/service-account-user" | jq -er '.id')"
    curl --config "$work/admin-curl.conf" --fail --silent --show-error --cacert "$work/ca.pem" \
        "$admin_base/admin/realms/master/roles/admin" >"$work/admin-role.json"
    jq '[.]' "$work/admin-role.json" >"$work/admin-role-array.json"
    curl --config "$work/admin-curl.conf" --fail --silent --show-error \
        --cacert "$work/ca.pem" -H 'Content-Type: application/json' \
        --request POST --data-binary @"$work/admin-role-array.json" \
        "$admin_base/admin/realms/master/users/$service_user_id/role-mappings/realm"
    printf 'One-time Keycloak administrator injected and dedicated OpenTofu client created; run the protected workflow, then cleanup\n'
else
    admin_login
    curl --fail --silent --show-error --cacert "$work/ca.pem" \
        --data-urlencode client_id=keycloak-tofu \
        --data-urlencode grant_type=client_credentials \
        --data-urlencode "client_secret@${work}/tofu-client-secret" \
        "$admin_base/realms/master/protocol/openid-connect/token" \
        | jq -e '.access_token | type == "string" and length > 100' >/dev/null \
        || fail 'dedicated OpenTofu client is not usable'
    bootstrap_username="$(<"$work/username")"
    users="$(curl --config "$work/admin-curl.conf" --fail --silent --show-error \
        --cacert "$work/ca.pem" \
        "$admin_base/admin/realms/master/users?username=$bootstrap_username&exact=true")"
    [[ "$(jq 'length' <<<"$users")" == 1 ]] || fail 'bootstrap administrator lookup is not exact'
    bootstrap_id="$(jq -er '.[0].id' <<<"$users")"
    curl --config "$work/admin-curl.conf" --fail --silent --show-error \
        --cacert "$work/ca.pem" --request DELETE \
        "$admin_base/admin/realms/master/users/$bootstrap_id"
    if kubectl -n security get keycloak keycloak -o jsonpath='{.spec.bootstrapAdmin}' 2>/dev/null | grep -q .; then
        kubectl -n security patch keycloak keycloak --type=json \
            -p '[{"op":"remove","path":"/spec/bootstrapAdmin"}]'
    fi
    kubectl -n security delete secret keycloak-bootstrap-admin --ignore-not-found
    kubectl -n security patch kustomization keycloak --type=merge -p '{"spec":{"suspend":false}}'
    kubectl -n security wait --for=condition=Ready keycloak/keycloak --timeout=15m
    ! kubectl -n security get secret keycloak-bootstrap-admin >/dev/null 2>&1 \
        || fail 'bootstrap Secret still exists'
    test -z "$(kubectl -n security get keycloak keycloak -o jsonpath='{.spec.bootstrapAdmin}' 2>/dev/null)" \
        || fail 'bootstrapAdmin still exists in the Keycloak CR'
    bao kv metadata delete -mount=kv "$bootstrap_record" >/dev/null
    printf 'Bootstrap account, OpenBao record, Kubernetes Secret, and CR reference removed; Flux resumed\n'
fi
