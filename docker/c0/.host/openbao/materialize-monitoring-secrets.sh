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
tls_root = target_root.parent / "vector-tls"
template_root = pathlib.Path(sys.argv[3])
record = json.loads(payload.read_text(encoding="utf-8"))["data"]["data"]
expected = {
    "telegram_bot_token", "telegram_chat_id", "vector_ingest_token",
    "backup_heartbeat_token", "vector_tls_certificate", "vector_tls_fullchain",
    "vector_tls_private_key", "vector_tls_serial", "vector_tls_not_after",
}
if set(record) != expected:
    raise SystemExit("monitoring secret keys differ from the exact contract")
for key in ("telegram_bot_token", "telegram_chat_id", "vector_ingest_token", "backup_heartbeat_token"):
    value = record[key]
    if not isinstance(value, str) or not value or re.search(r"[\r\n]", value):
        raise SystemExit(f"monitoring secret value is unsafe for configuration materialization: {key}")
if not record["vector_tls_fullchain"].startswith("-----BEGIN CERTIFICATE-----\n"):
    raise SystemExit("Vector TLS full chain is not PEM")
if not record["vector_tls_private_key"].startswith("-----BEGIN PRIVATE KEY-----\n"):
    raise SystemExit("Vector TLS private key is not PEM")
tls_root.mkdir(mode=0o700, parents=True, exist_ok=True)
os.chown(tls_root, 65534, 65534)
os.chmod(tls_root, 0o700)

def render(name):
    text = (template_root / f"{name}.template").read_text(encoding="utf-8")
    for key in ("telegram_bot_token", "telegram_chat_id", "vector_ingest_token", "backup_heartbeat_token"):
        text = text.replace(f"@@{key}@@", record[key])
    unresolved = sorted(set(re.findall(r"@@([a-z0-9_]+)@@", text)))
    if unresolved:
        raise SystemExit(f"unresolved monitoring template fields: {', '.join(unresolved)}")
    return text

def install(root, name, content):
    target = root / name
    if target.is_symlink() or root.is_symlink():
        raise SystemExit(f"unsafe monitoring secret path: {target}")
    descriptor, temporary = tempfile.mkstemp(prefix=f".{name}.", dir=root, text=True)
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
        directory = os.open(root, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0))
        try:
            os.fsync(directory)
        finally:
            os.close(directory)
    finally:
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass

install(target_root, "gatus.yaml", render("gatus.yaml"))
install(target_root, "vector.yaml", render("vector.yaml"))
install(tls_root, "fullchain.pem", record["vector_tls_fullchain"])
install(tls_root, "privkey.pem", record["vector_tls_private_key"])
PY
printf '%s\n' 'c0 monitoring secrets materialized into protected configuration files'
