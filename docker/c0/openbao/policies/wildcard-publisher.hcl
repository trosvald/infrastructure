path "kv/data/platform/tls/monosense-wildcard" {
  capabilities = ["create", "read", "update", "patch"]
}

path "kv/metadata/platform/tls/monosense-wildcard" {
  capabilities = ["read"]
}

path "auth/token/lookup-self" {
  capabilities = ["read"]
}

path "auth/token/renew-self" {
  capabilities = ["update"]
}
