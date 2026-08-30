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
readonly_paths = {
    "kv/data/network/junos/srx1500/netconf",
    "kv/data/network/junos/srx1500/admin",
    "kv/data/network/bgp/cilium-srx1500",
    "kv/data/platform/talos/bsd/topology",
    "kv/data/platform/talos/bsd/secrets",
}
managed_records = {
    "docker/c1/edge",
    "docker/c1/forgejo",
    "docker/c0/monitoring",
    "platform/tls/monosense-wildcard",
}
expected = {path: ["read"] for path in readonly_paths}
expected["kv/data/network/junos/srx1500/topology"] = ["read", "update"]
for record in managed_records:
    expected[f"kv/data/{record}"] = ["create", "read", "update", "patch", "delete"]
    expected[f"kv/metadata/{record}"] = ["read", "delete"]
for role in ("wildcard-publisher", "wildcard-reader-c0", "wildcard-reader-c1"):
    expected[f"auth/token/create/{role}"] = ["update"]
assert parsed == expected
assert len(blocks) == len(expected)
assert "*" not in text and "+" not in text
for denied in (
    "kv/data/docker/c1",
    "kv/data/docker/c1/edge/child",
    "kv/metadata/network/junos/srx1500/topology",
    "kv/data/network/junos/srx1500/topology/child",
    "kv/data/network/bgp",
    "kv/data/platform/talos/bsd",
    "auth/token/create",
    "auth/token/create/not-approved",
    "auth/userpass/users/monosense-infra",
    "sys/policies/acl/monosense-infra",
):
    assert denied not in parsed
print("monosense-infra policy grants only exact infrastructure records and token roles")
