variable "state_encryption_passphrase" {
  type      = string
  sensitive = true
}

variable "tofu_admin_client_secret" {
  type      = string
  sensitive = true
}

variable "keycloak_ca_certificate" {
  type      = string
  sensitive = true
}

variable "human_admin_username" {
  type      = string
  sensitive = true
}

variable "human_admin_email" {
  type      = string
  sensitive = true
}

variable "human_admin_initial_password" {
  type      = string
  sensitive = true
}

variable "ceph_client_secret" {
  type      = string
  sensitive = true
}

variable "alertmanager_client_secret" {
  type      = string
  sensitive = true
}

variable "victorialogs_client_secret" {
  type      = string
  sensitive = true
}

variable "memini_client_secret" {
  type      = string
  sensitive = true
}

variable "grafana_client_secret" {
  type      = string
  sensitive = true
}
