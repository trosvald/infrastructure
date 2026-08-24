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

if [[ "$mode" == "live" ]]; then
  require_mise_tools bao jq ansible-playbook python yq
  ansible-playbook -i localhost, -c local "$project_dir/tests/controller-smoke.yml"
else
  require_mise_tools bao jq python yq
fi

expected_addr="https://vault.monosense.io"
export BAO_ADDR="${BAO_ADDR:-$expected_addr}"
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
