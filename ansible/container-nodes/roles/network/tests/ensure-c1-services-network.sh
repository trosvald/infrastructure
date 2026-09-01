#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; SCRIPT="$HERE/../files/ensure-c1-services-network"
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT; mkdir "$work/state"
cat >"$work/network.json" <<'JSON'
[{"Name":"c1_services","Driver":"ipvlan","Scope":"local","EnableIPv4":true,"EnableIPv6":false,"Internal":false,"Attachable":false,"Ingress":false,"ConfigOnly":false,"IPAM":{"Driver":"default","Options":{},"Config":[{"Subnet":"10.25.13.0/24","IPRange":"10.25.13.64/27","Gateway":"10.25.13.1","AuxiliaryAddresses":{"c1-shim":"10.25.13.17"}}]},"Options":{"parent":"bond0.2513","ipvlan_mode":"l2","ipvlan_flag":"bridge"},"Labels":{"io.monosense.infrastructure.managed-by":"bootstrap","io.monosense.infrastructure.purpose":"c1-services"},"Containers":{}}]
JSON
cat >"$work/docker" <<'SH'
#!/usr/bin/env bash
set -eu
s=$FAKE_STATE
case "$1 $2" in
 'network inspect') if [[ -e $s/exists ]]; then cat "$s/network.json"; else printf 'Error response from daemon: network c1_services not found\n' >&2; exit 1; fi;;
 'network ls') [[ ! -e $s/exists ]] || printf 'c1_services\n';;
 'network create') printf '%s\n' "$*" >"$s/create"; touch "$s/exists";;
 *) exit 70;;
esac
SH
cat >"$work/ip" <<'SH'
#!/usr/bin/env bash
if [[ " $* " == *' address '* ]]; then printf '%s\n' '[{"ifname":"bond0.2513","addr_info":[]}]'; else printf '%s\n' '[{"ifname":"bond0.2513","mtu":1496,"flags":["UP"],"linkinfo":{"info_kind":"vlan","info_data":{"id":2513}}}]'; fi
SH
chmod +x "$work/docker" "$work/ip"
reset(){ rm -rf "$work/state"; mkdir "$work/state"; cp "$work/network.json" "$work/state/network.json"; }
run(){ FAKE_STATE="$work/state" DOCKER_BIN="$work/docker" IP_BIN="$work/ip" "$SCRIPT" "$@" >/dev/null; }
reset; touch "$work/state/exists"; run check; [[ ! -e "$work/state/create" ]]
reset; run check; [[ ! -e "$work/state/create" ]]
reset; run apply; [[ -e "$work/state/create" ]]; run check
reset; touch "$work/state/exists"; python3 -c 'import json,sys;p=sys.argv[1];x=json.load(open(p));x[0]["Options"]["parent"]="wrong";json.dump(x,open(p,"w"))' "$work/state/network.json"; if run apply 2>/dev/null; then exit 1; fi; [[ ! -e "$work/state/create" ]]
printf 'c1 SERVICES Ansible-owned network helper tests passed\n'
