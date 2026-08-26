#!/usr/bin/env bash
set -euo pipefail
umask 077

readonly DESTINATION="${API_SECRET_FILE:-/opt/doco-cd/secrets/api_secret}"
readonly CONTROLLER_GATE="${CONTROLLER_GATE:-/usr/local/sbin/check-c1-doco-controller}"
readonly SYSTEMCTL_BIN="${SYSTEMCTL_BIN:-systemctl}" SERVICE="${SERVICE:-doco-cd-c1.service}"

fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
[[ "$(id -u)" == 0 ]] || fail 'API secret installation requires root'
[[ ! -L "$DESTINATION" ]] || fail 'refusing symlink API-secret destination'
install -d -o root -g root -m 0700 "$(dirname "$DESTINATION")"
backup="$(mktemp "$(dirname "$DESTINATION")/.api-secret.previous.XXXXXX")"
trap 'rm -f "$backup"' EXIT
had_previous=false
if [[ -f "$DESTINATION" ]]; then
    cp --preserve=mode,ownership,timestamps "$DESTINATION" "$backup"
    had_previous=true
    "$SYSTEMCTL_BIN" is-active --quiet "$SERVICE" \
        || fail 'refusing API-secret rotation while Doco service is inactive'
fi
python3 -c '
import os,re,sys,tempfile
destination=sys.argv[1]
raw=sys.stdin.buffer.read()
if raw.endswith(b"\n"): raw=raw[:-1]
if len(raw)<43 or not re.fullmatch(rb"[A-Za-z0-9_-]+",raw):
 raise SystemExit("API secret must be at least 43 base64url characters")
fd,tmp=tempfile.mkstemp(prefix=".api-secret.new.",dir=os.path.dirname(destination))
try:
 os.fchmod(fd,0o600)
 os.write(fd,raw+b"\n")
 os.fsync(fd)
 os.close(fd)
 os.chown(tmp,0,0)
 os.replace(tmp,destination)
 dfd=os.open(os.path.dirname(destination),os.O_DIRECTORY)
 os.fsync(dfd)
 os.close(dfd)
except BaseException:
 try: os.close(fd)
 except OSError: pass
 try: os.unlink(tmp)
 except OSError: pass
 raise
' "$DESTINATION"
if [[ "$had_previous" == true ]] \
   && { ! "$SYSTEMCTL_BIN" restart "$SERVICE" || ! env REQUIRE_PROVIDER_CANARY=true "$CONTROLLER_GATE"; }; then
    install -o root -g root -m 0600 "$backup" "$DESTINATION"
    "$SYSTEMCTL_BIN" restart "$SERVICE" >/dev/null 2>&1 || true
    fail 'new API secret failed controller canary; prior value restored'
fi
if [[ "$had_previous" == true ]]; then
    printf 'Doco API secret installed; controller provider canary passed\n'
else
    printf 'Initial Doco API secret installed; controller remains stopped\n'
fi
