#!/usr/bin/env bash
set -euo pipefail

readonly C0_TARGET="monosense@10.25.10.20"
readonly C1_TARGET="monosense@10.25.10.101"
readonly C0_SECRET_ROOT="/var/lib/monosense-monitoring/secrets"
readonly C1_EDGE_SECRET_ROOT="/opt/edge/secrets"
readonly C1_FORGEJO_SECRET_ROOT="/opt/forgejo/secrets"
repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
runtime="$(mktemp -d "${TMPDIR:-/tmp}/edge-runtime.XXXXXX")"
cleanup() {
    local status=$?
    chmod -R u=rwX,go= "$runtime" 2>/dev/null || true
    rm -rf -- "$runtime"
    exit "$status"
}
trap cleanup EXIT HUP INT TERM
chmod 0700 "$runtime"

for tool in bao jq python3 ssh; do
    command -v "$tool" >/dev/null || { printf 'ERROR: missing required tool: %s\n' "$tool" >&2; exit 1; }
done
[[ -n "${BAO_TOKEN:-}" ]] || { printf '%s\n' 'ERROR: authenticated OpenBao runtime is required' >&2; exit 1; }

bao kv get -format=json kv/docker/c1/edge >"$runtime/edge.json"
bao kv get -format=json kv/docker/c1/forgejo >"$runtime/forgejo.json"
bao kv get -format=json kv/docker/c0/monitoring >"$runtime/monitoring.json"
chmod 0600 "$runtime"/*.json

python3 - "$runtime" "$repo_dir" <<'PY'
import json
import os
import pathlib
import re
import sys

runtime = pathlib.Path(sys.argv[1])
repo = pathlib.Path(sys.argv[2])
expected = {
    "edge": {"acme_email", "cloudflare_dns_token", "maxmind_account_id", "maxmind_license_key", "crowdsec_lapi_key", "crowdsec_bouncer_key", "vector_ingest_token"},
    "forgejo": {"postgres_password", "forgejo_secret_key", "forgejo_internal_token", "forgejo_jwt_secret", "forgejo_lfs_jwt_secret", "bootstrap_admin_password", "bootstrap_admin_email", "zoho_username", "zoho_password", "kopia_repository_password", "librefs_access_key", "librefs_secret_key"},
    "monitoring": {"telegram_bot_token", "telegram_chat_id", "vector_ingest_token", "backup_heartbeat_token"},
}
records = {}
for name, keys in expected.items():
    record = json.loads((runtime / f"{name}.json").read_text(encoding="utf-8"))["data"]["data"]
    if set(record) != keys or any(not isinstance(value, str) or not value or "\n" in value or "\r" in value for value in record.values()):
        raise SystemExit(f"{name} record differs from the exact secret contract")
    records[name] = record
if len(records["monitoring"]["backup_heartbeat_token"]) < 43 or re.search(r"[^A-Za-z0-9_-]", records["monitoring"]["backup_heartbeat_token"]):
    raise SystemExit("backup heartbeat token is not base64url text with at least 256 bits")
for name in ("gatus.yaml", "vector.yaml"):
    text = (repo / "docker/c0/monitoring/config" / f"{name}.template").read_text(encoding="utf-8")
    for key, value in records["monitoring"].items():
        text = text.replace(f"@@{key}@@", value)
    if re.search(r"@@[a-z0-9_]+@@", text):
        raise SystemExit(f"unresolved field in {name}")
    path = runtime / name
    path.write_text(text, encoding="utf-8")
    os.chmod(path, 0o600)
(runtime / "backup-heartbeat.token").write_text(records["monitoring"]["backup_heartbeat_token"] + "\n", encoding="utf-8")
os.chmod(runtime / "backup-heartbeat.token", 0o600)
PY

install_remote() {
    local host="$1" destination="$2" uid="$3" gid="$4" mode="$5" source="$6"
    local remote_script remote_command
    remote_script='
        destination=$1 uid=$2 gid=$3 mode=$4
        directory=$(dirname "$destination")
        install -d -o root -g root -m 0755 "$directory"
        temporary=$(mktemp "$directory/.edge-runtime.XXXXXX")
        trap '\''rm -f "$temporary"'\'' EXIT HUP INT TERM
        cat >"$temporary"
        chown "$uid:$gid" "$temporary"
        chmod "$mode" "$temporary"
        sync -f "$temporary"
        mv -f "$temporary" "$destination"
        trap - EXIT HUP INT TERM
    '
    printf -v remote_command '%q ' sudo /bin/sh -ceu "$remote_script" sh \
        "$destination" "$uid" "$gid" "$mode"
    ssh -T "$host" "$remote_command" <"$source"
}

install_token() {
    local role="$1" host="$2" destination="$3" token_file="$runtime/$role.token"
    bao token create -role="$role" -field=token >"$token_file"
    chmod 0600 "$token_file"
    [[ "$(wc -l <"$token_file")" == 1 ]] || { printf 'ERROR: invalid token response for %s\n' "$role" >&2; exit 1; }
    install_remote "$host" "$destination" 0 0 0600 "$token_file"
    rm -f "$token_file"
}

install_token wildcard-publisher "$C1_TARGET" "$C1_EDGE_SECRET_ROOT/wildcard-publisher.token"
install_token wildcard-reader-c1 "$C1_TARGET" "$C1_EDGE_SECRET_ROOT/wildcard-reader-c1.token"
install_token wildcard-reader-c0 "$C0_TARGET" "/opt/monitoring/secrets/wildcard-reader-c0.token"
install_remote "$C0_TARGET" "$C0_SECRET_ROOT/gatus.yaml" 65534 65534 0400 "$runtime/gatus.yaml"
install_remote "$C0_TARGET" "$C0_SECRET_ROOT/vector.yaml" 65534 65534 0400 "$runtime/vector.yaml"
install_remote "$C1_TARGET" "$C1_FORGEJO_SECRET_ROOT/backup-heartbeat.token" 0 0 0600 "$runtime/backup-heartbeat.token"
ssh -T "$C1_TARGET" sudo /usr/local/sbin/materialize-c1-app-secrets
printf '%s\n' 'EDGE runtime tokens and protected c0/c1 application files provisioned'
