#!/usr/bin/env bash
set -euo pipefail

readonly HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly RUNTIME_HELPER="${RUNTIME_HELPER:-/usr/local/sbin/haproxy-runtime-c1-forgejo.py}"
readonly STAGING="${STAGING:-/srv/applications/apps/forgejo/staging}"
readonly CURL_BIN="${CURL_BIN:-curl}"
readonly HEARTBEAT_URL="${HEARTBEAT_URL:-https://status.monosense.io/api/v1/endpoints/backups_forgejo-backup/external?success=true}"
readonly HEARTBEAT_TOKEN_FILE="${HEARTBEAT_TOKEN_FILE:-/opt/forgejo/secrets/backup-heartbeat.token}"
readonly LOG_DIR="${LOG_DIR:-/srv/applications/apps/forgejo/logs/backup}"
readonly FORGEJO=forgejo-c1 POSTGRES=forgejo-postgres-c1 KOPIA=kopia-forgejo-c1
readonly generation="$(date -u +%Y%m%dT%H%M%SZ)"
readonly target="$STAGING/$generation"
drained=false
app_stopped=false

fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
restore_backend() {
    if [[ "$app_stopped" == true ]]; then
        docker start "$FORGEJO" >/dev/null 2>&1 || true
    fi
    if [[ "$drained" == true ]]; then
        python3 "$RUNTIME_HELPER" ready >/dev/null 2>&1 || true
    fi
}
trap restore_backend EXIT HUP INT TERM
[[ "$(id -u)" == 0 ]] || fail 'Forgejo backup requires root'
[[ -f "$HEARTBEAT_TOKEN_FILE" && ! -L "$HEARTBEAT_TOKEN_FILE" ]] \
    || fail "backup heartbeat token is missing or unsafe: $HEARTBEAT_TOKEN_FILE"
[[ "$(stat -c '%a:%u:%g' "$HEARTBEAT_TOKEN_FILE")" == 600:0:0 ]] \
    || fail 'backup heartbeat token must be root-owned mode 0600'
for container in "$FORGEJO" "$POSTGRES" "$KOPIA" haproxy-c1; do
    [[ "$(docker inspect "$container" --format '{{.State.Running}}' 2>/dev/null)" == true ]] \
        || fail "required container is not running: $container"
done
install -d -o 1000 -g 1000 -m 0700 "$target"
python3 "$RUNTIME_HELPER" drain
drained=true
sleep 2
docker cp "$FORGEJO:/etc/gitea/app.ini" "$target/app.ini"
chown 1000:1000 "$target/app.ini"
chmod 0600 "$target/app.ini"
docker stop --time 60 "$FORGEJO" >/dev/null
app_stopped=true
readonly forgejo_image="$(docker inspect "$FORGEJO" --format '{{.Config.Image}}')"
docker run --rm --user 1000:1000 --network forgejo-c1-database \
    --volumes-from "$FORGEJO" --tmpfs /tmp:rw,nosuid,nodev,noexec,size=256m \
    --mount "type=bind,source=$target,target=/staging/$generation" \
    --entrypoint forgejo "$forgejo_image" dump --config "/staging/$generation/app.ini" \
    --file "/staging/$generation/forgejo-dump.zip" --tempdir /tmp
rm -f "$target/app.ini"
docker exec "$POSTGRES" pg_dump --format=custom --no-owner --no-privileges \
    --username forgejo --dbname forgejo >"$target/postgres.dump"
chmod 0600 "$target/postgres.dump"
chown 1000:1000 "$target/postgres.dump"
docker start "$FORGEJO" >/dev/null
app_stopped=false
(
    cd "$target"
    sha256sum forgejo-dump.zip postgres.dump >SHA256SUMS
)
chmod 0600 "$target/SHA256SUMS"
chown 1000:1000 "$target/SHA256SUMS"
for _ in $(seq 1 60); do
    [[ "$(docker inspect "$FORGEJO" --format '{{.State.Health.Status}}')" == healthy ]] && break
    sleep 1
done
[[ "$(docker inspect "$FORGEJO" --format '{{.State.Health.Status}}')" == healthy ]] \
    || fail 'Forgejo did not return healthy after backup'
python3 "$RUNTIME_HELPER" ready
drained=false
repository_script='export KOPIA_PASSWORD="$(cat /run/secrets/kopia_password)" AWS_ACCESS_KEY_ID="$(cat /run/secrets/librefs_access_key)" AWS_SECRET_ACCESS_KEY="$(cat /run/secrets/librefs_secret_key)"; kopia repository status >/dev/null 2>&1 || kopia repository connect s3 --bucket=forgejo-backups --endpoint=s3.monosense.io; kopia policy set --global --keep-daily=30 --keep-monthly=12 >/dev/null; kopia snapshot create "/staging/'"$generation"'"; kopia snapshot verify --verify-files-percent=1 --sources="/staging/'"$generation"'"'
docker exec "$KOPIA" sh -ceu "$repository_script"
heartbeat_token="$(tr -d '\n' <"$HEARTBEAT_TOKEN_FILE")"
[[ "$heartbeat_token" =~ ^[A-Za-z0-9_-]{43,}$ ]] || fail 'backup heartbeat token is malformed'
"$CURL_BIN" --fail --silent --show-error --request POST \
    --header "Authorization: Bearer $heartbeat_token" "$HEARTBEAT_URL"
rm -rf --one-file-system "$target"
printf '%s %s\n' "$(date -u +%FT%TZ)" "$generation" >>"$LOG_DIR/last-success.log"
printf '%s\n' "Forgejo backup $generation verified in the local libreFS Kopia repository"
