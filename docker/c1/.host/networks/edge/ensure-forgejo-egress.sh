#!/usr/bin/env bash
set -euo pipefail

NFT_BIN="${NFT_BIN:-nft}"
ID_BIN="${ID_BIN:-id}"
[[ "$($ID_BIN -u)" == 0 ]] || { printf '%s\n' 'Forgejo egress firewall requires root' >&2; exit 1; }
rules="$(mktemp)"
trap 'rm -f "$rules"' EXIT HUP INT TERM
cat >"$rules" <<'NFT'
destroy table inet c1_forgejo_egress
table inet c1_forgejo_egress {
    set denied_v4 {
        type ipv4_addr
        flags interval
        elements = { 0.0.0.0/8, 10.0.0.0/8, 100.64.0.0/10, 127.0.0.0/8,
            169.254.0.0/16, 172.16.0.0/12, 192.0.0.0/24, 192.0.2.0/24,
            192.168.0.0/16, 198.18.0.0/15, 198.51.100.0/24, 203.0.113.0/24,
            224.0.0.0/4, 240.0.0.0/4 }
    }
    chain forward {
        type filter hook forward priority -5; policy accept;
        ct state established,related accept
        ip saddr 172.30.15.67 ip daddr 10.25.13.65 tcp dport 443 accept
        ip saddr { 172.30.15.66, 172.30.15.67 } ip daddr @denied_v4 drop
        ip saddr { 172.30.15.66, 172.30.15.67 } udp dport 53 accept
        ip saddr { 172.30.15.66, 172.30.15.67 } tcp dport { 53, 443 } accept
        ip saddr 172.30.15.66 tcp dport 587 accept
        ip saddr { 172.30.15.66, 172.30.15.67 } drop
    }
}
NFT
if [[ "$1" == apply ]]; then
    "$NFT_BIN" -f "$rules"
else
    "$NFT_BIN" -c -f "$rules"
fi
printf '%s\n' 'Forgejo/Kopia egress permits only reviewed DNS, HTTPS, Zoho submission, and scoped S3 flows'
