#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; SCRIPT="$HERE/../files/ensure-c1-forgejo-egress"; work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT; mkdir "$work/state"
cat >"$work/nft" <<'SH'
#!/usr/bin/env bash
set -eu
s=$FAKE_STATE; printf '%s\n' "$*" >>"$s/calls"
if [[ "$*" == '-j list table inet c1_forgejo_egress' ]]; then
 [[ -e "$s/exists" ]] || { printf 'Error: No such file or directory\n' >&2; exit 1; }
 python3 - "$s" <<'PY'
import json,sys
s=sys.argv[1]; comments=['table','denied-v4','forward']+['r%d'%i for i in range(1,9)]
o=[{'table':{'family':'inet','name':'c1_forgejo_egress','comment':'monosense:forgejo-egress:v1:table'}},{'set':{'family':'inet','table':'c1_forgejo_egress','name':'denied_v4','type':'ipv4_addr','flags':['interval'],'comment':'monosense:forgejo-egress:v1:denied-v4'}},{'chain':{'family':'inet','table':'c1_forgejo_egress','name':'forward','hook':'forward','prio':-5,'policy':'accept','comment':'monosense:forgejo-egress:v1:forward'}}]
for i in range(1,9): o.append({'rule':{'family':'inet','table':'c1_forgejo_egress','chain':'forward','comment':'monosense:forgejo-egress:v1:r%d'%i}})
if __import__('os').environ.get('LEGACY') and not __import__('os').path.exists(s+'/labeled'):
    for obj in o: next(iter(obj.values())).pop('comment')
if __import__('os').environ.get('DRIFT'): o[-1]['rule']['comment']='bad'
print(json.dumps({'nftables':o}))
PY
elif [[ "$*" == '-nn list table inet c1_forgejo_egress' ]]; then
 cat <<'TXT'
ct state 0x2,0x4 accept
ip saddr 172.30.15.67 ip daddr 10.25.13.65 tcp dport 443 accept
ip saddr 172.30.15.66 ip daddr 10.25.20.41 tcp dport 6379 accept
ip saddr { 172.30.15.66, 172.30.15.67 } ip daddr @denied_v4 drop
ip saddr { 172.30.15.66, 172.30.15.67 } udp dport 53 accept
ip saddr { 172.30.15.66, 172.30.15.67 } tcp dport { 53, 443 } accept
ip saddr 172.30.15.66 tcp dport 587 accept
ip saddr { 172.30.15.66, 172.30.15.67 } drop
TXT
elif [[ "$*" == 'list tables' ]]; then [[ ! -e "$s/exists" ]] || printf 'table inet c1_forgejo_egress\n'
elif [[ "$1" == '-c' ]]; then :
elif [[ "$1" == '-f' ]]; then touch "$s/exists" "$s/labeled"
else exit 70
fi
SH
cat >"$work/id" <<'SH'
#!/usr/bin/env bash
printf '0\n'
SH
chmod +x "$work/nft" "$work/id"; touch "$work/policy"
run(){ FAKE_STATE="$work/state" NFT_BIN="$work/nft" ID_BIN="$work/id" POLICY="$work/policy" "$SCRIPT" "$@" >/dev/null; }
: >"$work/state/calls"; run check; ! grep -F -- '-f ' "$work/state/calls" >/dev/null
: >"$work/state/calls"; run apply; [[ -e "$work/state/exists" ]]
rm -f "$work/state/labeled"; LEGACY=1; export LEGACY
: >"$work/state/calls"; run check; ! grep -F -- '-f ' "$work/state/calls" >/dev/null
: >"$work/state/calls"; run apply; [[ -e "$work/state/labeled" ]]; grep -F -- '-f ' "$work/state/calls" >/dev/null; unset LEGACY
: >"$work/state/calls"; DRIFT=1; export DRIFT; if run apply 2>/dev/null; then exit 1; fi; unset DRIFT; ! grep -F -- '-f ' "$work/state/calls" >/dev/null
printf 'c1 repository firewall refusal tests passed\n'
