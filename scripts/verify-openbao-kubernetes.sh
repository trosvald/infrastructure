#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_dir"
[[ $# -eq 0 ]] || { echo "verify-openbao-kubernetes accepts no arguments" >&2; exit 2; }
[[ -n "${OPENBAO_RUNTIME_DIR:-}" && -d "$OPENBAO_RUNTIME_DIR" && ! -L "$OPENBAO_RUNTIME_DIR" && -n "${BAO_TOKEN:-}" ]] || {
    echo "verify-openbao-kubernetes requires the protected monosense-infra runtime" >&2
    exit 1
}
for tool in bao jq kubectl openssl; do
    command -v "$tool" >/dev/null 2>&1 || { echo "missing locked executable: $tool" >&2; exit 1; }
done
runtime="$OPENBAO_RUNTIME_DIR/kubernetes-verify"
mkdir -p "$runtime"
chmod 0700 "$runtime"
config="$(bao read -format=json auth/kubernetes/config)"
jq -e '
    .data.kubernetes_host == "https://k8s.monosense.io:6443" and
    .data.disable_local_ca_jwt == true and
    .data.disable_iss_validation == true and
    ((.data.token_reviewer_jwt // "") == "")
' <<<"$config" >/dev/null

login() {
    local role="$1" jwt="$2" output="$3"
    jq -cn --arg role "$role" --arg jwt "$jwt" '{role:$role,jwt:$jwt}' |
        bao write -format=json auth/kubernetes/login - > "$output"
    chmod 0600 "$output"
    jq -er '.auth.client_token' "$output"
}
revoke() {
    local token="$1"
    BAO_TOKEN="$token" bao token revoke -self >/dev/null
    ! BAO_TOKEN="$token" bao token lookup >/dev/null 2>&1
}

eso_jwt="$(kubectl -n external-secrets create token openbao --duration=10m \
    --audience=openbao-external-secrets --audience=https://k8s.monosense.io:6443)"
eso_token="$(login external-secrets "$eso_jwt" "$runtime/eso-login.json")"
unset eso_jwt
[[ "$(BAO_TOKEN="$eso_token" bao token capabilities \
    kv/data/platform/kubernetes/flux-system/image-automation)" == "read" ]]
[[ "$(BAO_TOKEN="$eso_token" bao token capabilities \
    kv/data/platform/kubernetes/default/not-allowed)" == "deny" ]]
[[ "$(BAO_TOKEN="$eso_token" bao token capabilities \
    kv/data/platform/kubernetes/verification/eso-cas)" == "create, patch, read, update" ]]
[[ "$(BAO_TOKEN="$eso_token" bao token capabilities \
    kv/metadata/platform/kubernetes/verification/eso-cas)" == "create, patch, read, update" ]]
for denied in \
    kv/metadata/platform/kubernetes/flux-system \
    kv/data/platform/kubernetes/not-approved \
    auth/kubernetes/config sys/policies/acl/admin sys/auth/kubernetes; do
    [[ "$(BAO_TOKEN="$eso_token" bao token capabilities "$denied")" == "deny" ]]
done
! BAO_TOKEN="$eso_token" bao kv list -mount=kv platform/kubernetes >/dev/null 2>&1
! BAO_TOKEN="$eso_token" bao kv delete -mount=kv platform/kubernetes/verification/eso-cas >/dev/null 2>&1

version=0
metadata="$(BAO_TOKEN="$eso_token" bao kv metadata get -mount=kv -format=json \
    platform/kubernetes/verification/eso-cas 2>/dev/null || true)"
if [[ -n "$metadata" ]]; then version="$(jq -er '.data.current_version' <<<"$metadata")"; fi
nonce="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
BAO_TOKEN="$eso_token" bao kv put -mount=kv -cas="$version" \
    platform/kubernetes/verification/eso-cas verified_at="$nonce" >/dev/null
! BAO_TOKEN="$eso_token" bao kv put -mount=kv -cas="$version" \
    platform/kubernetes/verification/eso-cas verified_at="$nonce" >/dev/null 2>&1
unset nonce

bad_audience="$(kubectl -n external-secrets create token openbao --duration=10m --audience=not-openbao)"
! jq -cn --arg role external-secrets --arg jwt "$bad_audience" '{role:$role,jwt:$jwt}' |
    bao write auth/kubernetes/login - >/dev/null 2>&1
unset bad_audience
! jq -cn --arg role cert-manager-networking --arg jwt "$(kubectl -n external-secrets create token openbao --duration=10m --audience=openbao-cert-manager-networking)" '{role:$role,jwt:$jwt}' |
    bao write auth/kubernetes/login - >/dev/null 2>&1

issuer_jwt="$(kubectl -n networking create token openbao-issuer --duration=10m \
    --audience=openbao-cert-manager-networking --audience=https://k8s.monosense.io:6443)"
issuer_token="$(login cert-manager-networking "$issuer_jwt" "$runtime/issuer-login.json")"
unset issuer_jwt
openssl req -new -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes \
    -subj /CN=envoy-edge.networking.svc.cluster.local \
    -keyout "$runtime/allowed.key" -out "$runtime/allowed.csr" >/dev/null 2>&1
BAO_TOKEN="$issuer_token" bao write -format=json pki-kubernetes/sign/envoy-edge \
    csr="@$runtime/allowed.csr" ttl=1h > "$runtime/certificate.json"
jq -e '.data.certificate | contains("BEGIN CERTIFICATE")' "$runtime/certificate.json" >/dev/null
openssl req -new -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes \
    -subj '/CN=*.monosense.io' \
    -keyout "$runtime/internal.key" -out "$runtime/internal.csr" >/dev/null 2>&1
BAO_TOKEN="$issuer_token" bao write -format=json pki-kubernetes/sign/envoy-internal \
    csr="@$runtime/internal.csr" ttl=1h > "$runtime/internal-certificate.json"
jq -e '.data.certificate | contains("BEGIN CERTIFICATE")' "$runtime/internal-certificate.json" >/dev/null
openssl req -new -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes \
    -subj /CN=forbidden.example.invalid \
    -keyout "$runtime/denied.key" -out "$runtime/denied.csr" >/dev/null 2>&1
! BAO_TOKEN="$issuer_token" bao write pki-kubernetes/sign/envoy-edge \
    csr="@$runtime/denied.csr" ttl=1h >/dev/null 2>&1
[[ "$(BAO_TOKEN="$issuer_token" bao token capabilities pki-kubernetes/root/generate/internal)" == "deny" ]]
revoke "$issuer_token"
revoke "$eso_token"
unset issuer_token eso_token
printf 'OpenBao Kubernetes pull, CAS, denial, audience, identity, signing-bound, and revocation proofs passed\n'
