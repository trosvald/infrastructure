#!/usr/bin/env bash
set -euo pipefail

fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
for command in kubectl jq base64 mktemp ssh; do
    command -v "$command" >/dev/null 2>&1 || fail "$command is required"
done
kubectl auth can-i get dragonflies.dragonflydb.io -n database | grep -qx yes \
    || fail 'current identity cannot inspect Dragonfly'
[[ "$(kubectl get dragonfly dragonfly -n database -o json | jq -r '.status.phase // .status.conditions[]? | select(.type == "Ready") | .status' | tail -n1)" =~ ^(ready|Ready|True)$ ]] \
    || fail 'Dragonfly is not Ready'
[[ "$(kubectl get pods -n database -l dragonfly.dragonflydb.io/name=dragonfly -o json | jq '[.items[] | select(.status.phase == "Running" and ([.status.containerStatuses[]? | select(.ready == true)] | length) == (.status.containerStatuses | length))] | length')" == 3 ]] \
    || fail 'Dragonfly does not have three Ready instances'
[[ "$(kubectl get endpointslice -n database -l kubernetes.io/service-name=dragonfly-internal -o json | jq '[.items[].endpoints[] | select(.conditions.ready == true) | .addresses[]] | unique | length')" == 1 ]] \
    || fail 'stable Dragonfly VIP does not select exactly one Ready primary'

work="$(mktemp -d)"
chmod 0700 "$work"
probe="dragonfly-accept-$(date +%s)"
cleanup() {
    kubectl delete pod,serviceaccount,secret,ciliumnetworkpolicy -n database \
        -l acceptance.monosense.io/run="$probe" --ignore-not-found --wait=false >/dev/null 2>&1 || true
    rm -rf "$work"
}
trap cleanup EXIT
kubectl get secret dragonfly-acl -n database -o json \
    | jq -er '.data["acl.conf"]' | base64 -d >"$work/acl.conf"
kubectl get secret dragonfly-server-tls -n database -o json \
    | jq -er '.data["ca.crt"]' | base64 -d >"$work/ca.crt"
chmod 0600 "$work/acl.conf" "$work/ca.crt"
password="$(sed -n 's/^user forgejo-a on >\([^ ]*\).*/\1/p' "$work/acl.conf")"
[[ "$password" =~ ^[0-9a-f]{64}$ ]] || fail 'Forgejo Dragonfly credential is malformed'

kubectl create serviceaccount "$probe" -n database >/dev/null
kubectl label serviceaccount "$probe" -n database acceptance.monosense.io/run="$probe" >/dev/null
kubectl create secret generic "$probe" -n database \
    --from-file=ca.crt="$work/ca.crt" --from-literal=password="$password" >/dev/null
kubectl label secret "$probe" -n database acceptance.monosense.io/run="$probe" >/dev/null
unset password
cat <<YAML | kubectl apply -f - >/dev/null
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: $probe
  namespace: database
  labels: { acceptance.monosense.io/run: $probe }
spec:
  endpointSelector:
    matchLabels:
      k8s:io.kubernetes.pod.namespace: database
      k8s:io.kubernetes.serviceaccount.name: $probe
  egress:
    - toEndpoints:
        - matchLabels:
            k8s:io.kubernetes.pod.namespace: database
            k8s:dragonfly.dragonflydb.io/name: dragonfly
      toPorts:
        - ports: [{ port: "6379", protocol: TCP }]
---
apiVersion: v1
kind: Pod
metadata:
  name: $probe
  namespace: database
  labels: { acceptance.monosense.io/run: $probe }
spec:
  serviceAccountName: $probe
  automountServiceAccountToken: false
  restartPolicy: Never
  containers:
    - name: redis-cli
      image: ghcr.io/dragonflydb/dragonfly:v1.40.1@sha256:ebf3c6c213e82fb51b4521660cca13f06f3421dc5b1ed14f2f474c50b5e29986
      command: [/bin/sh, -ec]
      args: ["sleep 3600"]
      env:
        - name: REDISCLI_AUTH
          valueFrom: { secretKeyRef: { name: $probe, key: password } }
      volumeMounts:
        - { name: ca, mountPath: /run/acceptance, readOnly: true }
      securityContext:
        allowPrivilegeEscalation: false
        capabilities: { drop: [ALL] }
        readOnlyRootFilesystem: true
      resources:
        requests: { cpu: 10m, memory: 16Mi }
        limits: { cpu: 100m, memory: 64Mi }
  volumes:
    - name: ca
      secret: { secretName: $probe, items: [{ key: ca.crt, path: ca.crt }] }
YAML
kubectl wait --for=condition=Ready pod/"$probe" -n database --timeout=2m >/dev/null
redis=(kubectl exec -n database "$probe" -- redis-cli --tls --cacert /run/acceptance/ca.crt -h dragonfly-internal -p 6379 --user forgejo-a --no-auth-warning)
"${redis[@]}" SET "forgejo:$probe" preserved EX 600 | grep -qx OK
[[ "$("${redis[@]}" GET "forgejo:$probe")" == preserved ]] || fail 'Dragonfly TLS write/read failed'
if "${redis[@]}" SET "keycloak:$probe" denied >/dev/null 2>&1; then
    fail 'Forgejo ACL can write outside its exact prefix'
fi
if kubectl exec -n database "$probe" -- redis-cli --tls --cacert /run/acceptance/ca.crt \
    -h dragonfly-internal -p 6379 PING >/dev/null 2>&1; then
    fail 'Dragonfly default user accepts unauthenticated commands'
fi

ssh c1 sudo python3 - <<'PY'
import re, socket, ssl
from pathlib import Path
config = Path('/srv/applications/apps/forgejo/secrets/app.ini').read_text()
match = re.search(r'rediss://forgejo-a:([0-9a-f]{64})@dragonfly\.internal:6379/', config)
if not match:
    raise SystemExit('protected Forgejo Dragonfly URI is absent or malformed')
context = ssl.create_default_context(cafile='/srv/applications/apps/forgejo/secrets/kubernetes-ca.crt')
def exchange(parts):
    wire = f'*{len(parts)}\r\n'.encode() + b''.join(
        f'${len(part)}\r\n{part}\r\n'.encode() for part in parts
    )
    with socket.create_connection(('dragonfly.internal', 6379), timeout=5) as raw:
        with context.wrap_socket(raw, server_hostname='dragonfly.internal') as tls:
            tls.sendall(wire)
            return tls.recv(4096)
if not exchange(['PING']).startswith(b'-NOAUTH'):
    raise SystemExit('c1 unauthenticated Dragonfly access was not denied')
if not exchange(['AUTH', 'forgejo-a', match.group(1)]).startswith(b'+OK'):
    raise SystemExit('c1 TLS+ACL authentication failed')
PY

old_endpoint="$(kubectl get endpointslice -n database -l kubernetes.io/service-name=dragonfly-internal -o json | jq -r '[.items[].endpoints[] | select(.conditions.ready == true) | .addresses[]] | unique | .[0]')"
primary_pod="$(kubectl get pods -n database -l dragonfly.dragonflydb.io/name=dragonfly -o json | jq -r --arg ip "$old_endpoint" '.items[] | select(.status.podIP == $ip) | .metadata.name')"
[[ -n "$primary_pod" ]] || fail 'cannot bind Dragonfly VIP endpoint to its primary pod'
kubectl delete pod "$primary_pod" -n database --wait=false >/dev/null
for _ in $(seq 1 60); do
    new_endpoint="$(kubectl get endpointslice -n database -l kubernetes.io/service-name=dragonfly-internal -o json 2>/dev/null | jq -r '[.items[].endpoints[] | select(.conditions.ready == true) | .addresses[]] | unique | .[0] // empty')"
    [[ -n "$new_endpoint" && "$new_endpoint" != "$old_endpoint" ]] && break
    sleep 2
done
[[ -n "${new_endpoint:-}" && "$new_endpoint" != "$old_endpoint" ]] \
    || fail 'Dragonfly primary did not promote behind the stable VIP'
kubectl wait --for=condition=Ready pod -n database -l dragonfly.dragonflydb.io/name=dragonfly --timeout=5m >/dev/null
[[ "$(kubectl get pods -n database -l dragonfly.dragonflydb.io/name=dragonfly -o json | jq '[.items[] | select(.status.phase == "Running")] | length')" == 3 ]] \
    || fail 'Dragonfly replacement replica did not resynchronize'
[[ "$("${redis[@]}" GET "forgejo:$probe")" == preserved ]] || fail 'Dragonfly state was lost during promotion'

args="$(kubectl get dragonfly dragonfly -n database -o json | jq -r '.spec.args | join(" ")')"
[[ "$args" == *'--cache_mode=false'* && "$args" == *'--maxmemory=4Gi'* ]] \
    || fail 'Dragonfly no-eviction memory bound is absent'
for pod in $(kubectl get pods -n database -l dragonfly.dragonflydb.io/name=dragonfly -o name); do
    kubectl exec -n database "$pod" -- /bin/sh -ec \
        'find /data -type f \( -name "*.dfs" -o -name "dump*.rdb" \) -size +0c -print -quit | grep -q .' \
        && snapshot_found=true && break
done
[[ "${snapshot_found:-false}" == true ]] || fail 'no non-empty hourly Dragonfly snapshot is present'
kubectl get backups -A -o json | jq -e '[.items[] | select(.metadata.labels["backup.monosense.io/source-namespace"] == "database") | select(.status.phase == "Completed" or .status.conditions[]?.type == "Ready")] | length > 0' >/dev/null \
    || fail 'no completed checksum-verified database PVC backup is visible'
printf 'Dragonfly TLS, ACL, c1 access, promotion, resync, no-eviction configuration, snapshot, and backup acceptance passed\n'
