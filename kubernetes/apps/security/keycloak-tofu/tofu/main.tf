terraform {
  required_version = "= 1.12.6"

  required_providers {
    keycloak = {
      source  = "keycloak/keycloak"
      version = "= 5.9.0"
    }
  }

  backend "s3" {
    bucket                      = "kubernetes-keycloak-tofu"
    key                         = "state/keycloak.tfstate"
    region                      = "us-east-1"
    endpoints                   = { s3 = "https://s3.monosense.io:443" }
    use_lockfile                = true
    skip_credentials_validation = true
    skip_region_validation      = true
    skip_requesting_account_id  = true
    skip_s3_checksum            = true
    force_path_style            = true
  }

  encryption {
    key_provider "pbkdf2" "openbao" {
      passphrase = var.state_encryption_passphrase
    }
    method "aes_gcm" "state" {
      keys = key_provider.pbkdf2.openbao
    }
    state {
      method   = method.aes_gcm.state
      enforced = true
    }
    plan {
      method   = method.aes_gcm.state
      enforced = true
    }
  }
}

provider "keycloak" {
  client_id           = "keycloak-tofu"
  client_secret       = var.tofu_admin_client_secret
  url                 = "https://keycloak.security.svc.cluster.local:8443"
  root_ca_certificate = var.keycloak_ca_certificate
  keycloak_version    = "26.7.3"
}

resource "keycloak_realm" "monosense" {
  realm                         = "monosense"
  display_name                  = "Monosense"
  enabled                       = true
  terraform_deletion_protection = true
  ssl_required                  = "all"
  registration_allowed          = false
  reset_password_allowed        = true
  remember_me                   = false
  verify_email                  = true
  login_with_email_allowed      = true
  duplicate_emails_allowed      = false

  access_token_lifespan                = "5m"
  sso_session_idle_timeout             = "8h"
  sso_session_max_lifespan             = "12h"
  client_session_idle_timeout          = "8h"
  client_session_max_lifespan          = "12h"
  revoke_refresh_token                 = true
  refresh_token_max_reuse              = 0
  offline_session_max_lifespan_enabled = true
  offline_session_idle_timeout         = "8h"
  offline_session_max_lifespan         = "12h"

  password_policy = "length(16) and upperCase(1) and lowerCase(1) and digits(1) and specialChars(1) and notUsername and passwordHistory(12) and forceExpiredPasswordChange(90)"

  otp_policy {
    type          = "totp"
    algorithm     = "HmacSHA256"
    digits        = 6
    period        = 30
    code_reusable = false
  }

  web_authn_passwordless_policy {
    relying_party_entity_name         = "Monosense"
    relying_party_id                  = "auth.internal"
    signature_algorithms              = ["ES256", "RS256"]
    attestation_conveyance_preference = "none"
    discoverable_credential           = "required"
    user_verification_requirement     = "required"
    avoid_same_authenticator_register = true
    passwordless_passkeys_enabled     = true
  }

  security_defenses {
    headers {
      x_frame_options           = "DENY"
      x_content_type_options    = "nosniff"
      x_robots_tag              = "none"
      referrer_policy           = "no-referrer"
      strict_transport_security = "max-age=31536000; includeSubDomains"
      content_security_policy   = "frame-src 'self'; frame-ancestors 'self'; object-src 'none';"
    }
    brute_force_detection {
      permanent_lockout                = false
      max_login_failures               = 5
      wait_increment_seconds           = 60
      quick_login_check_milli_seconds  = 1000
      minimum_quick_login_wait_seconds = 60
      max_failure_wait_seconds         = 900
      failure_reset_time_seconds       = 43200
    }
  }
}

resource "keycloak_realm_events" "monosense" {
  realm_id = keycloak_realm.monosense.id

  events_enabled               = true
  events_expiration            = 2592000
  events_listeners             = ["jboss-logging"]
  admin_events_enabled         = true
  admin_events_details_enabled = false
  enabled_event_types = [
    "LOGIN",
    "LOGIN_ERROR",
    "LOGOUT",
    "REFRESH_TOKEN",
    "REFRESH_TOKEN_ERROR",
    "REVOKE_GRANT",
    "UPDATE_CREDENTIAL",
    "UPDATE_CREDENTIAL_ERROR",
  ]
}

resource "keycloak_authentication_flow" "browser" {
  realm_id    = keycloak_realm.monosense.id
  alias       = "monosense-browser"
  description = "Passkey-first login with password plus TOTP or recovery-code fallback"
}

resource "keycloak_authentication_execution" "cookie" {
  realm_id          = keycloak_realm.monosense.id
  parent_flow_alias = keycloak_authentication_flow.browser.alias
  authenticator     = "auth-cookie"
  requirement       = "ALTERNATIVE"
  priority          = 10
}

resource "keycloak_authentication_execution" "passkey" {
  realm_id          = keycloak_realm.monosense.id
  parent_flow_alias = keycloak_authentication_flow.browser.alias
  authenticator     = "webauthn-passwordless"
  requirement       = "ALTERNATIVE"
  priority          = 20
}

resource "keycloak_authentication_subflow" "recovery" {
  realm_id          = keycloak_realm.monosense.id
  parent_flow_alias = keycloak_authentication_flow.browser.alias
  alias             = "monosense-recovery"
  provider_id       = "basic-flow"
  requirement       = "ALTERNATIVE"
  priority          = 30
}

resource "keycloak_authentication_execution" "recovery_password" {
  realm_id          = keycloak_realm.monosense.id
  parent_flow_alias = keycloak_authentication_subflow.recovery.alias
  authenticator     = "auth-username-password-form"
  requirement       = "REQUIRED"
  priority          = 10
}

resource "keycloak_authentication_subflow" "recovery_second_factor" {
  realm_id          = keycloak_realm.monosense.id
  parent_flow_alias = keycloak_authentication_subflow.recovery.alias
  alias             = "monosense-recovery-second-factor"
  provider_id       = "basic-flow"
  requirement       = "REQUIRED"
  priority          = 20
}

resource "keycloak_authentication_execution" "recovery_totp" {
  realm_id          = keycloak_realm.monosense.id
  parent_flow_alias = keycloak_authentication_subflow.recovery_second_factor.alias
  authenticator     = "auth-otp-form"
  requirement       = "ALTERNATIVE"
  priority          = 10
}

resource "keycloak_authentication_execution" "recovery_code" {
  realm_id          = keycloak_realm.monosense.id
  parent_flow_alias = keycloak_authentication_subflow.recovery_second_factor.alias
  authenticator     = "recovery-authn-code-form"
  requirement       = "ALTERNATIVE"
  priority          = 20
}

resource "keycloak_authentication_bindings" "monosense" {
  realm_id     = keycloak_realm.monosense.id
  browser_flow = keycloak_authentication_flow.browser.alias
}

resource "keycloak_role" "platform_admin" {
  realm_id    = keycloak_realm.monosense.id
  name        = "platform-admin"
  description = "Human platform administrators"
}

resource "keycloak_role" "platform_operator" {
  realm_id    = keycloak_realm.monosense.id
  name        = "platform-operator"
  description = "Human platform operators"
}

resource "keycloak_group" "platform" {
  realm_id = keycloak_realm.monosense.id
  name     = "platform"
}

resource "keycloak_group" "administrators" {
  realm_id  = keycloak_realm.monosense.id
  name      = "administrators"
  parent_id = keycloak_group.platform.id
}

resource "keycloak_group_roles" "administrators" {
  realm_id = keycloak_realm.monosense.id
  group_id = keycloak_group.administrators.id
  role_ids = [keycloak_role.platform_admin.id]
}

resource "keycloak_group" "ui_access" {
  for_each = toset(["ceph-users", "alertmanager-users", "vlogs-users", "memini-users", "grafana-admins"])

  realm_id  = keycloak_realm.monosense.id
  parent_id = keycloak_group.platform.id
  name      = each.value
}

resource "keycloak_user" "human_admin" {
  realm_id       = keycloak_realm.monosense.id
  username       = var.human_admin_username
  email          = var.human_admin_email
  email_verified = true
  enabled        = true
  initial_password {
    value     = var.human_admin_initial_password
    temporary = true
  }
  required_actions = [
    "CONFIGURE_TOTP",
    "CONFIGURE_RECOVERY_AUTHN_CODES",
    "webauthn-register-passwordless",
    "UPDATE_PASSWORD",
  ]
}

resource "keycloak_user_groups" "human_admin" {
  realm_id = keycloak_realm.monosense.id
  user_id  = keycloak_user.human_admin.id
  group_ids = concat(
    [keycloak_group.administrators.id],
    [for group in keycloak_group.ui_access : group.id],
  )
}

locals {
  browser_clients = {
    ceph = {
      secret       = var.ceph_client_secret
      redirect_uri = "https://ceph.monosense.io/oauth2/callback"
    }
    alertmanager = {
      secret       = var.alertmanager_client_secret
      redirect_uri = "https://alertmanager.monosense.io/oauth2/callback"
    }
    victorialogs = {
      secret       = var.victorialogs_client_secret
      redirect_uri = "https://vlogs.monosense.io/oauth2/callback"
    }
    memini = {
      secret       = var.memini_client_secret
      redirect_uri = "https://memini.monosense.io/oauth2/callback"
    }
    grafana = {
      secret       = var.grafana_client_secret
      redirect_uri = "https://grafana.monosense.io/login/generic_oauth"
    }
  }
}

resource "keycloak_openid_client" "browser" {
  for_each = local.browser_clients

  realm_id                        = keycloak_realm.monosense.id
  client_id                       = each.key
  name                            = each.key
  enabled                         = true
  access_type                     = "CONFIDENTIAL"
  client_secret                   = each.value.secret
  standard_flow_enabled           = true
  direct_access_grants_enabled    = false
  implicit_flow_enabled           = false
  service_accounts_enabled        = false
  valid_redirect_uris             = [each.value.redirect_uri]
  valid_post_logout_redirect_uris = [replace(each.value.redirect_uri, "/oauth2/callback", "/"), replace(each.value.redirect_uri, "/login/generic_oauth", "/")]
  web_origins                     = [replace(each.value.redirect_uri, "/oauth2/callback", ""), replace(each.value.redirect_uri, "/login/generic_oauth", "")]
  access_token_lifespan           = "5m"
}

resource "keycloak_openid_group_membership_protocol_mapper" "browser" {
  for_each = keycloak_openid_client.browser

  realm_id            = keycloak_realm.monosense.id
  client_id           = each.value.id
  name                = "groups"
  claim_name          = "groups"
  full_path           = true
  add_to_id_token     = true
  add_to_access_token = true
  add_to_userinfo     = true
}
