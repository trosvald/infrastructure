#!/usr/bin/env python3
from pathlib import Path
import re

ROOT = Path(__file__).parents[1]
expected = {
    "kubernetes-cert-manager-networking.hcl": {
        "pki-kubernetes/sign/envoy-edge",
        "pki-kubernetes/sign/envoy-internal",
        "pki-kubernetes/sign/mac-caddy",
        "pki-kubernetes/sign/vector-srx",
    },
    "kubernetes-cert-manager-database.hcl": {
        "pki-kubernetes/sign/cnpg",
        "pki-kubernetes/sign/dragonfly",
    },
    "kubernetes-cert-manager-security.hcl": {
        "pki-kubernetes/sign/keycloak",
        "pki-kubernetes/sign/cnpg",
    },
    "kubernetes-cert-manager-ai.hcl": {
        "pki-kubernetes/sign/mac-embedding",
        "pki-kubernetes/sign/cnpg",
    },
    "kubernetes-keycloak-tofu.hcl": {
        "kv/data/platform/kubernetes/security/keycloak-tofu",
    },
    "kubernetes-codex-checkpoint.hcl": {
        "kv/data/platform/kubernetes/ai/codex-adapter",
    },
}
for filename, paths in expected.items():
    text = (ROOT / filename).read_text()
    blocks = re.findall(r'path "([^"]+)"\s*\{\s*capabilities = \[([^]]+)\]', text)
    assert {path for path, _ in blocks} == paths
    if filename == "kubernetes-keycloak-tofu.hcl":
        expected_capabilities = {"read"}
    elif filename == "kubernetes-codex-checkpoint.hcl":
        expected_capabilities = {"create", "read", "update"}
    else:
        expected_capabilities = {"create", "update"}
    assert all(set(re.findall(r'"([a-z]+)"', caps)) == expected_capabilities for _, caps in blocks)
    assert "*" not in text and "list" not in text and "delete" not in text and "sudo" not in text

eso = (ROOT / "kubernetes-external-secrets.hcl").read_text()
assert "*" not in eso and '"list"' not in eso and '"delete"' not in eso and '"sudo"' not in eso
blocks = dict(re.findall(r'path "([^"]+)"\s*\{\s*capabilities = \[([^]]+)\]', eso))
for path, capabilities in blocks.items():
    parsed = set(re.findall(r'"([a-z]+)"', capabilities))
    if path.endswith(("cloudnative-pg-generated", "verification/eso-cas")):
        assert parsed == {"create", "read", "update", "patch"}
    elif path == "auth/token/lookup-self":
        assert parsed == {"read"}
    else:
        assert path.startswith("kv/data/platform/kubernetes/") or path == "kv/data/platform/tls/kubernetes-ca"
        assert parsed == {"read"}
print("Kubernetes OpenBao policies grant exact pull, CAS push, and PKI sign paths only")
