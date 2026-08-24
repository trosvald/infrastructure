#!/usr/bin/env bash
set -euo pipefail

project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$project_dir"
# shellcheck source=toolchain.sh
source scripts/toolchain.sh

ansible-playbook playbooks/verify.yml "$@"

[[ -f .build/srx1500.set ]] || {
  echo "Missing reviewed candidate; rerun deployment workflow" >&2
  exit 1
}
digest="$(sha256_file .build/srx1500.set)"
echo "Read-only verification succeeded for candidate SHA-256: $digest"
read -r -p "Type 'confirm $digest' to confirm the pending Junos commit: " answer
[[ "$answer" == "confirm $digest" ]] || {
  echo "Confirmation mismatch; the pending commit remains unconfirmed" >&2
  exit 1
}
ansible-playbook playbooks/confirm.yml \
  -e "junos_commit_comment=Confirm verified Ansible candidate $digest"
