#!/usr/bin/env bash
set -euo pipefail
BAO_BIN="${BAO_BIN:-bao}"
TARGET="${TARGET:-/opt/forgejo/secrets/backup-heartbeat.token}"
[[ "$(id -u)" == 0 ]] || { printf '%s\n' 'backup heartbeat token materialization requires root' >&2; exit 1; }
install -d -o root -g root -m 0700 "$(dirname "$TARGET")"
payload="$(mktemp)"
temporary=""
cleanup() { rm -f "$payload" "$temporary"; }
trap cleanup EXIT HUP INT TERM
chmod 0600 "$payload"
"$BAO_BIN" kv get -format=json kv/docker/c0/monitoring >"$payload"
temporary="$(mktemp "$(dirname "$TARGET")/.backup-heartbeat.XXXXXX")"
python3 - "$payload" "$temporary" <<'PY'
import json
import os
import pathlib
import re
import sys
record = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))["data"]["data"]
expected = {"telegram_bot_token", "telegram_chat_id", "vector_ingest_token", "backup_heartbeat_token"}
if set(record) != expected:
    raise SystemExit("monitoring secret keys differ from the exact contract")
token = record["backup_heartbeat_token"]
if not isinstance(token, str) or len(token) < 43 or re.search(r"[^A-Za-z0-9_-]", token):
    raise SystemExit("backup heartbeat token must be at least 256 bits of base64url text")
path = pathlib.Path(sys.argv[2])
path.write_text(token + "\n", encoding="utf-8")
os.chmod(path, 0o600)
with path.open("rb") as stream:
    os.fsync(stream.fileno())
PY
chown root:root "$temporary"
mv -f "$temporary" "$TARGET"
temporary=""
printf '%s\n' 'Forgejo backup heartbeat token materialized; no value printed'
