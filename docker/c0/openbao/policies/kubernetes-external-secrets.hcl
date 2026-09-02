path "auth/token/lookup-self" {
  capabilities = ["read"]
}

path "kv/data/platform/kubernetes/flux-system/image-automation" {
  capabilities = ["read"]
}

path "kv/data/platform/kubernetes/kube-system/cilium-bgp-bsd-k8s-01" {
  capabilities = ["read"]
}
path "kv/data/platform/kubernetes/kube-system/cilium-bgp-bsd-k8s-02" {
  capabilities = ["read"]
}
path "kv/data/platform/kubernetes/kube-system/cilium-bgp-bsd-k8s-03" {
  capabilities = ["read"]
}
path "kv/data/platform/kubernetes/kube-system/cilium-bgp-bsd-k8s-04" {
  capabilities = ["read"]
}
path "kv/data/platform/kubernetes/kube-system/cilium-bgp-bsd-k8s-05" {
  capabilities = ["read"]
}

path "kv/data/platform/kubernetes/networking/envoy-edge" {
  capabilities = ["read"]
}
path "kv/data/platform/kubernetes/networking/envoy-internal" {
  capabilities = ["read"]
}
path "kv/data/platform/kubernetes/networking/external-dns" {
  capabilities = ["read"]
}
path "kv/data/platform/kubernetes/rook-ceph/dashboard" {
  capabilities = ["read"]
}
path "kv/data/platform/kubernetes/kopiur-system/r2" {
  capabilities = ["read"]
}
path "kv/data/platform/kubernetes/kopiur-system/kopiur" {
  capabilities = ["read"]
}
path "kv/data/platform/kubernetes/observability/grafana" {
  capabilities = ["read"]
}
path "kv/data/platform/kubernetes/observability/alertmanager" {
  capabilities = ["read"]
}
path "kv/data/platform/kubernetes/observability/snmp" {
  capabilities = ["read"]
}
path "kv/data/platform/kubernetes/database/cloudnative-pg" {
  capabilities = ["read"]
}
path "kv/data/platform/kubernetes/database/dragonfly" {
  capabilities = ["read"]
}
path "kv/data/platform/kubernetes/security/keycloak" {
  capabilities = ["read"]
}
path "kv/data/platform/kubernetes/security/keycloak-tofu" {
  capabilities = ["read"]
}
path "kv/data/platform/kubernetes/security/oauth2-proxy" {
  capabilities = ["read"]
}
path "kv/data/platform/kubernetes/ai/memini" {
  capabilities = ["read"]
}
path "kv/data/platform/kubernetes/ai/llmkube" {
  capabilities = ["read"]
}
path "kv/data/platform/kubernetes/ai/litellm" {
  capabilities = ["read"]
}
path "kv/data/platform/kubernetes/ai/codex-adapter" {
  capabilities = ["read"]
}
path "kv/data/platform/tls/kubernetes-ca" {
  capabilities = ["read"]
}

path "kv/data/platform/kubernetes/system-upgrade/tuppr" {
  capabilities = ["read"]
}

path "kv/data/platform/kubernetes/database/cloudnative-pg-generated" {
  capabilities = ["create", "read", "update", "patch"]
}
path "kv/metadata/platform/kubernetes/database/cloudnative-pg-generated" {
  capabilities = ["create", "read", "update", "patch"]
}
path "kv/data/platform/kubernetes/verification/eso-cas" {
  capabilities = ["create", "read", "update", "patch"]
}
path "kv/metadata/platform/kubernetes/verification/eso-cas" {
  capabilities = ["create", "read", "update", "patch"]
}
