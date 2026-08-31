#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_dir"
[[ $# -eq 0 ]] || { echo "normalize-forgejo-jwt-secrets accepts no arguments" >&2; exit 2; }
[[ -n "${BAO_TOKEN:-}" && -n "${OPENBAO_RUNTIME_DIR:-}" ]] || {
    echo "run only through scripts/with-openbao-runtime.sh" >&2
    exit 1
}
for tool in bao jq python3; do
    command -v "$tool" >/dev/null 2>&1 || { echo "missing locked executable: $tool" >&2; exit 1; }
done

runtime="$OPENBAO_RUNTIME_DIR/forgejo-jwt-normalization"
[[ ! -e "$runtime" ]] || { echo "protected Forgejo JWT runtime already exists" >&2; exit 1; }
mkdir -m 0700 "$runtime"
cleanup() {
    local status=$?
    chmod -R u=rwX,go= "$runtime" 2>/dev/null || true
    rm -rf -- "$runtime"
    exit "$status"
}
trap cleanup EXIT
trap 'exit 130' HUP INT TERM

bao kv get -mount=kv -format=json docker/c1/forgejo > "$runtime/record.json"
chmod 0600 "$runtime/record.json"
jq -e '
  .data.metadata.version > 0 and
  (.data.data | keys | sort) == (["admin_email","admin_password","forgejo_internal_token","forgejo_jwt_secret","forgejo_lfs_jwt_secret","forgejo_secret_key","kopia_repository_password","librefs_access_key","librefs_secret_key","postgres_password","zoho_password","zoho_username"] | sort) and
  (.data.data | values | all(type == "string" and length > 0))
' "$runtime/record.json" >/dev/null

python3 - "$runtime/record.json" "$runtime/normalized.json" <<'PY'
import base64
import json
import re
import sys

source, destination = sys.argv[1:]
record = json.load(open(source, encoding="utf-8"))
normalized = {}
for key in ("forgejo_jwt_secret", "forgejo_lfs_jwt_secret"):
    value = record["data"]["data"][key]
    if re.fullmatch(r"[0-9a-f]{64}", value):
        value = base64.b64encode(bytes.fromhex(value)).decode("ascii")
    try:
        decoded = base64.b64decode(value, validate=True)
    except Exception as error:
        raise SystemExit(f"{key} is neither legacy hex nor valid base64: {error}")
    if len(decoded) != 32:
        raise SystemExit(f"{key} does not encode exactly 32 bytes")
    normalized[key] = value
json.dump(normalized, open(destination, "w", encoding="utf-8"), separators=(",", ":"))
PY
chmod 0600 "$runtime/normalized.json"
version="$(jq -er '.data.metadata.version' "$runtime/record.json")"
if jq -e --slurpfile normalized "$runtime/normalized.json" '
  .data.data.forgejo_jwt_secret == $normalized[0].forgejo_jwt_secret and
  .data.data.forgejo_lfs_jwt_secret == $normalized[0].forgejo_lfs_jwt_secret
' "$runtime/record.json" >/dev/null; then
    echo "Forgejo JWT secrets already normalized"
    exit 0
fi
jq -cn --slurpfile normalized "$runtime/normalized.json" --argjson cas "$version" \
    '{data:$normalized[0],options:{cas:$cas}}' > "$runtime/patch.json"
chmod 0600 "$runtime/patch.json"
bao patch kv/data/docker/c1/forgejo - < "$runtime/patch.json" >/dev/null
bao kv get -mount=kv -format=json docker/c1/forgejo > "$runtime/verified.json"
jq -e --slurpfile normalized "$runtime/normalized.json" --argjson version "$((version + 1))" '
  .data.metadata.version == $version and
  .data.data.forgejo_jwt_secret == $normalized[0].forgejo_jwt_secret and
  .data.data.forgejo_lfs_jwt_secret == $normalized[0].forgejo_lfs_jwt_secret
' "$runtime/verified.json" >/dev/null
printf '%s\n' 'Forgejo JWT secrets normalized with CAS'
