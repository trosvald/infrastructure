#!/usr/bin/env python3
from pathlib import Path
import re

root = Path(__file__).parents[1]
expected = {
    "wildcard-publisher.hcl": {
        "kv/data/platform/tls/monosense-wildcard": ["create", "read", "update", "patch"],
        "kv/metadata/platform/tls/monosense-wildcard": ["read"],
        "auth/token/lookup-self": ["read"],
        "auth/token/renew-self": ["update"],
    },
    "wildcard-reader-c0.hcl": {
        "kv/data/platform/tls/monosense-wildcard": ["read"],
        "kv/metadata/platform/tls/monosense-wildcard": ["read"],
        "auth/token/lookup-self": ["read"],
        "auth/token/renew-self": ["update"],
    },
    "wildcard-reader-c1.hcl": {
        "kv/data/platform/tls/monosense-wildcard": ["read"],
        "kv/metadata/platform/tls/monosense-wildcard": ["read"],
        "auth/token/lookup-self": ["read"],
        "auth/token/renew-self": ["update"],
    },
}
for name, wanted in expected.items():
    text = (root / name).read_text(encoding="utf-8")
    blocks = re.findall(
        r'path\s+"([^"]+)"\s*\{\s*capabilities\s*=\s*\[([^]]*)\]\s*\}',
        text,
        re.S,
    )
    parsed = {path: re.findall(r'"([^"]+)"', caps) for path, caps in blocks}
    assert parsed == wanted, name
    assert "*" not in text and "+" not in text
print("wildcard service policies expose only the exact record and self lifecycle")
