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
git -C "$project_dir" diff --quiet HEAD -- adoption.yml || {
  echo "Fixed adoption record has uncommitted changes" >&2
  exit 1
}
require_mise_tools yq ansible-playbook
git -C "$project_dir" show HEAD:ansible/junos/adoption.yml |
  yq -e '.adopted == true' - >/dev/null || {
  echo "Routine deployment is disabled until the fixed adoption record is true" >&2
  exit 1
}
candidate_path="${JUNOS_CANDIDATE_FILE:-}"
[[ -n "$candidate_path" && "$candidate_path" == "$OPENBAO_RUNTIME_DIR/"* ]] || {
  echo "Deployment candidate must be inside the protected OpenBao runtime" >&2
  exit 1
}
render_result="$(scripts/render.sh --check 2>&1 >/dev/null)"
emitted_digest="$(printf '%s\n' "$render_result" | sed -n 's/^sha256://p')"
[[ -f "$candidate_path" && ! -L "$candidate_path" ]] || {
  echo "Renderer did not produce a regular candidate artifact" >&2
  exit 1
}
chmod 0600 "$candidate_path"
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
  -e operation=deploy -e "junos_intent_commit_comment=Ansible candidate $digest" \
  -e "junos_expected_digest=$digest"
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
