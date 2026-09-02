#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_dir"
[[ $# -eq 0 ]] || { echo "rotate-vector-srx-certificate accepts no arguments" >&2; exit 2; }
[[ -n "${BAO_TOKEN:-}" && -n "${OPENBAO_RUNTIME_DIR:-}" ]] || {
    echo "run only through scripts/with-openbao-runtime.sh" >&2
    exit 1
}
[[ -d "$OPENBAO_RUNTIME_DIR" && ! -L "$OPENBAO_RUNTIME_DIR" ]] || exit 1
for tool in bao jq openssl python3 sops; do
    command -v "$tool" >/dev/null 2>&1 || { echo "missing locked executable: $tool" >&2; exit 1; }
done

ca_source="docker/c0/monitoring/encrypted/vector-srx-ca.yaml"
ca_certificate="ansible/junos/files/vector-srx-root-ca.pem"
[[ -f "$ca_source" && ! -L "$ca_source" && -f "$ca_certificate" && ! -L "$ca_certificate" ]] || {
    echo "Vector SRX CA sources are missing or unsafe" >&2
    exit 1
}

runtime="$OPENBAO_RUNTIME_DIR/vector-srx-certificate"
[[ ! -e "$runtime" ]] || { echo "protected Vector certificate runtime already exists" >&2; exit 1; }
mkdir -m 0700 "$runtime"
cleanup() {
    local status=$?
    chmod -R u=rwX,go= "$runtime" 2>/dev/null || true
    rm -rf -- "$runtime"
    exit "$status"
}
trap cleanup EXIT HUP INT TERM

sops decrypt --extract '["private_key"]' "$ca_source" > "$runtime/ca-key.pem"
cp "$ca_certificate" "$runtime/ca.pem"
chmod 0600 "$runtime/ca-key.pem" "$runtime/ca.pem"
openssl pkey -in "$runtime/ca-key.pem" -pubout -out "$runtime/ca-key-public.pem" >/dev/null 2>&1
openssl x509 -in "$runtime/ca.pem" -pubkey -noout > "$runtime/ca-certificate-public.pem"
cmp "$runtime/ca-key-public.pem" "$runtime/ca-certificate-public.pem" >/dev/null || {
    echo "encrypted Vector CA key does not match the tracked CA certificate" >&2
    exit 1
}
openssl verify -CAfile "$runtime/ca.pem" "$runtime/ca.pem" >/dev/null

openssl req -new -newkey rsa:2048 -sha256 -nodes \
    -subj '/CN=10.25.13.37' \
    -keyout "$runtime/leaf-key.pem" -out "$runtime/leaf.csr" >/dev/null 2>&1
cat > "$runtime/leaf.ext" <<'EOF'
authorityKeyIdentifier=keyid,issuer
basicConstraints=critical,CA:FALSE
keyUsage=critical,digitalSignature,keyEncipherment
extendedKeyUsage=serverAuth
subjectAltName=IP:10.25.13.37,DNS:vector-srx.monosense.internal
EOF
serial_hex="$(openssl rand -hex 16)"
openssl x509 -req -in "$runtime/leaf.csr" -CA "$runtime/ca.pem" -CAkey "$runtime/ca-key.pem" \
    -set_serial "0x$serial_hex" -days 397 -sha256 -extfile "$runtime/leaf.ext" \
    -out "$runtime/leaf.pem" >/dev/null 2>&1
cat "$runtime/leaf.pem" "$runtime/ca.pem" > "$runtime/fullchain.pem"
chmod 0600 "$runtime/leaf-key.pem" "$runtime/leaf.pem" "$runtime/fullchain.pem"
openssl verify -CAfile "$runtime/ca.pem" "$runtime/leaf.pem" >/dev/null
openssl x509 -in "$runtime/leaf.pem" -noout -checkip 10.25.13.37 >/dev/null
openssl x509 -in "$runtime/leaf.pem" -noout -purpose | grep -F 'SSL server : Yes' >/dev/null
openssl x509 -in "$runtime/leaf.pem" -noout -checkend 33696000 >/dev/null

bao kv get -mount=kv -format=json docker/c0/monitoring > "$runtime/current.json"
chmod 0600 "$runtime/current.json"
jq -e '
  def base: ["backup_heartbeat_token", "telegram_bot_token", "telegram_chat_id"];
  def tls: ["vector_tls_certificate", "vector_tls_fullchain", "vector_tls_not_after",
            "vector_tls_private_key", "vector_tls_serial"];
  def client: ["vector_client_ca", "vector_client_certificate", "vector_client_expiration",
               "vector_client_private_key", "vector_client_serial"];
  (.data.data | keys) as $keys |
  (base - $keys | length) == 0 and
  ($keys - (base + tls + client) | length) == 0 and
  ((tls - $keys | length) == 0 or (tls - $keys | length) == (tls | length)) and
  ((client - $keys | length) == 0 or (client - $keys | length) == (client | length))
' "$runtime/current.json" >/dev/null || {
    echo "monitoring record differs from the exact staged Vector contracts" >&2
    exit 1
}
version="$(jq -er '.data.metadata.version | select(type == "number" and . > 0)' "$runtime/current.json")"
serial="$(openssl x509 -in "$runtime/leaf.pem" -noout -serial | cut -d= -f2 | tr '[:upper:]' '[:lower:]')"
not_after="$(openssl x509 -in "$runtime/leaf.pem" -noout -enddate | cut -d= -f2-)"
python3 - "$runtime" "$version" "$serial" "$not_after" <<'PY'
import json
import pathlib
import sys

runtime = pathlib.Path(sys.argv[1])
payload = {
    "data": {
        "vector_tls_certificate": (runtime / "leaf.pem").read_text(),
        "vector_tls_fullchain": (runtime / "fullchain.pem").read_text(),
        "vector_tls_private_key": (runtime / "leaf-key.pem").read_text(),
        "vector_tls_serial": sys.argv[3],
        "vector_tls_not_after": sys.argv[4],
    },
    "options": {"cas": int(sys.argv[2])},
}
(runtime / "payload.json").write_text(json.dumps(payload, separators=(",", ":")))
PY
chmod 0600 "$runtime/payload.json"
bao patch kv/data/docker/c0/monitoring - < "$runtime/payload.json" >/dev/null
bao kv get -mount=kv -format=json docker/c0/monitoring > "$runtime/verified.json"
jq -e --arg serial "$serial" --arg not_after "$not_after" --argjson version "$((version + 1))" '
  def base: ["backup_heartbeat_token", "telegram_bot_token", "telegram_chat_id"];
  def tls: ["vector_tls_certificate", "vector_tls_fullchain", "vector_tls_not_after",
            "vector_tls_private_key", "vector_tls_serial"];
  def client: ["vector_client_ca", "vector_client_certificate", "vector_client_expiration",
               "vector_client_private_key", "vector_client_serial"];
  (.data.data | keys) as $keys |
  .data.metadata.version == $version and
  .data.data.vector_tls_serial == $serial and
  .data.data.vector_tls_not_after == $not_after and
  (base - $keys | length) == 0 and (tls - $keys | length) == 0 and
  ($keys - (base + tls + client) | length) == 0 and
  ((client - $keys | length) == 0 or (client - $keys | length) == (client | length))
' "$runtime/verified.json" >/dev/null
printf '%s\n' 'Dedicated Vector SRX certificate rotated with strict IP identity'
