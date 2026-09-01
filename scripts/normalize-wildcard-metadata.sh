#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_dir"
[[ $# -eq 0 ]] || { echo "normalize-wildcard-metadata accepts no arguments" >&2; exit 2; }
[[ -n "${BAO_TOKEN:-}" && -n "${OPENBAO_RUNTIME_DIR:-}" ]] || {
    echo "run only through scripts/with-openbao-runtime.sh" >&2
    exit 1
}
for tool in bao jq openssl python3; do
    command -v "$tool" >/dev/null 2>&1 || { echo "missing locked executable: $tool" >&2; exit 1; }
done

runtime="$OPENBAO_RUNTIME_DIR/wildcard-metadata"
[[ ! -e "$runtime" ]] || { echo "protected wildcard metadata runtime already exists" >&2; exit 1; }
mkdir -m 0700 "$runtime"
cleanup() {
    local status=$?
    chmod -R u=rwX,go= "$runtime" 2>/dev/null || true
    rm -rf -- "$runtime"
    exit "$status"
}
trap cleanup EXIT
trap 'exit 130' HUP INT TERM

bao kv get -mount=kv -format=json platform/tls/monosense-wildcard > "$runtime/record.json"
chmod 0600 "$runtime/record.json"
jq -e '
  .data.metadata.version > 0 and
  (.data.data | keys | sort) == ["certificate","fullchain","not_after","private_key","serial"] and
  (.data.data | values | all(type == "string" and length > 0))
' "$runtime/record.json" >/dev/null
jq -er '.data.data.certificate' "$runtime/record.json" > "$runtime/certificate.pem"
chmod 0600 "$runtime/certificate.pem"

raw_serial="$(openssl x509 -in "$runtime/certificate.pem" -noout -serial)"
raw_serial="${raw_serial#*=}"
normalized_serial="$(python3 -c 'import sys; print(format(int(sys.argv[1], 16), "x"))' "$raw_serial")"
record_serial="$(jq -er '.data.data.serial' "$runtime/record.json")"
[[ "$(python3 -c 'import sys; print(format(int(sys.argv[1], 16), "x"))' "$record_serial")" == "$normalized_serial" ]] || {
    echo "wildcard record serial does not identify its certificate" >&2
    exit 1
}

if [[ "$record_serial" == "$normalized_serial" ]]; then
    echo "wildcard metadata already normalized"
    exit 0
fi
version="$(jq -er '.data.metadata.version' "$runtime/record.json")"
jq -cn --arg serial "$normalized_serial" --argjson cas "$version" \
    '{data:{serial:$serial},options:{cas:$cas}}' > "$runtime/patch.json"
chmod 0600 "$runtime/patch.json"
bao patch kv/data/platform/tls/monosense-wildcard - < "$runtime/patch.json" >/dev/null
bao kv get -mount=kv -format=json platform/tls/monosense-wildcard > "$runtime/verified.json"
jq -e --arg serial "$normalized_serial" --argjson version "$((version + 1))" '
  .data.metadata.version == $version and .data.data.serial == $serial
' "$runtime/verified.json" >/dev/null
printf '%s\n' 'wildcard serial metadata normalized with CAS'
