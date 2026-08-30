#!/usr/bin/env bash
set -euo pipefail
readonly SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/ensure-forgejo-egress.sh"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
cat >"$work/id" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "${FAKE_UID:-0}"
FAKE
cat >"$work/nft" <<'FAKE'
#!/usr/bin/env bash
set -eu
printf '%s\n' "$*" >"$NFT_ARGS"
last=""
for value in "$@"; do last="$value"; done
cp "$last" "$NFT_RULES"
FAKE
chmod +x "$work/id" "$work/nft"
export NFT_ARGS="$work/args" NFT_RULES="$work/rules"
ID_BIN="$work/id" NFT_BIN="$work/nft" "$SCRIPT" check >/dev/null
grep -E '^-c -f /' "$work/args" >/dev/null
grep -F 'destroy table inet c1_forgejo_egress' "$work/rules" >/dev/null
grep -F '172.30.15.67 ip daddr 10.25.13.65 tcp dport 443 accept' "$work/rules" >/dev/null
grep -F '172.30.15.66 tcp dport 587 accept' "$work/rules" >/dev/null
grep -F 'tcp dport { 53, 443 } accept' "$work/rules" >/dev/null
grep -F 'ip daddr @denied_v4 drop' "$work/rules" >/dev/null
grep -F 'ip saddr { 172.30.15.66, 172.30.15.67 } drop' "$work/rules" >/dev/null
ID_BIN="$work/id" NFT_BIN="$work/nft" "$SCRIPT" apply >/dev/null
[[ "$(cut -d' ' -f1 "$work/args")" == -f ]]
if FAKE_UID=1000 ID_BIN="$work/id" NFT_BIN="$work/nft" "$SCRIPT" check >/dev/null 2>&1; then
    printf '%s\n' 'non-root firewall invocation unexpectedly passed' >&2
    exit 1
fi
printf '%s\n' 'Forgejo egress firewall contract tests passed'
