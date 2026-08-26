#!/usr/bin/env bash
set -euo pipefail
project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$project_dir"
# shellcheck source=toolchain.sh
source scripts/toolchain.sh
[[ $# -eq 0 ]] || { echo "deploy does not accept trailing arguments" >&2; exit 2; }
adoption_file="$project_dir/adoption.yml"
[[ -f "$adoption_file" && ! -L "$adoption_file" ]] || {
  echo "Fixed tracked adoption record is missing or unsafe" >&2
  exit 1
}
[[ "$(git -C "$project_dir" ls-files --error-unmatch -- adoption.yml 2>/dev/null)" == "adoption.yml" ]] || {
  echo "Fixed adoption record is not tracked" >&2
  exit 1
}
require_mise_tools yq ansible-playbook
yq -e '.adopted == true' "$adoption_file" >/dev/null || {
  echo "Routine deployment is disabled until the fixed adoption record is true" >&2
  exit 1
}
candidate_path="$project_dir/.build/srx1500.set"
render_result="$(scripts/render.sh --check 2>&1 >/dev/null)"
emitted_digest="$(printf '%s\n' "$render_result" | sed -n 's/^sha256://p')"
[[ -f "$candidate_path" && ! -L "$candidate_path" ]] || {
  echo "Renderer did not produce a regular candidate artifact" >&2
  exit 1
}
digest="$(sha256_file "$candidate_path")"
[[ "$emitted_digest" == "$digest" && "$digest" =~ ^[0-9a-f]{64}$ ]] || {
  echo "Renderer output digest is missing or does not match the candidate artifact" >&2
  exit 1
}
echo "Target hostname: srx1500"
echo "Candidate SHA-256: $digest"
read -r -p "Type 'srx1500 $digest' to deploy with commit-confirmed: " answer
[[ "$answer" == "srx1500 $digest" ]] || { echo "Confirmation mismatch; aborted" >&2; exit 1; }
ansible-playbook playbooks/live.yml \
  -e operation=deploy -e "junos_commit_comment=Ansible candidate $digest" \
  -e "junos_expected_digest=$digest"
