#!/usr/bin/env bash
set -euo pipefail

BAO_BIN="${BAO_BIN:-bao}"
TARGET_ROOT="${TARGET_ROOT:-/var/lib/monosense-monitoring/secrets}"
TEMPLATE_ROOT="${TEMPLATE_ROOT:-/usr/local/share/monosense-monitoring}"
[[ "$(id -u)" == 0 ]] || { printf '%s\n' 'monitoring secret materialization requires root' >&2; exit 1; }
install -d -o root -g root -m 0755 "$TARGET_ROOT"
payload="$(mktemp)"
trap 'rm -f "$payload"' EXIT HUP INT TERM
chmod 0600 "$payload"
"$BAO_BIN" kv get -format=json kv/docker/c0/monitoring >"$payload"
python3 - "$payload" "$TARGET_ROOT" "$TEMPLATE_ROOT" <<'PY'
import json
import os
import pathlib
import re
import sys
import tempfile

payload = pathlib.Path(sys.argv[1])
target_root = pathlib.Path(sys.argv[2])
template_root = pathlib.Path(sys.argv[3])
record = json.loads(payload.read_text(encoding="utf-8"))["data"]["data"]
expected = {"telegram_bot_token", "telegram_chat_id", "vector_ingest_token", "backup_heartbeat_token"}
if set(record) != expected:
    raise SystemExit("monitoring secret keys differ from the exact contract")
for key, value in record.items():
    if not isinstance(value, str) or not value or re.search(r"[\r\n]", value):
        raise SystemExit(f"monitoring secret value is unsafe for configuration materialization: {key}")

def render(name):
    text = (template_root / f"{name}.template").read_text(encoding="utf-8")
    for key, value in record.items():
        text = text.replace(f"@@{key}@@", value)
    unresolved = sorted(set(re.findall(r"@@([a-z0-9_]+)@@", text)))
    if unresolved:
        raise SystemExit(f"unresolved monitoring template fields: {', '.join(unresolved)}")
    return text

def install(name, content):
    target = target_root / name
    if target.is_symlink() or target_root.is_symlink():
        raise SystemExit(f"unsafe monitoring secret path: {target}")
    descriptor, temporary = tempfile.mkstemp(prefix=f".{name}.", dir=target_root, text=True)
    try:
        os.fchmod(descriptor, 0o400)
        os.fchown(descriptor, 65534, 65534)
        with os.fdopen(descriptor, "w", encoding="utf-8") as stream:
            stream.write(content)
            if not content.endswith("\n"):
                stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, target)
        directory = os.open(target_root, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0))
        try:
            os.fsync(directory)
        finally:
            os.close(directory)
    finally:
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass

install("gatus.yaml", render("gatus.yaml"))
install("vector.yaml", render("vector.yaml"))
PY
printf '%s\n' 'c0 monitoring secrets materialized into protected configuration files'
