#!/usr/bin/env bash
set -euo pipefail

BAO_BIN="${BAO_BIN:-bao}"
TARGET="${TARGET:-/var/lib/monosense-monitoring/monitoring.env}"
[[ "$(id -u)" == 0 ]] || { printf '%s\n' 'monitoring secret materialization requires root' >&2; exit 1; }
install -d -o root -g root -m 0700 "$(dirname "$TARGET")"
payload="$(mktemp)"
trap 'rm -f "$payload"' EXIT HUP INT TERM
chmod 0600 "$payload"
"$BAO_BIN" kv get -format=json kv/docker/c0/monitoring >"$payload"
python3 - "$payload" "$TARGET" <<'PY'
import json
import os
import pathlib
import re
import sys
import tempfile

payload = pathlib.Path(sys.argv[1])
target = pathlib.Path(sys.argv[2])
record = json.loads(payload.read_text(encoding="utf-8"))["data"]["data"]
expected = {"telegram_bot_token", "telegram_chat_id", "vector_ingest_token", "backup_heartbeat_token"}
if set(record) != expected:
    raise SystemExit("monitoring secret keys differ from the exact contract")
for key, value in record.items():
    if not isinstance(value, str) or not value or re.search(r"[\s'\"\\]", value):
        raise SystemExit(f"monitoring secret value is unsafe for env-file materialization: {key}")
rows = (
    f"MONITORING_TELEGRAM_BOT_TOKEN={record['telegram_bot_token']}\n"
    f"MONITORING_TELEGRAM_CHAT_ID={record['telegram_chat_id']}\n"
    f"MONITORING_VECTOR_INGEST_TOKEN={record['vector_ingest_token']}\n"
    f"MONITORING_BACKUP_HEARTBEAT_TOKEN={record['backup_heartbeat_token']}\n"
)
fd, temporary = tempfile.mkstemp(prefix=".monitoring-env-", dir=target.parent, text=True)
try:
    with os.fdopen(fd, "w", encoding="utf-8") as stream:
        stream.write(rows)
        stream.flush()
        os.fsync(stream.fileno())
    os.chmod(temporary, 0o600)
    os.chown(temporary, 0, 0)
    os.replace(temporary, target)
    directory = os.open(target.parent, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0))
    try:
        os.fsync(directory)
    finally:
        os.close(directory)
except BaseException:
    try:
        os.unlink(temporary)
    except FileNotFoundError:
        pass
    raise
PY
printf '%s\n' 'c0 monitoring secrets materialized; Doco recreation remains explicit'
