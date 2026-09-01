#!/usr/bin/env bash
set -euo pipefail

project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$project_dir"
# shellcheck source=toolchain.sh
source scripts/toolchain.sh
require_mise_tools ansible-playbook

read -r -p "Pending candidate SHA-256 to roll back: " digest
[[ "$digest" =~ ^[0-9a-f]{64}$ ]] || {
    echo "Expected a lowercase SHA-256 digest" >&2
    exit 2
}
read -r -p "Type 'rollback-pending $digest' to restore the preceding configuration: " answer
[[ "$answer" == "rollback-pending $digest" ]] || {
    echo "Rollback authorization mismatch; pending commit remains unchanged" >&2
    exit 1
}
ansible-playbook playbooks/rollback-pending.yml -e "{\"junos_expected_digest\":\"$digest\"}"
echo "Rolled back pending candidate SHA-256: $digest"
