#!/usr/bin/env bash
set -euo pipefail

fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
for command in bao curl jq kubectl mktemp openssl ssh; do
    command -v "$command" >/dev/null 2>&1 || fail "$command is required"
done
[[ -n "${BAO_ADDR:-}" && -n "${BAO_TOKEN:-}" ]] || fail 'run through scripts/with-openbao-runtime.sh'
[[ "${BAO_SKIP_VERIFY:-false}" != true ]] || fail 'OpenBao TLS verification bypasses are forbidden'
: "${LLMKUBE_MAC_ADMIN:?set LLMKUBE_MAC_ADMIN to the named Mac administrator}"
[[ "${AI_ACCEPT_REBOOT:-}" == YES ]] || fail 'set AI_ACCEPT_REBOOT=YES after scheduling the cold/reboot appliance proof'
readonly mac=10.25.13.95
readonly canary="ai-accept-$(date -u +%Y%m%d%H%M%S)-authorization-secret"
work="$(mktemp -d)"
chmod 0700 "$work"
logs_forward_pid=
physical_job=
logical_job=
cleanup() {
    rc=$?
    kubectl -n ai patch kustomization litellm --type=merge -p '{"spec":{"suspend":false}}' >/dev/null 2>&1 || true
    [[ ! -s "$work/litellm-policy.json" ]] || kubectl apply -f "$work/litellm-policy.json" >/dev/null 2>&1 || true
    [[ ! -s "$work/codex-policy.json" ]] || kubectl apply -f "$work/codex-policy.json" >/dev/null 2>&1 || true
    [[ ! -s "$work/embedding-slice.json" ]] || kubectl apply -f "$work/embedding-slice.json" >/dev/null 2>&1 || true
    [[ -z "$logs_forward_pid" ]] || kill "$logs_forward_pid" >/dev/null 2>&1 || true
    [[ -z "$physical_job" ]] || kubectl -n ai delete job "$physical_job" --ignore-not-found >/dev/null 2>&1 || true
    [[ -z "$logical_job" ]] || kubectl -n ai delete job "$logical_job" --ignore-not-found >/dev/null 2>&1 || true
    rm -rf "$work"
    exit "$rc"
}
trap cleanup EXIT

kubectl -n ai wait --for=condition=Ready kustomization/llmkube kustomization/codex-adapter kustomization/litellm kustomization/memini --timeout=15m
[[ "$(kubectl -n ai get deployment -l app.kubernetes.io/name=llmkube -o json | jq '[.items[].status.readyReplicas // 0] | add')" -eq 2 ]] || fail 'LLMKube controller is not two-replica Ready'
[[ "$(kubectl -n ai get deployment -l app.kubernetes.io/name=litellm -o json | jq '[.items[].status.readyReplicas // 0] | add')" -eq 2 ]] || fail 'LiteLLM is not two-replica Ready'
[[ "$(kubectl -n ai get statefulset memini -o jsonpath='{.status.readyReplicas}')" == 1 ]] || fail 'Memini is not Ready'
[[ "$(kubectl -n ai get endpointslice qwen3-embedding-tls-mac -o jsonpath='{.endpoints[0].addresses[0]}')" == "$mac" ]]

ssh -o BatchMode=yes -o StrictHostKeyChecking=yes "$LLMKUBE_MAC_ADMIN@$mac" sudo shutdown -r now >/dev/null 2>&1 || true
for _ in {1..60}; do ssh -o BatchMode=yes -o ConnectTimeout=2 "$LLMKUBE_MAC_ADMIN@$mac" true >/dev/null 2>&1 || break; sleep 2; done
for _ in {1..180}; do ssh -o BatchMode=yes -o ConnectTimeout=3 "$LLMKUBE_MAC_ADMIN@$mac" sudo launchctl print system/io.monosense.llmkube-caddy >/dev/null 2>&1 && break; sleep 2; done
ssh -o BatchMode=yes "$LLMKUBE_MAC_ADMIN@$mac" sudo launchctl print system/io.monosense.llmkube-metal-agent >/dev/null
ssh -o BatchMode=yes "$LLMKUBE_MAC_ADMIN@$mac" "shasum -a 256 /var/lib/llmkube/models/Qwen3-Embedding-4B-Q8_0.gguf" \
    | grep -q '^b60ae5ce2dd6a0b77f82cadf21def1f310a3e10cde380ad0081b07a9d416949d '
ssh -o BatchMode=yes "$LLMKUBE_MAC_ADMIN@$mac" "test \"\$(stat -f %z /var/lib/llmkube/models/Qwen3-Embedding-4B-Q8_0.gguf)\" = 4279660224"
ssh -o BatchMode=yes "$LLMKUBE_MAC_ADMIN@$mac" "ps -axo rss,command | grep '[l]lama-server'" >"$work/rss"

kubectl -n ai get secret llmkube-mac-tls -o jsonpath='{.data.ca\.crt}' | openssl base64 -d -A >"$work/ca.crt"
kubectl -n ai get secret llmkube-embedding-api-key -o jsonpath='{.data.api-key}' | openssl base64 -d -A >"$work/embed-key"
chmod 0600 "$work/embed-key"
EMBED_KEY="$(<"$work/embed-key")" curl --fail --silent --show-error --cacert "$work/ca.crt" \
    --resolve embedding.internal:8443:$mac --variable %EMBED_KEY \
    --expand-header 'Authorization: Bearer {{EMBED_KEY}}' -H 'Content-Type: application/json' \
    -d '{"model":"qwen3-embedding","input":"acceptance"}' \
    https://embedding.internal:8443/v1/embeddings >"$work/embed.json"
jq -e '.data[0].embedding | length == 2560' "$work/embed.json" >/dev/null
if curl --silent --show-error --connect-timeout 3 "http://$mac:8081/health" >/dev/null 2>&1; then fail 'direct llama-server port 8081 is reachable'; fi
kubectl -n ai get secret mac-embedding-client-tls -o jsonpath='{.data.tls\.crt}' | openssl base64 -d -A >"$work/metrics.crt"
kubectl -n ai get secret mac-embedding-client-tls -o jsonpath='{.data.tls\.key}' | openssl base64 -d -A >"$work/metrics.key"
curl --fail --silent --show-error --cacert "$work/ca.crt" --cert "$work/metrics.crt" --key "$work/metrics.key" \
    --resolve mac-metrics.internal:9443:$mac https://mac-metrics.internal:9443/metrics | grep -q '^llmkube_'
if curl --silent --show-error --cacert "$work/ca.crt" --resolve mac-metrics.internal:9443:$mac https://mac-metrics.internal:9443/metrics >/dev/null 2>&1; then fail 'metrics endpoint accepts clients without mTLS'; fi

bao kv get -mount=kv -field=operator_api_key platform/kubernetes/ai/memini >"$work/memini-key"
bao kv get -mount=kv -field=memini_virtual_key platform/kubernetes/ai/litellm >"$work/memini-litellm-key"
bao kv get -mount=kv -field=forgejo_virtual_key platform/kubernetes/ai/litellm >"$work/forgejo-litellm-key"
bao kv get -mount=kv -field=breakglass_master_key platform/kubernetes/ai/litellm >"$work/litellm-master-key"
chmod 0600 "$work"/*key
memini_request() {
    MEMINI_KEY="$(<"$work/memini-key")" curl --fail --silent --show-error --variable %MEMINI_KEY \
        --expand-header 'Authorization: Bearer {{MEMINI_KEY}}' "$@"
}
memini_request -H 'Content-Type: application/json' -d "{\"namespace\":\"acceptance\",\"content\":\"$canary\"}" https://memini-api.internal/v1/memories >"$work/memory.json"
memini_request "https://memini-api.internal/v1/recall?q=$canary&namespace=acceptance" | jq -e --arg canary "$canary" '.. | strings | select(contains($canary))' >/dev/null
fallback_canary="${canary}-vectorless"
kubectl -n ai get endpointslice qwen3-embedding-tls-mac -o json \
    | jq 'del(.metadata.creationTimestamp,.metadata.generation,.metadata.resourceVersion,.metadata.uid,.metadata.managedFields,.status)' \
    >"$work/embedding-slice.json"
kubectl -n ai patch endpointslice qwen3-embedding-tls-mac --type=json \
    -p '[{"op":"replace","path":"/endpoints/0/addresses/0","value":"192.0.2.1"}]' >/dev/null
memini_request -H 'Content-Type: application/json' \
    -d "{\"namespace\":\"acceptance\",\"content\":\"$fallback_canary\"}" \
    https://memini-api.internal/v1/memories >"$work/vectorless-memory.json"
memini_request "https://memini-api.internal/v1/recall?q=$fallback_canary&namespace=acceptance" \
    | jq -e --arg canary "$fallback_canary" '.. | strings | select(contains($canary))' >/dev/null
kubectl apply -f "$work/embedding-slice.json" >/dev/null
kubectl -n ai exec memini-0 -- /usr/local/bin/memini reembed --yes --namespace acceptance >/dev/null
physical_job="memini-accept-physical-$(date +%s)"
logical_job="memini-accept-logical-$(date +%s)"
kubectl -n ai create job --from=cronjob/memini-sqlite-backup "$physical_job" >/dev/null
kubectl -n ai create job --from=cronjob/memini-logical-backup "$logical_job" >/dev/null
kubectl -n ai wait --for=condition=complete "job/$physical_job" "job/$logical_job" --timeout=15m >/dev/null

litellm_call() {
    local key_file="$1" model="$2" output="$3"
    LITELLM_KEY="$(<"$key_file")" curl --silent --show-error --output "$output" \
        --write-out '%{http_code}' --variable %LITELLM_KEY \
        --expand-header 'Authorization: Bearer {{LITELLM_KEY}}' -H 'Content-Type: application/json' \
        -d "{\"model\":\"$model\",\"messages\":[{\"role\":\"user\",\"content\":\"reply ok\"}],\"max_tokens\":4}" \
        https://litellm.internal/v1/chat/completions
}
[[ "$(litellm_call "$work/memini-litellm-key" memini-chat "$work/minimax.json")" == 200 ]]
[[ "$(litellm_call "$work/memini-litellm-key" forgejo-codex "$work/denied.json")" =~ ^(401|403)$ ]] || fail 'Memini key can call Forgejo Codex alias'
[[ "$(litellm_call "$work/forgejo-litellm-key" memini-chat "$work/denied.json")" =~ ^(401|403)$ ]] || fail 'Forgejo key can call MiniMax alias'
LITELLM_MASTER="$(<"$work/litellm-master-key")" curl --fail --silent --show-error \
    --variable %LITELLM_MASTER --expand-header 'Authorization: Bearer {{LITELLM_MASTER}}' \
    'https://litellm-admin.internal/key/list?page=1&size=100' >"$work/litellm-keys.json"
jq -e '[.keys[] | select(.key_alias == "memini" and .models == ["memini-chat"] and .rpm_limit == 20 and .tpm_limit == 200000 and .max_parallel_requests == 2 and .max_budget == 5 and .budget_duration == "30d")] | length == 1' "$work/litellm-keys.json" >/dev/null
jq -e '[.keys[] | select(.key_alias == "forgejo" and .models == ["forgejo-codex"] and .rpm_limit == 30 and .max_parallel_requests == 2 and .max_budget == 500 and .budget_duration == "1d")] | length == 1' "$work/litellm-keys.json" >/dev/null

kubectl -n ai get ciliumnetworkpolicy litellm -o json \
    | jq 'del(.metadata.creationTimestamp,.metadata.generation,.metadata.resourceVersion,.metadata.uid,.metadata.managedFields,.status)' \
    >"$work/litellm-policy.json"
kubectl -n ai patch kustomization litellm --type=merge -p '{"spec":{"suspend":true}}' >/dev/null
kubectl -n ai patch ciliumnetworkpolicy litellm --type=json -p '[{"op":"replace","path":"/spec/egress","value":[]}]' >/dev/null
kubectl -n ai rollout restart deployment -l app.kubernetes.io/name=litellm >/dev/null
sleep 20
if litellm_call "$work/memini-litellm-key" memini-chat "$work/failclosed.json" | grep -q '^200$'; then fail 'LiteLLM stayed available without CNPG and Dragonfly policy state'; fi
kubectl apply -f "$work/litellm-policy.json" >/dev/null
kubectl -n ai rollout restart deployment -l app.kubernetes.io/name=litellm >/dev/null
kubectl -n ai rollout status deployment -l app.kubernetes.io/name=litellm --timeout=10m >/dev/null

kubectl -n ai get ciliumnetworkpolicy codex-adapter -o json \
    | jq 'del(.metadata.creationTimestamp,.metadata.generation,.metadata.resourceVersion,.metadata.uid,.metadata.managedFields,.status)' \
    >"$work/codex-policy.json"
kubectl -n ai patch ciliumnetworkpolicy codex-adapter --type=json -p '[{"op":"replace","path":"/spec/egress","value":[]}]' >/dev/null
sleep 5
if litellm_call "$work/forgejo-litellm-key" forgejo-codex "$work/codex-denied.json" | grep -q '^200$'; then fail 'Codex adapter did not fail closed when OAuth refresh was unreachable'; fi
kubectl apply -f "$work/codex-policy.json" >/dev/null

logs_port=19428
kubectl port-forward -n observability service/victoria-logs "$logs_port:9428" >"$work/logs-forward.log" 2>&1 &
logs_forward_pid="$!"
for _ in {1..30}; do
    curl --fail --silent "http://127.0.0.1:$logs_port/health" >/dev/null 2>&1 && break
    sleep 1
done
curl --fail --silent --show-error --get --data-urlencode "query=_msg:$canary" \
    --data-urlencode 'limit=20' "http://127.0.0.1:$logs_port/select/logsql/query" >"$work/logs.json"
! grep -Fq "$canary" "$work/logs.json" || fail 'sensitive AI canary reached logs'
printf 'AI acceptance passed: headless Metal recovery, isolated embedding, Memini durability/fallback, gateway quotas, fail-closed policy state, and bounded telemetry\n'
