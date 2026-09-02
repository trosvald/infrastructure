#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
probe="$repo_dir/kubernetes/scripts/dns_probe.py"
namespace=powerdns-acceptance
name=powerdns-acceptance.monosense.io
updated=powerdns-acceptance-updated.monosense.io
server=10.25.13.33
image='ghcr.io/mendhak/http-https-echo:41@sha256:2046be25f4a2c0bdda662ebfb7c2b7b60fc95c31d97987be143645a8a2194a40'
for tool in jq kubectl python ssh; do
    command -v "$tool" >/dev/null 2>&1 || { echo "missing locked tool: $tool" >&2; exit 1; }
done
cleanup() { kubectl delete namespace "$namespace" --ignore-not-found --wait=false >/dev/null 2>&1 || true; }
trap cleanup EXIT HUP INT TERM
cleanup

remote_powerdns() {
    ssh -o BatchMode=yes -o StrictHostKeyChecking=yes monosense@10.25.10.20 "$1"
}
wait_record() {
    local record=$1 type=$2 expression=$3 result
    for _ in $(seq 1 60); do
        result="$(python "$probe" "$server" query "$record" "$type")"
        if jq -e "$expression" <<<"$result" >/dev/null; then
            printf '%s' "$result"
            return 0
        fi
        sleep 2
    done
    printf '%s\n' "timed out waiting for $record $type: $result" >&2
    return 1
}

cat <<YAML | kubectl apply -f - >/dev/null
apiVersion: v1
kind: Namespace
metadata:
  name: $namespace
  labels:
    pod-security.kubernetes.io/enforce: restricted
    gateway.monosense.io/allow-internal-routes: "true"
---
apiVersion: apps/v1
kind: Deployment
metadata: { name: echo, namespace: $namespace }
spec:
  replicas: 1
  selector: { matchLabels: { app: powerdns-acceptance } }
  template:
    metadata: { labels: { app: powerdns-acceptance } }
    spec:
      securityContext: { runAsNonRoot: true, runAsUser: 1000, runAsGroup: 1000, seccompProfile: { type: RuntimeDefault } }
      containers:
        - name: echo
          image: $image
          env: [{ name: HTTP_PORT, value: "8080" }]
          ports: [{ name: http, containerPort: 8080 }]
          securityContext: { allowPrivilegeEscalation: false, readOnlyRootFilesystem: true, capabilities: { drop: [ALL] } }
          resources:
            requests: { cpu: 10m, memory: 32Mi }
            limits: { cpu: 250m, memory: 128Mi }
---
apiVersion: v1
kind: Service
metadata: { name: echo, namespace: $namespace }
spec:
  selector: { app: powerdns-acceptance }
  ports: [{ name: http, port: 8080, targetPort: http }]
---
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata: { name: echo-from-envoy-internal, namespace: $namespace }
spec:
  endpointSelector: { matchLabels: { app: powerdns-acceptance } }
  ingress:
    - fromEndpoints:
        - matchLabels:
            k8s:io.kubernetes.pod.namespace: networking
            k8s:io.cilium.k8s.policy.serviceaccount: envoy-internal
      toPorts:
        - ports: [{ port: "8080", protocol: TCP }]
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata: { name: powerdns-acceptance, namespace: $namespace }
spec:
  hostnames: [$name]
  parentRefs: [{ name: envoy-internal, namespace: networking, sectionName: https }]
  rules:
    - backendRefs: [{ name: echo, port: 8080 }]
YAML
kubectl -n "$namespace" rollout status deployment/echo --timeout=5m >/dev/null
for _ in $(seq 1 60); do
    route="$(kubectl -n "$namespace" get httproute powerdns-acceptance -o json)"
    if jq -e '.status.parents | length == 1 and .[0].conditions | any(.type == "Accepted" and .status == "True") and any(.type == "ResolvedRefs" and .status == "True")' <<<"$route" >/dev/null; then
        break
    fi
    sleep 2
done
jq -e '.status.parents | length == 1 and .[0].conditions | any(.type == "Accepted" and .status == "True") and any(.type == "ResolvedRefs" and .status == "True")' <<<"$route" >/dev/null
wait_record "$name" A '.rcode == 0 and .aa == true and .values == ["10.25.20.40"]' >/dev/null
wait_record "$name" TXT '.rcode == 0 and .aa == true and any(.values[]; contains("external-dns/owner=external-dns-internal"))' >/dev/null

remote_powerdns 'set -eu; ids=$(sudo -n docker ps --filter label=com.docker.compose.project=powerdns-c0 --filter label=com.docker.compose.service=powerdns --format "{{.ID}}"); test "$(printf "%s\n" "$ids" | wc -l)" = 1; sudo -n docker exec "$ids" /usr/local/bin/reconcile.sh; sudo -n docker exec "$ids" pdns_control rediscover >/dev/null'
wait_record "$name" A '.rcode == 0 and .aa == true and .values == ["10.25.20.40"]' >/dev/null
wait_record "$name" TXT '.rcode == 0 and any(.values[]; contains("external-dns/owner=external-dns-internal"))' >/dev/null

kubectl -n "$namespace" patch httproute powerdns-acceptance --type=merge \
    --patch "{\"spec\":{\"hostnames\":[\"$updated\"]}}" >/dev/null
wait_record "$updated" A '.rcode == 0 and .aa == true and .values == ["10.25.20.40"]' >/dev/null
wait_record "$name" A '(.rcode == 0 or .rcode == 3) and (.values | length) == 0' >/dev/null

before="$(remote_powerdns 'set -eu; id=$(sudo -n docker ps --filter label=com.docker.compose.project=powerdns-c0 --filter label=com.docker.compose.service=powerdns --format "{{.ID}}"); test -n "$id"; sudo -n docker exec "$id" sha256sum /var/lib/powerdns/pdns.sqlite3 | cut -d " " -f 1')"
cat <<YAML | kubectl apply -f - >/dev/null
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata: { name: canonical-collision, namespace: $namespace }
spec:
  hostnames: [git.monosense.io]
  parentRefs: [{ name: envoy-internal, namespace: networking, sectionName: https }]
  rules:
    - backendRefs: [{ name: echo, port: 8080 }]
YAML
sleep 10
wait_record git.monosense.io A '.rcode == 0 and .aa == true and .values == ["10.25.15.10"]' >/dev/null
collision_txt="$(python "$probe" "$server" query git.monosense.io TXT)"
jq -e 'all(.values[]; contains("external-dns/owner=external-dns-internal") | not)' <<<"$collision_txt" >/dev/null
after="$(remote_powerdns 'set -eu; id=$(sudo -n docker ps --filter label=com.docker.compose.project=powerdns-c0 --filter label=com.docker.compose.service=powerdns --format "{{.ID}}"); test -n "$id"; sudo -n docker exec "$id" sha256sum /var/lib/powerdns/pdns.sqlite3 | cut -d " " -f 1')"
[[ "$before" == "$after" ]] || { echo 'canonical collision changed the live PowerDNS database' >&2; exit 1; }
kubectl -n "$namespace" delete httproute canonical-collision --wait=true >/dev/null

unsigned="$(python "$probe" "$server" unsigned-update unsigned-denial.monosense.io)"
jq -e '.rcode == 5 or .rcode == 9' <<<"$unsigned" >/dev/null
kubectl -n "$namespace" delete httproute powerdns-acceptance --wait=true >/dev/null
wait_record "$updated" A '(.rcode == 0 or .rcode == 3) and (.values | length) == 0' >/dev/null
wait_record "$updated" TXT '(.rcode == 0 or .rcode == 3) and (.values | length) == 0' >/dev/null
printf '%s\n' 'PowerDNS acceptance passed: TXT-owned create/update/delete, Git reconcile preservation, canonical collision refusal, authoritative answers, TSIG denial, and unchanged collision state'
