#!/usr/bin/env bash
set -euo pipefail

fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
for command in awk curl jq kubectl mktemp seq ssh; do
    command -v "$command" >/dev/null 2>&1 || fail "$command is required"
done
kubectl auth can-i create pods -n observability | grep -qx yes || fail 'current identity cannot run observability acceptance'

[[ "$(kubectl get vmsingle victoria-metrics -n observability -o json | jq -r '.spec.retentionPeriod')" == 14d ]] \
    || fail 'VictoriaMetrics retention is not 14 days'
logs_json="$(kubectl get vlsingle victoria-logs -n observability -o json)"
[[ "$(jq -r '.spec.retentionPeriod' <<<"$logs_json")" == 30d ]] || fail 'VictoriaLogs retention is not 30 days'
[[ "$(jq -r '.spec.storage.resources.requests.storage' <<<"$logs_json")" == 50Gi ]] || fail 'VictoriaLogs storage is not 50 GiB'
kubectl get pods -n observability -l app.kubernetes.io/name=vector --no-headers 2>/dev/null | grep -q . \
    && fail 'bundled VictoriaLogs Vector is running'

work="$(mktemp -d)"
chmod 0700 "$work"
run="observability-accept-$(date +%s)"
metric_port=18428
logs_port=19428
alert_port=19093
logs_replicas=1
logs_sts=""
cleanup() {
    rc=$?
    [[ -z "$logs_sts" ]] || kubectl scale statefulset "$logs_sts" -n observability --replicas="$logs_replicas" >/dev/null 2>&1 || true
    kubectl delete pod "$run" -n observability --ignore-not-found --wait=false >/dev/null 2>&1 || true
    for pid in "${forward_pids[@]:-}"; do kill "$pid" >/dev/null 2>&1 || true; done
    rm -rf "$work"
    exit "$rc"
}
trap cleanup EXIT
forward_pids=()
kubectl port-forward -n observability service/vmsingle-victoria-metrics "$metric_port:8428" >"$work/metrics-forward.log" 2>&1 &
forward_pids+=("$!")
kubectl port-forward -n observability service/victoria-logs "$logs_port:9428" >"$work/logs-forward.log" 2>&1 &
logs_forward_pid="$!"
forward_pids+=("$logs_forward_pid")
kubectl port-forward -n observability service/vmalertmanager-victoria-metrics "$alert_port:9093" >"$work/alert-forward.log" 2>&1 &
forward_pids+=("$!")
for _ in $(seq 1 30); do
    curl --fail --silent "http://127.0.0.1:$metric_port/health" >/dev/null 2>&1 \
        && curl --fail --silent "http://127.0.0.1:$logs_port/health" >/dev/null 2>&1 \
        && curl --fail --silent "http://127.0.0.1:$alert_port/-/ready" >/dev/null 2>&1 && break
    sleep 1
done
curl --fail --silent "http://127.0.0.1:$metric_port/health" >/dev/null || fail 'VictoriaMetrics port-forward is not ready'

printf 'observability_acceptance_metric{run="%s"} 1\n' "$run" >"$work/metric.txt"
curl --fail --silent --show-error --data-binary @"$work/metric.txt" \
    "http://127.0.0.1:$metric_port/api/v1/import/prometheus" >/dev/null
curl --fail --silent --get --data-urlencode "query=observability_acceptance_metric{run=\"$run\"}" \
    "http://127.0.0.1:$metric_port/api/v1/query" \
    | jq -e '.data.result[0].value[1] == "1"' >/dev/null || fail 'synthetic metric was not queryable'

canary="obs-$run"
kubectl run "$run" -n observability --restart=Never \
    --image=ghcr.io/dragonflydb/dragonfly:v1.40.1@sha256:ebf3c6c213e82fb51b4521660cca13f06f3421dc5b1ed14f2f474c50b5e29986 \
    --overrides='{"spec":{"automountServiceAccountToken":false,"containers":[{"name":"logger","image":"ghcr.io/dragonflydb/dragonfly:v1.40.1@sha256:ebf3c6c213e82fb51b4521660cca13f06f3421dc5b1ed14f2f474c50b5e29986","securityContext":{"allowPrivilegeEscalation":false,"readOnlyRootFilesystem":true,"capabilities":{"drop":["ALL"]}},"resources":{"requests":{"cpu":"5m","memory":"8Mi"},"limits":{"cpu":"50m","memory":"32Mi"}}}]}}' \
    --command -- /bin/sh -ec "printf '%s\\n' '$canary password=OBSERVABILITY-SECRET-CANARY token=OBSERVABILITY-TOKEN-CANARY'" >/dev/null
kubectl wait --for=jsonpath='{.status.phase}'=Succeeded pod/"$run" -n observability --timeout=2m >/dev/null
for _ in $(seq 1 60); do
    curl --fail --silent --get --data-urlencode "query=_msg:$canary" --data-urlencode 'limit=20' \
        "http://127.0.0.1:$logs_port/select/logsql/query" >"$work/log-query.json" 2>/dev/null || true
    grep -q "$canary" "$work/log-query.json" && break
    sleep 2
done
grep -q "$canary" "$work/log-query.json" || fail 'synthetic Kubernetes log did not reach VictoriaLogs'
grep -q 'password=\[REDACTED\]' "$work/log-query.json" || fail 'password canary was not redacted'
grep -q 'token=\[REDACTED\]' "$work/log-query.json" || fail 'token canary was not redacted'
! grep -q 'OBSERVABILITY-SECRET-CANARY\|OBSERVABILITY-TOKEN-CANARY' "$work/log-query.json" \
    || fail 'raw secret canary reached VictoriaLogs'

printf '[{"labels":{"alertname":"ObservabilityAcceptance","severity":"info","namespace":"observability","run":"%s"},"annotations":{"summary":"synthetic acceptance"},"startsAt":"%s"}]' \
    "$run" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >"$work/alert.json"
curl --fail --silent --show-error -H 'Content-Type: application/json' --data-binary @"$work/alert.json" \
    "http://127.0.0.1:$alert_port/api/v2/alerts" >/dev/null
for _ in $(seq 1 30); do
    delivered="$(curl --fail --silent --get --data-urlencode 'query=increase(alertmanager_notifications_total{integration="telegram"}[5m])' \
        "http://127.0.0.1:$metric_port/api/v1/query" | jq -r '[.data.result[].value[1] | tonumber] | add // 0')"
    awk "BEGIN { exit !($delivered > 0) }" && break
    sleep 2
done
awk "BEGIN { exit !(${delivered:-0} > 0) }" || fail 'Telegram notification delivery was not observed'

curl --silent --output /dev/null --write-out '%{http_code}' --resolve vlogs.monosense.io:443:10.25.20.40 \
    https://vlogs.monosense.io/ | grep -Eq '^(302|401)$' || fail 'VictoriaLogs query route permits unauthenticated access'
status="$(curl --silent --output /dev/null --write-out '%{http_code}' --resolve vlogs.monosense.io:443:10.25.20.40 \
    -X POST https://vlogs.monosense.io/insert/jsonline)"
[[ "$status" != 200 && "$status" != 204 ]] || fail 'query route exposes VictoriaLogs ingestion'

logs_sts="$(kubectl get statefulset -n observability -l app.kubernetes.io/instance=victoria-logs -o json | jq -er '.items | select(length == 1) | .[0].metadata.name')"
logs_replicas="$(kubectl get statefulset "$logs_sts" -n observability -o json | jq -r '.spec.replicas')"
kubectl scale statefulset "$logs_sts" -n observability --replicas=0 >/dev/null
kubectl wait --for=delete pod -n observability -l app.kubernetes.io/instance=victoria-logs --timeout=3m >/dev/null
buffer_canary="buffer-$run"
ssh c1 sudo /bin/sh -ceu "printf '%s\\n' '$buffer_canary password=BUFFER-CANARY' >>/srv/applications/apps/forgejo/logs/backup/observability-acceptance.log"
sleep 5
ssh c1 sudo docker exec vector-c1 /bin/sh -ceu 'find /var/lib/vector -type f -size +0c -print -quit | grep -q .' \
    || fail 'c1 Vector did not persist the outage buffer'
kubectl scale statefulset "$logs_sts" -n observability --replicas="$logs_replicas" >/dev/null
kubectl rollout status statefulset/"$logs_sts" -n observability --timeout=5m >/dev/null
kill "$logs_forward_pid" >/dev/null 2>&1 || true
kubectl port-forward -n observability service/victoria-logs "$logs_port:9428" >"$work/logs-forward-recovery.log" 2>&1 &
logs_forward_pid="$!"
forward_pids+=("$logs_forward_pid")
for _ in $(seq 1 30); do
    curl --fail --silent "http://127.0.0.1:$logs_port/health" >/dev/null 2>&1 && break
    sleep 1
done
for _ in $(seq 1 60); do
    curl --fail --silent --get --data-urlencode "query=_msg:$buffer_canary" --data-urlencode 'limit=20' \
        "http://127.0.0.1:$logs_port/select/logsql/query" >"$work/buffer-query.json" 2>/dev/null || true
    grep -q "$buffer_canary" "$work/buffer-query.json" && break
    sleep 2
done
grep -q "$buffer_canary" "$work/buffer-query.json" || fail 'Vector outage buffer did not drain'

curl --fail --silent --get --data-urlencode 'query=count(probe_success{tier=~"critical|infrastructure"} == 1)' \
    "http://127.0.0.1:$metric_port/api/v1/query" \
    | jq -e '.data.result[0].value[1] | tonumber >= 13' >/dev/null || fail 'tiered blackbox path is incomplete'
curl --fail --silent --get --data-urlencode 'query=count_over_time({_msg=~"RT_(FLOW|SCREEN)|BGP|UI_(AUTH_EVENT|COMMIT)"}[24h])' \
    "http://127.0.0.1:$logs_port/select/logsql/stats_query" >/dev/null || fail 'SRX event query failed'

for forbidden in gatus karma kromgo prometheus-adapter unpoller zfs-exporter nfs-subdir-external-provisioner zigbee2mqtt; do
    kubectl get deployment,statefulset,daemonset -A -o name | grep -qi "$forbidden" \
        && fail "rejected live surface remains: $forbidden"
done
printf '%s\n' 'Observability metric, redacted logs, Telegram, isolation, buffering, SRX query, and blackbox acceptance passed'
