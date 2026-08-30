#!/usr/bin/env bash
set -euo pipefail
readonly ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
: >"$work/tty"
cat >"$work/curl" <<'FAKE'
#!/usr/bin/env bash
set -eu
count=0
[[ ! -f "$CURL_COUNT" ]] || count="$(cat "$CURL_COUNT")"
count=$((count + 1))
printf '%s' "$count" >"$CURL_COUNT"
if [[ "${HEALTH_MODE:-sealed}" == active || "$count" -gt 1 ]]; then printf 200; else printf 503; fi
FAKE
cat >"$work/ssh" <<'FAKE'
#!/usr/bin/env bash
set -eu
printf '%s\n' "$*" >>"$SSH_LOG"
case "$*" in
  *'docker ps'*) printf '%064d\n' 0 ;;
  *'bao operator unseal'*) : ;;
  *) exit 64 ;;
esac
FAKE
chmod +x "$work/curl" "$work/ssh"
export CURL_COUNT="$work/curl-count" SSH_LOG="$work/ssh-log"
TTY_DEVICE="$work/tty" CURL_BIN="$work/curl" SSH_BIN="$work/ssh" \
    "$ROOT/scripts/unseal-openbao.sh" >/dev/null
[[ "$(grep -c 'bao operator unseal' "$SSH_LOG")" == 2 ]]
[[ "$(grep -c -- '-tt monosense@10.25.10.20' "$SSH_LOG")" == 2 ]]
[[ "$(cat "$CURL_COUNT")" == 2 ]]
if grep -E '(share|key)=' "$SSH_LOG" >/dev/null; then
    printf '%s\n' 'unseal material appeared in SSH arguments' >&2
    exit 1
fi
rm -f "$CURL_COUNT" "$SSH_LOG"
HEALTH_MODE=active TTY_DEVICE="$work/tty" CURL_BIN="$work/curl" SSH_BIN="$work/ssh" \
    "$ROOT/scripts/unseal-openbao.sh" >/dev/null
[[ ! -e "$SSH_LOG" ]]
printf '%s\n' 'OpenBao Just unseal orchestration tests passed'
