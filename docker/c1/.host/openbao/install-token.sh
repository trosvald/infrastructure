#!/usr/bin/env bash
set -euo pipefail
umask 077
readonly DESTINATION="${TOKEN_FILE:-/opt/doco-cd/secrets/openbao-token}"
readonly TTL_GATE="${TTL_GATE:-/usr/local/sbin/check-c1-openbao-token}"
readonly CONTROLLER_GATE="${CONTROLLER_GATE:-/usr/local/sbin/check-c1-doco-controller}"
readonly SYSTEMCTL_BIN="${SYSTEMCTL_BIN:-systemctl}" SERVICE="${SERVICE:-doco-cd-c1.service}"
[[ "$(id -u)" == 0 ]] || { printf 'ERROR: token installation requires root\n' >&2; exit 1; }
[[ ! -L "$DESTINATION" ]] || { printf 'ERROR: refusing symlink token destination\n' >&2; exit 1; }
install -d -o root -g root -m 0700 "$(dirname "$DESTINATION")"
backup="$(mktemp "$(dirname "$DESTINATION")/.openbao-token.previous.XXXXXX")"
trap 'rm -f "$backup"' EXIT
had_previous=false
if [[ -f "$DESTINATION" ]]; then
    cp --preserve=mode,ownership,timestamps "$DESTINATION" "$backup"
    had_previous=true
    "$SYSTEMCTL_BIN" is-active --quiet "$SERVICE" \
        || { printf 'ERROR: refusing token rotation while Doco service is inactive\n' >&2; exit 1; }
fi
write_token() {
    python3 -c '
import os,sys,tempfile
destination=sys.argv[1]
raw=sys.stdin.buffer.read()
if raw.endswith(b"\n"): raw=raw[:-1]
if not raw or b"\n" in raw or b"\r" in raw or any(chr(x).isspace() for x in raw): raise SystemExit("invalid token input")
fd,tmp=tempfile.mkstemp(prefix=".openbao-token.new.",dir=os.path.dirname(destination))
try:
 os.fchmod(fd,0o600); os.write(fd,raw+b"\n"); os.fsync(fd); os.close(fd); os.chown(tmp,0,0); os.replace(tmp,destination)
 dfd=os.open(os.path.dirname(destination),os.O_DIRECTORY); os.fsync(dfd); os.close(dfd)
except BaseException:
 try: os.close(fd)
 except OSError: pass
 try: os.unlink(tmp)
 except OSError: pass
 raise
' "$DESTINATION"
}
if [[ -t 0 ]]; then
    IFS= read -r -s -p 'OpenBao c1 token: ' token
    printf '\n' >&2
    printf '%s' "$token" | write_token
    unset token
else
    write_token
fi
if ! "$TTL_GATE"; then
    failed=true
elif [[ "$had_previous" == true ]] \
     && { ! "$SYSTEMCTL_BIN" restart "$SERVICE" || ! env REQUIRE_PROVIDER_CANARY=true "$CONTROLLER_GATE"; }; then
    failed=true
else
    failed=false
fi
if [[ "$failed" == true ]]; then
    if [[ "$had_previous" == true ]]; then
        install -o root -g root -m 0600 "$backup" "$DESTINATION"
        "$SYSTEMCTL_BIN" restart "$SERVICE" >/dev/null 2>&1 || true
    else
        rm -f "$DESTINATION"
    fi
    printf 'ERROR: replacement-token host or controller verification failed; prior state restored\n' >&2
    exit 1
fi
if [[ "$had_previous" == true ]]; then
    printf 'OpenBao c1 token installed; Doco service and provider canary passed\n'
else
    printf 'Initial OpenBao c1 token installed; host TTL gate passed\n'
fi
