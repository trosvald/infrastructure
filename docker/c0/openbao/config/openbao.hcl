ui = true
api_addr = "https://vault.monosense.io:8200"
cluster_addr = "https://10.25.13.34:8201"

storage "raft" {
  path = "/openbao/data"
  node_id = "c0-openbao-1"
}

listener "tcp" {
  address = "0.0.0.0:8200"
  cluster_address = "0.0.0.0:8201"
  tls_disable = false
  tls_cert_file = "/openbao/tls/current/fullchain.pem"
  tls_key_file = "/openbao/tls/current/privkey.pem"
  tls_min_version = "tls12"
}

audit "file" "stdout" {
  description = "Write audit information to standard output."
  options = {
    file_path = "stdout"
  }
}
