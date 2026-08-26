#!/usr/bin/env bash
set -euo pipefail

project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$project_dir"
# shellcheck source=toolchain.sh
source scripts/toolchain.sh
[[ $# -eq 0 ]] || { echo "verify does not accept trailing arguments" >&2; exit 2; }
require_private_dir .build
candidate=".build/srx1500.set"
[[ -f "$candidate" && ! -L "$candidate" ]] || {
  echo "Missing reviewed candidate; rerun deployment workflow" >&2
  exit 1
}
require_mise_tools ansible-playbook yq
adoption_file="$project_dir/adoption.yml"
[[ -f "$adoption_file" && ! -L "$adoption_file" ]] || {
  echo "Fixed tracked adoption record is missing or unsafe" >&2
  exit 1
}
yq -e '.adopted == true' "$adoption_file" >/dev/null || {
  echo "Verification is disabled until the fixed adoption record is true" >&2
  exit 1
}
digest="$(sha256_file "$candidate")"
ansible-playbook playbooks/verify.yml -e "junos_expected_digest=$digest"
echo "Read-only verification succeeded for candidate SHA-256: $digest"
read -r -p "Type 'confirm $digest' to confirm the pending Junos commit: " answer
[[ "$answer" == "confirm $digest" ]] || {
  echo "Confirmation mismatch; the pending commit remains unconfirmed" >&2
  exit 1
}
ansible-playbook playbooks/confirm.yml \
  -e "junos_commit_comment=Ansible candidate $digest" \
  -e "junos_expected_digest=$digest"
