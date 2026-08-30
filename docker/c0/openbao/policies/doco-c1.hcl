path "kv/data/docker/c1/librefs" {
  capabilities = ["read"]
}

path "kv/data/docker/c1/edge" {
  capabilities = ["read"]
}

path "kv/data/docker/c1/forgejo" {
  capabilities = ["read"]
}

path "auth/token/lookup-self" {
  capabilities = ["read"]
}

path "auth/token/renew-self" {
  capabilities = ["update"]
}
