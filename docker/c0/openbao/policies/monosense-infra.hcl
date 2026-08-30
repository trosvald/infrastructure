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

path "kv/data/platform/tls/monosense-wildcard" {
  capabilities = ["create", "read", "update", "patch", "delete"]
}

path "kv/metadata/platform/tls/monosense-wildcard" {
  capabilities = ["read", "delete"]
}

path "auth/token/create/wildcard-publisher" {
  capabilities = ["update"]
}

path "auth/token/create/wildcard-reader-c0" {
  capabilities = ["update"]
}

path "auth/token/create/wildcard-reader-c1" {
  capabilities = ["update"]
}
