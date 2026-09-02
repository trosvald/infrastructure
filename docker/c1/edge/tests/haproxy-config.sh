#!/usr/bin/env bash
set -euo pipefail
readonly ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
readonly IMAGE="docker.io/library/haproxy:3.2.23-alpine@sha256:0666a2c2f41d341084ed2da85392b48cdcd766adfa28231f31305724ed5c6ea5"
tmp="$(mktemp -d)"
chmod 0755 "$tmp"
container="edge-haproxy-validation-$$"
cleanup() {
    docker rm --force "$container" >/dev/null 2>&1 || true
    rm -rf "$tmp"
}
trap cleanup EXIT HUP INT TERM
openssl req -x509 -newkey rsa:2048 -nodes -days 2 \
    -subj /CN=git.monosense.io \
    -addext 'subjectAltName=DNS:git.monosense.io' \
    -keyout "$tmp/key.pem" -out "$tmp/cert.pem" >/dev/null 2>&1
cat "$tmp/cert.pem" "$tmp/key.pem" >"$tmp/combined.pem"
cp "$tmp/cert.pem" "$tmp/kubernetes-ca.pem"
printf '%s\n' '/run/tls/combined.pem git.monosense.io edge-acceptance.monosense.io' >"$tmp/crt-list.txt"
chmod 0644 "$tmp/combined.pem" "$tmp/crt-list.txt" "$tmp/kubernetes-ca.pem"
docker run --rm --platform linux/amd64 --network none \
    --read-only --cap-drop ALL --security-opt no-new-privileges:true \
    --add-host forgejo-c1:127.0.0.1 --add-host crowdsec-spoa-c1:127.0.0.1 \
    --env SPOA_BYPASS=1 \
    --mount "type=bind,src=$ROOT/docker/c1/edge/config/haproxy.cfg,dst=/usr/local/etc/haproxy/haproxy.cfg,readonly" \
    --mount "type=bind,src=$tmp/crt-list.txt,dst=/usr/local/etc/haproxy/crt-list.txt,readonly" \
    --mount "type=bind,src=$tmp,dst=/run/tls,readonly" \
    "$IMAGE" haproxy -c -f /usr/local/etc/haproxy/haproxy.cfg
docker run --detach --name "$container" --platform linux/amd64 \
    --publish 127.0.0.1::443 --read-only --user 99:99 \
    --cap-drop ALL --cap-add NET_BIND_SERVICE --security-opt no-new-privileges:true \
    --add-host forgejo-c1:127.0.0.1 --add-host crowdsec-spoa-c1:127.0.0.1 \
    --tmpfs /run/haproxy:rw,nosuid,nodev,noexec,size=16m,mode=0750,uid=99,gid=99 \
    --env SPOA_BYPASS=1 \
    --mount "type=bind,src=$ROOT/docker/c1/edge/config/haproxy.cfg,dst=/usr/local/etc/haproxy/haproxy.cfg,readonly" \
    --mount "type=bind,src=$tmp/crt-list.txt,dst=/usr/local/etc/haproxy/crt-list.txt,readonly" \
    --mount "type=bind,src=$tmp,dst=/run/tls,readonly" \
    "$IMAGE" >/dev/null
port="$(docker port "$container" 443/tcp | sed 's/.*://')"
for _ in $(seq 1 20); do
    openssl s_client -connect "127.0.0.1:$port" -servername git.monosense.io \
        </dev/null >/dev/null 2>&1 && break
    sleep 0.25
done
openssl s_client -connect "127.0.0.1:$port" -servername git.monosense.io \
    </dev/null 2>/dev/null | openssl x509 -noout -checkhost git.monosense.io >/dev/null
if openssl s_client -connect "127.0.0.1:$port" -servername unlisted.monosense.io \
    </dev/null >/dev/null 2>&1; then
    printf '%s\n' 'unlisted SNI unexpectedly completed a TLS handshake' >&2
    exit 1
fi
if openssl s_client -connect "127.0.0.1:$port" </dev/null >/dev/null 2>&1; then
    printf '%s\n' 'missing SNI unexpectedly completed a TLS handshake' >&2
    exit 1
fi
