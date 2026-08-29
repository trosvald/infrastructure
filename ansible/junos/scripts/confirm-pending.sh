#!/usr/bin/env bash
set -euo pipefail

project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$project_dir"
# shellcheck source=toolchain.sh
source scripts/toolchain.sh
require_mise_tools python ansible-playbook

candidate_path="${JUNOS_CANDIDATE_FILE:?protected candidate path is required}"
render_result="$(scripts/render.sh --check 2>&1 >/dev/null)"
emitted_digest="$(printf '%s\n' "$render_result" | sed -n 's/^sha256://p')"
[[ -f "$candidate_path" && ! -L "$candidate_path" ]] || {
  echo "Renderer did not produce a regular candidate artifact" >&2
  exit 1
}
digest="$(sha256_file "$candidate_path")"
[[ "$emitted_digest" == "$digest" && "$digest" =~ ^[0-9a-f]{64}$ ]] || {
  echo "Renderer digest ${emitted_digest:-<missing>} does not match candidate digest ${digest:-<missing>}" >&2
  exit 1
}

echo "Pending candidate SHA-256: $digest"
read -r -p "Type 'confirm-pending $digest' to verify and confirm it: " answer
[[ "$answer" == "confirm-pending $digest" ]] || {
  echo "Confirmation mismatch; pending commit remains unconfirmed" >&2
  exit 1
}
ansible-playbook playbooks/confirm.yml \
  -e "{\"junos_commit_comment\":\"Ansible candidate $digest\",\"junos_expected_digest\":\"$digest\"}"
echo "Verified and confirmed pending candidate SHA-256: $digest"
