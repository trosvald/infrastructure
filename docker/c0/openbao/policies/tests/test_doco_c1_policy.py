#!/usr/bin/env python3
from pathlib import Path
import re

policy = Path(__file__).parents[1] / "doco-c1.hcl"
text = policy.read_text(encoding="utf-8")
blocks = re.findall(r'path\s+"([^"]+)"\s*\{\s*capabilities\s*=\s*\[([^]]*)\]\s*\}', text, re.S)
parsed = {path: re.findall(r'"([^"]+)"', capabilities) for path, capabilities in blocks}
expected = {
    "kv/data/docker/c1/librefs": ["read"],
    "kv/data/docker/c1/edge": ["read"],
    "kv/data/docker/c1/forgejo": ["read"],
    "auth/token/lookup-self": ["read"],
    "auth/token/renew-self": ["update"],
}
assert parsed == expected
assert len(blocks) == len(expected)
assert "*" not in text and "+" not in text

allowed = {(path, capability) for path, capabilities in expected.items() for capability in capabilities}
denied_paths = [
    "kv/data/docker/c1", "kv/data/docker/c1/librefs/child", "kv/metadata/docker/c1/librefs",
    "kv/data/docker/c1/mattermost", "kv/data/docker/c1/edge/child",
    "kv/metadata/docker/c1/edge", "kv/metadata/docker/c1/forgejo",
    "kv/data/docker/c0/openbao", "kv/data/junos", "kv/data/global", "sys/policies/acl/doco-c1",
    "auth/token/create", "auth/token/revoke-self", "identity/entity/id/canary", "pki/issue/canary",
]
denied_capabilities = ["create", "update", "patch", "delete", "list", "sudo"]
for path in denied_paths:
    for capability in ["create", "read", "update", "patch", "delete", "list", "sudo"]:
        assert (path, capability) not in allowed
for path, capabilities in expected.items():
    for capability in denied_capabilities:
        if capability not in capabilities:
            assert (path, capability) not in allowed
assert ("auth/token/renew-self", "read") not in allowed
print("doco-c1 policy grants only exact KV read and self token lifecycle capabilities")
