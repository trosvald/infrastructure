#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_dir"
[[ $# -eq 0 ]] || { echo "configure-openbao-kubernetes accepts no arguments" >&2; exit 2; }
[[ -n "${OPENBAO_RUNTIME_DIR:-}" && -d "$OPENBAO_RUNTIME_DIR" && ! -L "$OPENBAO_RUNTIME_DIR" && -n "${BAO_TOKEN:-}" ]] || {
    echo "configure-openbao-kubernetes requires the protected monosense-infra runtime" >&2
    exit 1
}
for tool in bao jq kubectl python; do
    command -v "$tool" >/dev/null 2>&1 || { echo "missing locked executable: $tool" >&2; exit 1; }
done
umask 077
kube_json="$OPENBAO_RUNTIME_DIR/kubernetes-config.json"
ca_file="$OPENBAO_RUNTIME_DIR/kubernetes-ca.crt"
kubectl config view --raw --minify -o json > "$kube_json"
jq -e '.clusters | length == 1 and .[0].cluster.server == "https://k8s.monosense.io:6443"' "$kube_json" >/dev/null
python - "$kube_json" "$ca_file" <<'PY'
import base64, json, pathlib, sys
value = json.loads(pathlib.Path(sys.argv[1]).read_text())
data = base64.b64decode(value["clusters"][0]["cluster"]["certificate-authority-data"], validate=True)
if b"BEGIN CERTIFICATE" not in data:
    raise SystemExit("Kubernetes CA data is invalid")
pathlib.Path(sys.argv[2]).write_bytes(data)
PY
chmod 0600 "$ca_file"
bao write auth/kubernetes/config \
    kubernetes_host=https://k8s.monosense.io:6443 \
    kubernetes_ca_cert="@$ca_file" \
    token_reviewer_jwt="" \
    disable_local_ca_jwt=true \
    disable_iss_validation=true >/dev/null
bao read -format=json auth/kubernetes/config | jq -e '
    .data.kubernetes_host == "https://k8s.monosense.io:6443" and
    .data.disable_local_ca_jwt == true and
    .data.disable_iss_validation == true and
    ((.data.token_reviewer_jwt // "") == "")
' >/dev/null

policies=(
    kubernetes-external-secrets
    kubernetes-cert-manager-networking
    kubernetes-cert-manager-database
    kubernetes-cert-manager-security
    kubernetes-cert-manager-ai
    kubernetes-keycloak-tofu
    kubernetes-codex-checkpoint
)
for policy in "${policies[@]}"; do
    bao policy write "$policy" "$repo_dir/docker/c0/openbao/policies/$policy.hcl" >/dev/null
done
write_role() {
    local role="$1" service_account="$2" namespace="$3" audience="$4" policy="$5"
    bao write "auth/kubernetes/role/$role" \
        bound_service_account_names="$service_account" \
        bound_service_account_namespaces="$namespace" \
        audience="$audience" \
        token_policies="$policy" \
        token_ttl=15m token_max_ttl=1h token_no_default_policy=true >/dev/null
}
write_role external-secrets openbao external-secrets openbao-external-secrets kubernetes-external-secrets
for namespace in networking database security ai; do
    write_role "cert-manager-$namespace" openbao-issuer "$namespace" \
        "openbao-cert-manager-$namespace" "kubernetes-cert-manager-$namespace"
done
write_role keycloak-tofu keycloak-tofu-runner security keycloak-tofu kubernetes-keycloak-tofu
write_role codex-checkpoint codex-checkpoint ai openbao kubernetes-codex-checkpoint

write_pki_role() {
    local role="$1" domains="$2" client="$3" server="$4"
    bao write "pki-kubernetes/roles/$role" \
        allowed_domains="$domains" allow_bare_domains=true allow_subdomains=false \
        allow_glob_domains=false allow_wildcard_certificates=false \
        enforce_hostnames=true require_cn=false \
        client_flag="$client" server_flag="$server" \
        key_type=ec key_bits=256 signature_bits=256 \
        max_ttl=8760h ttl=720h >/dev/null
}
write_pki_role envoy-edge \
    envoy-edge.networking.svc.cluster.local false true
bao write pki-kubernetes/roles/envoy-internal \
    allowed_domains=monosense.io allow_bare_domains=false allow_subdomains=true \
    allow_glob_domains=false allow_wildcard_certificates=true \
    enforce_hostnames=true require_cn=false \
    client_flag=false server_flag=true \
    key_type=ec key_bits=256 signature_bits=256 \
    max_ttl=2160h ttl=720h >/dev/null
write_pki_role cnpg \
    postgres-rw.database.svc.cluster.local,streaming-replica,keycloak-db,litellm-db true true
write_pki_role dragonfly dragonfly.database.svc.cluster.local,dragonfly.internal true true
write_pki_role keycloak keycloak.security.svc.cluster.local,auth.internal,auth-admin.internal false true
write_pki_role mac-caddy embedding.internal,mac-metrics.internal false true
write_pki_role mac-embedding embedding.internal,mac-metrics.internal,qwen3-embedding-tls.ai.svc.cluster.local true true
bgp_record="$OPENBAO_RUNTIME_DIR/cilium-bgp.json"
bao kv get -mount=kv -format=json network/bgp/cilium-srx1500 > "$bgp_record"
chmod 0600 "$bgp_record"
jq -e '
    (.data.data | keys) ==
        ["password_01", "password_02", "password_03", "password_04", "password_05"] and
    ([.data.data[] | type == "string" and length == 43 and test("^[A-Za-z0-9_-]{43}$")] | all) and
    ([.data.data[]] | unique | length) == 5
' "$bgp_record" >/dev/null
for index in 01 02 03 04 05; do
    record="platform/kubernetes/kube-system/cilium-bgp-bsd-k8s-$index"
    payload="$OPENBAO_RUNTIME_DIR/cilium-bgp-$index.json"
    jq --arg field "password_$index" '{password: .data.data[$field]}' "$bgp_record" > "$payload"
    chmod 0600 "$payload"
    if existing="$(bao kv get -mount=kv -format=json "$record" 2>/dev/null)"; then
        jq -e --slurpfile payload "$payload" '.data.data == $payload[0]' <<<"$existing" >/dev/null || {
            echo "$record differs from the adjacency source; use the one-peer rotation workflow" >&2
            exit 1
        }
    else
        bao kv put -mount=kv -cas=0 "$record" "@$payload" >/dev/null
    fi
done
write_pki_role vector-client vector-c0,vector-c1 true false
write_pki_role vector-srx logs-ingest.monosense.io true true
bao read -field=certificate pki-kubernetes/cert/ca >"$OPENBAO_RUNTIME_DIR/pki-kubernetes-ca.pem"
jq -n --rawfile certificate "$OPENBAO_RUNTIME_DIR/pki-kubernetes-ca.pem" \
    '{data:{certificate:$certificate}}' \
    | bao write kv/data/platform/tls/kubernetes-ca - >/dev/null
bao kv get -mount=kv -format=json platform/tls/kubernetes-ca \
    | jq -e '.data.data | keys == ["certificate"] and (.certificate | contains("BEGIN CERTIFICATE"))' >/dev/null
printf 'OpenBao Kubernetes auth roles, exact policies, and bounded private-PKI roles configured\n'
