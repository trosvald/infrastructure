#!/usr/bin/env python3
from pathlib import Path
import re

policy = Path(__file__).parents[1] / "monosense-infra.hcl"
text = policy.read_text(encoding="utf-8")
blocks = re.findall(
    r'path\s+"([^"]+)"\s*\{\s*capabilities\s*=\s*\[([^]]*)\]\s*\}',
    text,
    re.S,
)
parsed = {
    path: re.findall(r'"([^"]+)"', capabilities)
    for path, capabilities in blocks
}
expected_paths = {
    "kv/data/network/junos/srx1500/topology",
    "kv/data/network/junos/srx1500/netconf",
    "kv/data/network/junos/srx1500/admin",
    "kv/data/network/bgp/cilium-srx1500",
    "kv/data/platform/talos/bsd/topology",
    "kv/data/platform/talos/bsd/secrets",
}
assert parsed == {path: ["read"] for path in expected_paths}
assert len(blocks) == len(expected_paths)
assert "*" not in text and "+" not in text
for capabilities in parsed.values():
    assert capabilities == ["read"]
for denied in (
    "kv/metadata/network/junos/srx1500/topology",
    "kv/data/network/junos/srx1500/topology/child",
    "kv/data/network/bgp",
    "kv/data/platform/talos/bsd",
    "auth/token/create",
    "auth/userpass/users/monosense-infra",
    "sys/policies/acl/monosense-infra",
):
    assert denied not in parsed
print("monosense-infra policy grants read on only the six approved records")
