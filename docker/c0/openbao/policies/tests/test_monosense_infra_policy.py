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
    "pki-kubernetes/cert/ca",
}
managed_records = {
    "docker/c1/librefs",
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
for record in (
    "docker/c0/powerdns",
    "platform/kubernetes/networking/external-dns",
):
    expected[f"kv/data/{record}"] = ["create", "read", "update", "delete"]
    expected[f"kv/metadata/{record}"] = ["read", "delete"]
expected["kv/data/platform/tls/kubernetes-ca"] = ["create", "read", "update"]
expected["kv/metadata/platform/tls/kubernetes-ca"] = ["read"]
for role in ("doco-c1", "wildcard-publisher", "wildcard-reader-c0", "wildcard-reader-c1"):
    expected[f"auth/token/create/{role}"] = ["update"]
    expected[f"auth/token/roles/{role}"] = ["read"]
expected["auth/token/revoke-accessor"] = ["update"]
for role in (
    "external-secrets",
    "cert-manager-networking",
    "cert-manager-database",
    "cert-manager-security",
    "cert-manager-ai",
    "keycloak-tofu",
    "codex-checkpoint",
):
    expected[f"auth/kubernetes/role/{role}"] = ["create", "read", "update"]
expected["auth/kubernetes/config"] = ["create", "read", "update"]
for policy in (
    "kubernetes-external-secrets",
    "kubernetes-cert-manager-networking",
    "kubernetes-cert-manager-database",
    "kubernetes-cert-manager-security",
    "kubernetes-cert-manager-ai",
    "kubernetes-keycloak-tofu",
    "kubernetes-codex-checkpoint",
):
    expected[f"sys/policies/acl/{policy}"] = ["create", "read", "update"]
for role in (
    "envoy-edge",
    "envoy-internal",
    "cnpg",
    "dragonfly",
    "keycloak",
    "mac-caddy",
    "mac-embedding",
    "vector-client",
    "vector-srx",
):
    expected[f"pki-kubernetes/roles/{role}"] = ["create", "read", "update"]
expected["pki-kubernetes/issue/vector-client"] = ["create", "update"]
for index in range(1, 6):
    record = f"platform/kubernetes/kube-system/cilium-bgp-bsd-k8s-{index:02d}"
    expected[f"kv/data/{record}"] = ["create", "read", "update"]
    expected[f"kv/metadata/{record}"] = ["read"]
for record in (
    "platform/kubernetes/kopiur-system/kopiur",
    "platform/kubernetes/kopiur-system/r2",
):
    expected[f"kv/data/{record}"] = ["create", "read", "update"]
    expected[f"kv/metadata/{record}"] = ["read", "delete"]
for record in (
    "platform/kubernetes/database/cloudnative-pg",
    "platform/kubernetes/database/dragonfly",
    "platform/kubernetes/security/keycloak",
    "platform/kubernetes/security/keycloak-bootstrap",
    "platform/kubernetes/security/keycloak-tofu",
    "platform/kubernetes/observability/grafana",
    "platform/kubernetes/observability/alertmanager",
    "platform/kubernetes/observability/snmp",
    "platform/kubernetes/ai/llmkube",
    "platform/kubernetes/ai/memini",
    "platform/kubernetes/ai/litellm",
    "platform/kubernetes/ai/codex-adapter",
):
    expected[f"kv/data/{record}"] = ["create", "read", "update", "patch"]
    expected[f"kv/metadata/{record}"] = ["read", "delete"]
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
    "sys/auth/kubernetes",
    "sys/mounts/pki-kubernetes",
    "auth/kubernetes/role/not-approved",
    "pki-kubernetes/root/generate/internal",
):
    assert denied not in parsed
print("monosense-infra policy grants only exact infrastructure records and token roles")
