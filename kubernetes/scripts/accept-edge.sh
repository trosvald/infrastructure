#!/usr/bin/env bash
set -euo pipefail

namespace=edge-acceptance
host=edge-acceptance.monosense.io
image='ghcr.io/mendhak/http-https-echo:41@sha256:2046be25f4a2c0bdda662ebfb7c2b7b60fc95c31d97987be143645a8a2194a40'
for tool in curl jq kubectl python; do
    command -v "$tool" >/dev/null 2>&1 || { echo "missing locked tool: $tool" >&2; exit 1; }
done
cleanup() {
    kubectl -n networking delete httproute edge-acceptance --ignore-not-found --wait=false >/dev/null 2>&1 || true
    kubectl delete namespace "$namespace" --ignore-not-found --wait=false >/dev/null 2>&1 || true
}
trap cleanup EXIT HUP INT TERM
cleanup

cat <<YAML | kubectl apply -f - >/dev/null
apiVersion: v1
kind: Namespace
metadata:
  name: $namespace
  labels: { pod-security.kubernetes.io/enforce: restricted }
---
apiVersion: apps/v1
kind: Deployment
metadata: { name: echo, namespace: $namespace }
spec:
  replicas: 1
  selector: { matchLabels: { app: edge-acceptance } }
  template:
    metadata: { labels: { app: edge-acceptance } }
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
  selector: { app: edge-acceptance }
  ports: [{ name: http, port: 8080, targetPort: http }]
---
apiVersion: gateway.networking.k8s.io/v1beta1
kind: ReferenceGrant
metadata: { name: networking-edge-route, namespace: $namespace }
spec:
  from: [{ group: gateway.networking.k8s.io, kind: HTTPRoute, namespace: networking }]
  to: [{ group: "", kind: Service, name: echo }]
---
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata: { name: echo-from-envoy-edge, namespace: $namespace }
spec:
  endpointSelector: { matchLabels: { app: edge-acceptance } }
  ingress:
    - fromEndpoints:
        - matchLabels:
            k8s:io.kubernetes.pod.namespace: networking
            k8s:io.cilium.k8s.policy.serviceaccount: envoy-edge
      toPorts:
        - ports: [{ port: "8080", protocol: TCP }]
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata: { name: edge-acceptance, namespace: networking }
spec:
  hostnames: [$host]
  parentRefs: [{ name: envoy-edge, sectionName: https }]
  rules:
    - backendRefs: [{ name: echo, namespace: $namespace, port: 8080 }]
YAML
kubectl -n "$namespace" rollout status deployment/echo --timeout=5m >/dev/null
for _ in $(seq 1 60); do
    route="$(kubectl -n networking get httproute edge-acceptance -o json)"
    if jq -e '.status.parents | length == 1 and .[0].conditions | any(.type == "Accepted" and .status == "True") and any(.type == "ResolvedRefs" and .status == "True")' <<<"$route" >/dev/null; then
        break
    fi
    sleep 2
done
jq -e '.status.parents | length == 1 and .[0].conditions | any(.type == "Accepted" and .status == "True") and any(.type == "ResolvedRefs" and .status == "True")' <<<"$route" >/dev/null

response="$(mktemp)"
trap 'rm -f "$response"; cleanup' EXIT HUP INT TERM
curl --fail --silent --show-error --max-time 20 \
    --header 'X-Forwarded-For: 198.51.100.200' \
    --header 'Forwarded: for=198.51.100.200;proto=http' \
    --header 'X-Real-IP: 198.51.100.200' \
    "https://$host/acceptance" >"$response"
jq -e '
  ([.. | objects | .["x-forwarded-for"]? // empty] | length == 1 and all(.[]; contains("198.51.100.200") | not)) and
  ([.. | objects | .["x-forwarded-proto"]? // empty] == ["https"]) and
  ([.. | objects | .["x-forwarded-host"]? // empty] == ["edge-acceptance.monosense.io"]) and
  ([.. | objects | .["x-request-id"]? // empty] | length == 1)
' "$response" >/dev/null

public_ip="$(python - "$host" <<'PY'
import socket, sys
addresses = sorted({row[4][0] for row in socket.getaddrinfo(sys.argv[1], 443, socket.AF_INET, socket.SOCK_STREAM)})
if len(addresses) != 1:
    raise SystemExit("acceptance hostname must resolve to exactly one public IPv4 address")
print(addresses[0])
PY
)"
status="$(curl --silent --output /dev/null --write-out '%{http_code}' --max-time 20 \
    --resolve "unknown-edge-acceptance.monosense.io:443:$public_ip" \
    https://unknown-edge-acceptance.monosense.io/ || true)"
[[ "$status" == 000 || "$status" == 421 ]] || { echo "unknown edge host was not rejected: HTTP $status" >&2; exit 1; }

cat <<YAML | kubectl apply -f - >/dev/null
apiVersion: v1
kind: Pod
metadata: { name: direct-denial, namespace: $namespace }
spec:
  restartPolicy: Never
  securityContext: { runAsNonRoot: true, runAsUser: 99, runAsGroup: 99, seccompProfile: { type: RuntimeDefault } }
  containers:
    - name: probe
      image: docker.io/library/haproxy:3.2.23-alpine@sha256:0666a2c2f41d341084ed2da85392b48cdcd766adfa28231f31305724ed5c6ea5
      command: [/bin/sh, -ceu, 'if wget -T 5 -qO- http://echo:8080/; then exit 1; fi']
      securityContext: { allowPrivilegeEscalation: false, capabilities: { drop: [ALL] } }
YAML
kubectl -n "$namespace" wait --for=jsonpath='{.status.phase}'=Succeeded pod/direct-denial --timeout=2m >/dev/null
python - "$public_ip" <<'PY'
import socket, sys
sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
sock.settimeout(2)
try:
    sock.connect((sys.argv[1], 443))
    sock.send(b"no-udp-443")
    sock.recv(1)
except (ConnectionRefusedError, TimeoutError, socket.timeout):
    pass
else:
    raise SystemExit("public edge unexpectedly answered UDP/443")
finally:
    sock.close()
PY
printf '%s\n' 'Edge acceptance passed: public Host/SNI, verified backend TLS, forwarding-header replacement, exact edge identity, direct-backend denial, unknown-host rejection, and no UDP/443 response'
