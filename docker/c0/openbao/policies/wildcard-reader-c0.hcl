path "kv/data/platform/tls/monosense-wildcard" {
  capabilities = ["read"]
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
