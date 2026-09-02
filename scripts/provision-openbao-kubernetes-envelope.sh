#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_dir"
[[ $# -eq 0 ]] || { echo "provision-openbao-kubernetes-envelope accepts no arguments" >&2; exit 2; }
for tool in bao jq; do
    command -v "$tool" >/dev/null 2>&1 || { echo "missing locked executable: $tool" >&2; exit 1; }
done
[[ -z "${BAO_SKIP_VERIFY:-}${VAULT_SKIP_VERIFY:-}${BAO_TLS_SERVER_NAME:-}${VAULT_TLS_SERVER_NAME:-}" ]] || {
    echo "OpenBao TLS verification bypasses and server-name overrides are prohibited" >&2
    exit 1
}
export BAO_ADDR="${BAO_ADDR:-https://vault.monosense.io:8200}"
[[ "$BAO_ADDR" == "https://vault.monosense.io:8200" ]] || { echo "unexpected BAO_ADDR" >&2; exit 1; }
policy="$repo_dir/docker/c0/openbao/policies/monosense-infra.hcl"
[[ -f "$policy" && ! -L "$policy" ]] || { echo "monosense-infra policy is absent or unsafe" >&2; exit 1; }
umask 077
admin_token=""
cleanup() {
    status=$?
    if [[ -n "$admin_token" ]]; then BAO_TOKEN="$admin_token" bao token revoke -self >/dev/null 2>&1 || true; fi
    unset admin_token BAO_TOKEN
    exit "$status"
}
trap cleanup EXIT
trap 'exit 130' HUP INT TERM
[[ -r /dev/tty && -w /dev/tty ]] || { echo "monosense-admin authentication requires a terminal" >&2; exit 1; }
IFS= read -r -s -p "monosense-admin password: " password </dev/tty
printf '\n' >/dev/tty
admin_token="$(jq -cn --arg password "$password" '{password:$password}' |
    bao write -field=token auth/userpass/login/monosense-admin -)"
unset password
export BAO_TOKEN="$admin_token"
bao token lookup -format=json | jq -e '.data.policies | any(. == "admin" or . == "root")' >/dev/null

auth_json="$(bao auth list -format=json)"
if ! jq -e 'has("kubernetes/")' <<<"$auth_json" >/dev/null; then
    bao auth enable -path=kubernetes kubernetes >/dev/null
else
    jq -e '."kubernetes/".type == "kubernetes"' <<<"$auth_json" >/dev/null
fi
mounts_json="$(bao secrets list -format=json)"
if ! jq -e 'has("pki-kubernetes/")' <<<"$mounts_json" >/dev/null; then
    bao secrets enable -path=pki-kubernetes -max-lease-ttl=87600h pki >/dev/null
    bao write -field=certificate pki-kubernetes/root/generate/internal \
        common_name="Monosense Kubernetes Internal Root" ttl=87600h >/dev/null
else
    jq -e '."pki-kubernetes/".type == "pki"' <<<"$mounts_json" >/dev/null
    bao read -field=certificate pki-kubernetes/cert/ca |
        grep -Fq 'BEGIN CERTIFICATE' || {
            echo "existing pki-kubernetes mount has no internal CA" >&2
            exit 1
        }
fi
bao secrets tune -max-lease-ttl=87600h pki-kubernetes >/dev/null
bao write pki-kubernetes/config/urls \
    issuing_certificates="$BAO_ADDR/v1/pki-kubernetes/ca" \
    crl_distribution_points="$BAO_ADDR/v1/pki-kubernetes/crl" >/dev/null
bao policy write monosense-infra "$policy" >/dev/null

for forbidden in 'path "sys/auth/' 'path "sys/mounts/' 'capabilities = ["sudo"]' 'path "auth/*' 'path "sys/policies/acl/*'; do
    ! grep -Fq "$forbidden" "$policy" || { echo "monosense-infra envelope is overbroad: $forbidden" >&2; exit 1; }
done
printf 'OpenBao Kubernetes auth and private-PKI mounts exist; exact monosense-infra configuration envelope installed\n'
