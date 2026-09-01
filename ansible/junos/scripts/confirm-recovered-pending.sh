#!/usr/bin/env bash
set -euo pipefail

project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$project_dir"
# shellcheck source=toolchain.sh
source scripts/toolchain.sh
require_mise_tools python ansible-playbook

candidate_path="${JUNOS_CANDIDATE_FILE:?protected candidate path is required}"
render_result="$(scripts/render.sh --check 2>&1 >/dev/null)"
candidate_digest="$(printf '%s\n' "$render_result" | sed -n 's/^sha256://p')"
[[ -f "$candidate_path" && ! -L "$candidate_path" ]] || {
    echo "Renderer did not produce a regular candidate artifact" >&2
    exit 1
}
[[ "$(sha256_file "$candidate_path")" == "$candidate_digest" && "$candidate_digest" =~ ^[0-9a-f]{64}$ ]] || {
    echo "Renderer did not produce the reported candidate digest" >&2
    exit 1
}
read -r -p "Failed pending candidate SHA-256: " pending_digest
[[ "$pending_digest" =~ ^[0-9a-f]{64}$ && "$pending_digest" != "$candidate_digest" ]] || {
    echo "Recovery requires a distinct lowercase pending SHA-256 digest" >&2
    exit 2
}
echo "Corrected reviewed candidate SHA-256: $candidate_digest"
read -r -p "Type 'confirm-recovered $pending_digest as $candidate_digest' to verify and confirm it: " answer
[[ "$answer" == "confirm-recovered $pending_digest as $candidate_digest" ]] || {
    echo "Recovery confirmation mismatch; pending commit remains unconfirmed" >&2
    exit 1
}
ansible-playbook playbooks/confirm.yml -e "{\"junos_commit_comment\":\"Ansible candidate $pending_digest\",\"junos_expected_digest\":\"$pending_digest\",\"junos_candidate_digest\":\"$candidate_digest\"}"
echo "Verified corrected candidate $candidate_digest and confirmed pending candidate $pending_digest"
