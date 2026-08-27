#!/usr/bin/env bash
set -euo pipefail

project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export ANSIBLE_CONFIG="$project_dir/ansible.cfg"
export ANSIBLE_LOCAL_TEMP="$project_dir/.build/tmp/controller"
export ANSIBLE_REMOTE_TEMP="$project_dir/.build/tmp/remote"
# shellcheck source=toolchain.sh
source "$project_dir/scripts/toolchain.sh"
cd "$project_dir"

mode="${1:-}"
[[ "$mode" == "topology" || "$mode" == "live" ]] || {
  echo "usage: with-openbao-runtime.sh topology|live command [args...]" >&2
  exit 2
}
shift
[[ $# -gt 0 ]] || { echo "runtime command is required" >&2; exit 2; }
case "$mode" in
  topology)
    [[ $# -eq 2 && "$1" == "scripts/render.sh" && "$2" == "--check" ]] || {
      echo "topology runtime permits only the protected render action" >&2
      exit 2
    }
    ;;
  live)
    case "${1:-}" in
      scripts/deploy.sh|scripts/verify.sh|scripts/backup.sh)
        [[ $# -eq 1 ]] || { echo "live scripts do not accept trailing arguments" >&2; exit 2; }
        ;;
      ansible-playbook)
        if [[ $# -eq 4 && "$2" == "playbooks/live.yml" && "$3" == "-e" &&
          ( "$4" == "operation=check" || "$4" == "operation=diff" ) ]]; then
          :
        elif [[ $# -eq 5 && "$2" == "--diff" && "$3" == "playbooks/live.yml" && "$4" == "-e" && "$5" == "operation=diff" ]]; then
          :
        elif [[ $# -eq 2 && "$2" == "playbooks/drift.yml" ]]; then
          :
        else
          echo "live runtime received an unapproved Ansible action" >&2
          exit 2
        fi
        ;;
      *)
        echo "live runtime received an unapproved action" >&2
        exit 2
        ;;
    esac
    ;;
esac

adoption_file="$project_dir/adoption.yml"
if [[ "$mode" == "live" && "${1:-}" == "scripts/deploy.sh" ]]; then
  require_mise_tools yq
  [[ -f "$adoption_file" && ! -L "$adoption_file" ]] || {
    echo "Fixed tracked adoption record is missing or unsafe" >&2
    exit 1
  }
  [[ "$(git -C "$project_dir" ls-files --error-unmatch -- adoption.yml 2>/dev/null)" == "adoption.yml" ]] || {
    echo "Fixed adoption record is not tracked" >&2
    exit 1
  }
  git -C "$project_dir" diff --quiet HEAD -- adoption.yml || {
    echo "Fixed adoption record has uncommitted changes" >&2
    exit 1
  }
  git -C "$project_dir" show HEAD:ansible/junos/adoption.yml |
    yq -e '.adopted == true' - >/dev/null || {
    echo "Routine deployment is disabled until the fixed adoption record is true" >&2
    exit 1
  }
fi


[[ -z "${BAO_SKIP_VERIFY:-}" && -z "${VAULT_SKIP_VERIFY:-}" ]] || {
  echo "TLS verification bypass variables are prohibited for OpenBao" >&2
  exit 1
}
[[ -z "${BAO_TLS_SERVER_NAME:-}" && -z "${VAULT_TLS_SERVER_NAME:-}" ]] || {
  echo "Unreviewed OpenBao TLS server-name overrides are prohibited" >&2
  exit 1
}
expected_addr="https://vault.monosense.io:8200"
export BAO_ADDR="${BAO_ADDR:-$expected_addr}"
if [[ "$mode" == "live" ]]; then
  require_mise_tools bao jq ansible-playbook python yq
  ansible-playbook -i localhost, -c local "$project_dir/tests/controller-smoke.yml"
else
  require_mise_tools bao jq python yq
fi
[[ "$BAO_ADDR" == "$expected_addr" ]] || {
  echo "BAO_ADDR must be $expected_addr" >&2
  exit 1
}

bao token lookup -format=json >/dev/null || {
  echo "No valid OpenBao CLI session. Authenticate first with: bao login" >&2
  exit 1
}

runtime_dir="$(mktemp -d "${TMPDIR:-/tmp}/junos-runtime.XXXXXX")"
[[ -d "$runtime_dir" && "$runtime_dir" == *junos-runtime.* ]] || {
  echo "Failed to create a safe Junos runtime directory" >&2
  exit 1
}
chmod 0700 "$runtime_dir"
cleanup() {
  find "$runtime_dir" -type f -exec chmod 0600 {} + 2>/dev/null || true
  rm -rf -- "$runtime_dir"
}
trap cleanup EXIT
trap 'exit 130' HUP INT TERM

topology_raw="$runtime_dir/topology-response.json"
topology_file="$runtime_dir/topology.json"
bao kv get -mount=kv -format=json network/junos/srx1500/topology > "$topology_raw"
chmod 0600 "$topology_raw"

jq -e '
  .data.data as $t |
  ($t | type == "object") and
  ($t.management_address | type == "string" and test("^[A-Za-z0-9](?:[A-Za-z0-9._-]*[A-Za-z0-9])?$")) and
  ($t.netconf_host_key | type == "object") and
  ($t.netconf_host_key.type | test("^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp(256|384|521))$")) and
  ($t.netconf_host_key.key | type == "string" and test("^[A-Za-z0-9+/]+={0,2}$")) and
  ($t.backup_age_recipient | type == "string" and test("^age1[0-9a-z]+$"))
' "$topology_raw" >/dev/null || {
  echo "OpenBao topology record is missing a valid address, SSH host key, or backup age recipient" >&2
  exit 1
}

jq -e '.data.data | del(.netconf_host_key, .backup_age_recipient)' "$topology_raw" > "$topology_file"
chmod 0600 "$topology_file"
export JUNOS_TOPOLOGY_FILE="$topology_file"
export JUNOS_MANAGEMENT_ADDRESS
export JUNOS_BACKUP_AGE_RECIPIENT
JUNOS_MANAGEMENT_ADDRESS="$(jq -er '.data.data.management_address' "$topology_raw")"
JUNOS_BACKUP_AGE_RECIPIENT="$(jq -er '.data.data.backup_age_recipient' "$topology_raw")"

if [[ "$mode" == "live" ]]; then
  netconf_raw="$runtime_dir/netconf-response.json"
  private_key="$runtime_dir/netconf-key"
  known_hosts="$runtime_dir/known_hosts"
  ssh_config="$runtime_dir/ssh_config"
  bao kv get -mount=kv -format=json network/junos/srx1500/netconf > "$netconf_raw"
  chmod 0600 "$netconf_raw"
  jq -e '
    .data.data as $n |
    ($n | type == "object") and
    ($n.username | type == "string" and length > 0 and test("^[^[:space:]]+$")) and
    ($n.private_key | type == "string" and test("^-----BEGIN (OPENSSH |RSA |EC )?PRIVATE KEY-----"))
  ' "$netconf_raw" >/dev/null || {
    echo "OpenBao NETCONF record is missing a valid username or SSH private key" >&2
    exit 1
  }

  jq -er '.data.data.private_key' "$netconf_raw" > "$private_key"
  host_key_type="$(jq -er '.data.data.netconf_host_key.type' "$topology_raw")"
  host_key="$(jq -er '.data.data.netconf_host_key.key' "$topology_raw")"
  printf '[%s]:830 %s %s\n' "$JUNOS_MANAGEMENT_ADDRESS" "$host_key_type" "$host_key" > "$known_hosts"
  printf 'Host *\n  StrictHostKeyChecking yes\n  UserKnownHostsFile "%s"\n' "$known_hosts" > "$ssh_config"
  chmod 0600 "$private_key" "$known_hosts" "$ssh_config"

  export JUNOS_NETCONF_USERNAME
  export JUNOS_NETCONF_PRIVATE_KEY_FILE="$private_key"
  export JUNOS_NETCONF_SSH_CONFIG="$ssh_config"
  JUNOS_NETCONF_USERNAME="$(jq -er '.data.data.username' "$netconf_raw")"
fi

"$@"
