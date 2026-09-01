#!/usr/bin/env bash
set -euo pipefail
project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$project_dir"
# shellcheck source=toolchain.sh
source scripts/toolchain.sh
require_tool ansible-playbook ansible-lint yamllint
yamllint ../../.github/workflows/container-nodes.yaml ../requirements.yml adoption.yml inventory playbooks roles tasks tests
# Roles share the public container_node_* variable namespace; role-local prefixes would duplicate that API.
ansible-lint -x var-naming[no-role-prefix] playbooks roles tasks
while IFS= read -r shell_file; do
  bash -n "$shell_file"
done < <(find scripts roles tests -type f -name '*.sh' -print | LC_ALL=C sort)
for playbook in playbooks/*.yml; do
  ansible-playbook --syntax-check "$playbook"
done
