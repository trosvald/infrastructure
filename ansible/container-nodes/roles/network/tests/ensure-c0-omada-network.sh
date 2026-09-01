#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; SCRIPT="$HERE/../files/ensure-c0-omada-network"; work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT; mkdir "$work/state"
cat >"$work/network.json" <<'JSON'
[{"Name":"c0_omada_mgmt","Driver":"ipvlan","Scope":"local","Internal":false,"Attachable":false,"Ingress":false,"ConfigOnly":false,"EnableIPv4":true,"EnableIPv6":false,"IPAM":{"Driver":"default","Options":{},"Config":[{"Subnet":"10.25.10.0/24","IPRange":"10.25.10.26/32","Gateway":"10.25.10.1","AuxiliaryAddresses":{"c0":"10.25.10.20"}}]},"Options":{"ipvlan_mode":"l2","ipvlan_flag":"bridge","parent":"enp0s31f6"},"Labels":{"io.monosense.infrastructure.managed-by":"bootstrap","io.monosense.infrastructure.purpose":"omada-controller-mgmt"},"Containers":{}}]
JSON
cat >"$work/docker" <<'SH'
#!/usr/bin/env bash
set -eu; s=$FAKE_STATE; printf '%s\n' "$*" >>"$s/calls"
case "$1 $2" in
 'network inspect') [[ ${FAIL:-} != inspect ]] || exit 70; if [[ -e $s/exists ]]; then cat "$s/network.json"; else printf 'Error response from daemon: network c0_omada_mgmt not found\n' >&2; exit 1; fi;;
 'network ls') [[ ${FAIL:-} != list ]] || exit 71; [[ ! -e $s/exists ]] || printf 'c0_omada_mgmt\n';;
 'network create') [[ ${FAIL:-} != create ]] || exit 72; printf '%s\n' "$*" >"$s/create"; touch "$s/exists";;
 *) exit 73;; esac
SH
cat >"$work/ip" <<'SH'
#!/usr/bin/env bash
[[ ${FAIL:-} != ip ]] || exit 80; mtu=1500; flags='["UP"]'; [[ ${FAIL:-} != mtu ]] || mtu=1496; [[ ${FAIL:-} != down ]] || flags='[]'; printf '[{"ifname":"enp0s31f6","mtu":%s,"flags":%s}]\n' "$mtu" "$flags"
SH
chmod +x "$work/docker" "$work/ip"
reset(){ rm -rf "$work/state"; mkdir "$work/state"; cp "$work/network.json" "$work/state/network.json"; : >"$work/state/calls"; }
run(){ FAKE_STATE="$work/state" DOCKER_BIN="$work/docker" IP_BIN="$work/ip" FAIL="${1:-}" "$SCRIPT" "${MODE:-apply}" >/dev/null; }
must_fail(){ if run "$1" 2>/dev/null; then printf 'expected failure %s\n' "$1" >&2; exit 1; fi; [[ ! -e $work/state/create ]]; }
reset; touch "$work/state/exists"; run; [[ ! -e $work/state/create ]]
reset; MODE=check run; unset MODE; [[ ! -e $work/state/create ]]
reset; run; [[ -e $work/state/create ]]; grep -F -- '--driver ipvlan' "$work/state/create" >/dev/null; grep -F -- '--ip-range 10.25.10.26/32' "$work/state/create" >/dev/null
filters=('.[0].Name="wrong"' '.[0].Driver="bridge"' '.[0].Scope="swarm"' '.[0].Internal=true' '.[0].Attachable=true' '.[0].Ingress=true' '.[0].ConfigOnly=true' '.[0].EnableIPv4=false' '.[0].EnableIPv6=true' '.[0].IPAM.Driver="other"' '.[0].IPAM.Options={"x":"y"}' '.[0].IPAM.Config[0].Subnet="10.0.0.0/8"' '.[0].IPAM.Config[0].IPRange="10.25.10.27/32"' '.[0].IPAM.Config[0].Gateway="10.25.10.254"' '.[0].IPAM.Config[0].AuxiliaryAddresses={}' '.[0].Options.parent="wrong"' '.[0].Options.ipvlan_mode="l3"' '.[0].Options.ipvlan_flag="private"' '.[0].Labels={}' '. += [.[0]]')
for filter in "${filters[@]}"; do reset; touch "$work/state/exists"; jq "$filter" "$work/network.json" >"$work/state/network.json"; must_fail ''; done
for scenario in inspect list ip mtu down; do reset; [[ $scenario == inspect ]] && touch "$work/state/exists"; must_fail "$scenario"; done
reset; if run create 2>/dev/null; then exit 1; fi; [[ ! -e $work/state/exists ]]
printf 'c0 Omada network behavior tests passed\n'
