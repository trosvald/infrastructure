#!/usr/bin/env bash
set -euo pipefail
project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$project_dir"
scripts/render.sh --check 2> .build/render.digest
digest="$(sed -n 's/^sha256://p' .build/render.digest)"
[[ -n "$digest" ]] || { echo "Renderer did not produce a candidate digest" >&2; exit 1; }
echo "Target hostname: srx1500"
echo "Candidate SHA-256: $digest"
read -r -p "Type 'srx1500 $digest' to deploy with commit-confirmed: " answer
[[ "$answer" == "srx1500 $digest" ]] || { echo "Confirmation mismatch; aborted" >&2; exit 1; }
ansible-playbook playbooks/live.yml \
  -e operation=deploy -e "junos_commit_comment=Ansible candidate $digest" "$@"
