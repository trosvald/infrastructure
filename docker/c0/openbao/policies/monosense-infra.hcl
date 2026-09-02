path "kv/data/network/junos/srx1500/topology" {
  capabilities = ["read", "update"]
}

path "kv/data/network/junos/srx1500/netconf" {
  capabilities = ["read"]
}
path "kv/data/network/junos/srx1500/admin" {
  capabilities = ["read"]
}


path "kv/data/network/bgp/cilium-srx1500" {
  capabilities = ["read"]
}

path "kv/data/platform/talos/bsd/topology" {
  capabilities = ["read"]
}

path "kv/data/platform/talos/bsd/secrets" {
  capabilities = ["read"]
}

path "kv/data/docker/c1/librefs" {
  capabilities = ["create", "read", "update", "patch", "delete"]
}

path "kv/metadata/docker/c1/librefs" {
  capabilities = ["read", "delete"]
}

path "kv/data/docker/c1/edge" {
  capabilities = ["create", "read", "update", "patch", "delete"]
}

path "kv/metadata/docker/c1/edge" {
  capabilities = ["read", "delete"]
}

path "kv/data/docker/c1/forgejo" {
  capabilities = ["create", "read", "update", "patch", "delete"]
}

path "kv/metadata/docker/c1/forgejo" {
  capabilities = ["read", "delete"]
}

path "kv/data/docker/c0/monitoring" {
  capabilities = ["create", "read", "update", "patch", "delete"]
}

path "kv/metadata/docker/c0/monitoring" {
  capabilities = ["read", "delete"]
}
path "kv/data/docker/c0/powerdns" {
  capabilities = ["create", "read", "update", "delete"]
}

path "kv/metadata/docker/c0/powerdns" {
  capabilities = ["read", "delete"]
}

path "kv/data/platform/tls/monosense-wildcard" {
  capabilities = ["create", "read", "update", "patch", "delete"]
}
path "kv/data/platform/tls/kubernetes-ca" {
  capabilities = ["create", "read", "update"]
}

path "kv/metadata/platform/tls/kubernetes-ca" {
  capabilities = ["read"]
}

path "kv/metadata/platform/tls/monosense-wildcard" {
  capabilities = ["read", "delete"]
}

path "auth/token/create/wildcard-publisher" {
  capabilities = ["update"]
}

path "auth/token/roles/wildcard-publisher" {
  capabilities = ["read"]
}

path "auth/token/create/wildcard-reader-c0" {
  capabilities = ["update"]
}

path "auth/token/roles/wildcard-reader-c0" {
  capabilities = ["read"]
}

path "auth/token/create/wildcard-reader-c1" {
  capabilities = ["update"]
}

path "auth/token/roles/wildcard-reader-c1" {
  capabilities = ["read"]
}

path "auth/token/create/doco-c1" {
  capabilities = ["update"]
}

path "auth/token/roles/doco-c1" {
  capabilities = ["read"]
}

path "auth/token/revoke-accessor" {
  capabilities = ["update"]
}

path "auth/kubernetes/config" {
  capabilities = ["create", "read", "update"]
}

path "auth/kubernetes/role/external-secrets" {
  capabilities = ["create", "read", "update"]
}

path "auth/kubernetes/role/cert-manager-networking" {
  capabilities = ["create", "read", "update"]
}

path "auth/kubernetes/role/cert-manager-database" {
  capabilities = ["create", "read", "update"]
}

path "auth/kubernetes/role/cert-manager-security" {
  capabilities = ["create", "read", "update"]
}

path "auth/kubernetes/role/cert-manager-ai" {
  capabilities = ["create", "read", "update"]
}

path "auth/kubernetes/role/keycloak-tofu" {
  capabilities = ["create", "read", "update"]
}
path "auth/kubernetes/role/codex-checkpoint" {
  capabilities = ["create", "read", "update"]
}

path "sys/policies/acl/kubernetes-external-secrets" {
  capabilities = ["create", "read", "update"]
}

path "sys/policies/acl/kubernetes-cert-manager-networking" {
  capabilities = ["create", "read", "update"]
}

path "sys/policies/acl/kubernetes-cert-manager-database" {
  capabilities = ["create", "read", "update"]
}

path "sys/policies/acl/kubernetes-cert-manager-security" {
  capabilities = ["create", "read", "update"]
}

path "sys/policies/acl/kubernetes-cert-manager-ai" {
  capabilities = ["create", "read", "update"]
}

path "sys/policies/acl/kubernetes-keycloak-tofu" {
  capabilities = ["create", "read", "update"]
}
path "sys/policies/acl/kubernetes-codex-checkpoint" {
  capabilities = ["create", "read", "update"]
}

path "pki-kubernetes/roles/envoy-edge" {
  capabilities = ["create", "read", "update"]
}

path "pki-kubernetes/roles/envoy-internal" {
  capabilities = ["create", "read", "update"]
}

path "pki-kubernetes/roles/cnpg" {
  capabilities = ["create", "read", "update"]
}

path "pki-kubernetes/roles/dragonfly" {
  capabilities = ["create", "read", "update"]
}

path "pki-kubernetes/roles/keycloak" {
  capabilities = ["create", "read", "update"]
}

path "pki-kubernetes/roles/mac-caddy" {
  capabilities = ["create", "read", "update"]
}

path "pki-kubernetes/roles/mac-embedding" {
  capabilities = ["create", "read", "update"]
}

path "pki-kubernetes/roles/vector-client" {
  capabilities = ["create", "read", "update"]
}

path "pki-kubernetes/roles/vector-srx" {
  capabilities = ["create", "read", "update"]
}

path "kv/data/platform/kubernetes/kube-system/cilium-bgp-bsd-k8s-01" {
  capabilities = ["create", "read", "update"]
}
path "kv/metadata/platform/kubernetes/kube-system/cilium-bgp-bsd-k8s-01" {
  capabilities = ["read"]
}
path "kv/data/platform/kubernetes/kube-system/cilium-bgp-bsd-k8s-02" {
  capabilities = ["create", "read", "update"]
}
path "kv/metadata/platform/kubernetes/kube-system/cilium-bgp-bsd-k8s-02" {
  capabilities = ["read"]
}
path "kv/data/platform/kubernetes/kube-system/cilium-bgp-bsd-k8s-03" {
  capabilities = ["create", "read", "update"]
}
path "kv/metadata/platform/kubernetes/kube-system/cilium-bgp-bsd-k8s-03" {
  capabilities = ["read"]
}
path "kv/data/platform/kubernetes/kube-system/cilium-bgp-bsd-k8s-04" {
  capabilities = ["create", "read", "update"]
}
path "kv/metadata/platform/kubernetes/kube-system/cilium-bgp-bsd-k8s-04" {
  capabilities = ["read"]
}
path "kv/data/platform/kubernetes/kube-system/cilium-bgp-bsd-k8s-05" {
  capabilities = ["create", "read", "update"]
}
path "kv/metadata/platform/kubernetes/kube-system/cilium-bgp-bsd-k8s-05" {
  capabilities = ["read"]
}

path "kv/data/platform/kubernetes/kopiur-system/kopiur" {
  capabilities = ["create", "read", "update"]
}
path "kv/metadata/platform/kubernetes/kopiur-system/kopiur" {
  capabilities = ["read", "delete"]
}
path "kv/data/platform/kubernetes/kopiur-system/r2" {
  capabilities = ["create", "read", "update"]
}
path "kv/metadata/platform/kubernetes/kopiur-system/r2" {
  capabilities = ["read", "delete"]
}

path "kv/data/platform/kubernetes/networking/external-dns" {
  capabilities = ["create", "read", "update", "delete"]
}
path "kv/metadata/platform/kubernetes/networking/external-dns" {
  capabilities = ["read", "delete"]
}

path "kv/data/platform/kubernetes/database/cloudnative-pg" {
  capabilities = ["create", "read", "update", "patch"]
}
path "kv/metadata/platform/kubernetes/database/cloudnative-pg" {
  capabilities = ["read", "delete"]
}
path "kv/data/platform/kubernetes/database/dragonfly" {
  capabilities = ["create", "read", "update", "patch"]
}
path "kv/metadata/platform/kubernetes/database/dragonfly" {
  capabilities = ["read", "delete"]
}

path "kv/data/platform/kubernetes/security/keycloak" {
  capabilities = ["create", "read", "update", "patch"]
}
path "kv/metadata/platform/kubernetes/security/keycloak" {
  capabilities = ["read", "delete"]
}
path "kv/data/platform/kubernetes/security/keycloak-bootstrap" {
  capabilities = ["create", "read", "update", "patch"]
}
path "kv/metadata/platform/kubernetes/security/keycloak-bootstrap" {
  capabilities = ["read", "delete"]
}
path "kv/data/platform/kubernetes/security/keycloak-tofu" {
  capabilities = ["create", "read", "update", "patch"]
}
path "kv/metadata/platform/kubernetes/security/keycloak-tofu" {
  capabilities = ["read", "delete"]
}

path "kv/data/platform/kubernetes/ai/llmkube" {
  capabilities = ["create", "read", "update", "patch"]
}
path "kv/metadata/platform/kubernetes/ai/llmkube" {
  capabilities = ["read", "delete"]
}
path "kv/data/platform/kubernetes/ai/memini" {
  capabilities = ["create", "read", "update", "patch"]
}
path "kv/metadata/platform/kubernetes/ai/memini" {
  capabilities = ["read", "delete"]
}
path "kv/data/platform/kubernetes/ai/litellm" {
  capabilities = ["create", "read", "update", "patch"]
}
path "kv/metadata/platform/kubernetes/ai/litellm" {
  capabilities = ["read", "delete"]
}
path "kv/data/platform/kubernetes/ai/codex-adapter" {
  capabilities = ["create", "read", "update", "patch"]
}
path "kv/metadata/platform/kubernetes/ai/codex-adapter" {
  capabilities = ["read", "delete"]
}

path "pki-kubernetes/issue/vector-client" {
  capabilities = ["create", "update"]
}

path "kv/data/platform/kubernetes/observability/grafana" {
  capabilities = ["create", "read", "update", "patch"]
}
path "kv/metadata/platform/kubernetes/observability/grafana" {
  capabilities = ["read", "delete"]
}
path "kv/data/platform/kubernetes/observability/alertmanager" {
  capabilities = ["create", "read", "update", "patch"]
}
path "kv/metadata/platform/kubernetes/observability/alertmanager" {
  capabilities = ["read", "delete"]
}
path "kv/data/platform/kubernetes/observability/snmp" {
  capabilities = ["create", "read", "update", "patch"]
}
path "kv/metadata/platform/kubernetes/observability/snmp" {
  capabilities = ["read", "delete"]
}

path "pki-kubernetes/cert/ca" {
  capabilities = ["read"]
}
