#!/usr/bin/env bash
set -euo pipefail
project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$project_dir"
export ANSIBLE_CONFIG="$project_dir/ansible.cfg"
export ANSIBLE_LOCAL_TEMP="$project_dir/.build/tmp/controller"
export PYTHONDONTWRITEBYTECODE=1
# shellcheck source=toolchain.sh
source scripts/toolchain.sh
require_private_dir .build
require_private_dir .build/tmp
require_private_dir .build/tmp/controller

action="${1:-}"
[[ -n "$action" ]] && shift || true
[[ $# -eq 0 ]] || {
  printf 'container-nodes actions do not accept trailing arguments\n' >&2
  exit 2
}

run_playbook() {
  require_tool ansible-playbook
  exec ansible-playbook "$@"
}

case "$action" in
  bootstrap) exec scripts/bootstrap.sh ;;
  test) exec scripts/test.sh ;;
  lint) exec scripts/lint.sh ;;
  audit) run_playbook playbooks/audit.yml ;;
  check) run_playbook --check playbooks/check.yml ;;
  diff) run_playbook --check --diff playbooks/check.yml -e container_nodes_action=diff ;;
  deploy) run_playbook playbooks/deploy.yml ;;
  verify) run_playbook playbooks/verify.yml ;;
  drift) run_playbook --check playbooks/drift.yml ;;
  provision-storage) run_playbook playbooks/provision-storage.yml ;;
  provision-secrets) run_playbook playbooks/provision-secrets.yml ;;
  prepare-applications) run_playbook playbooks/prepare-applications.yml ;;
  rollout-applications) run_playbook playbooks/rollout-applications.yml ;;
  rotate-secrets) run_playbook playbooks/rotate-secrets.yml ;;
  activate-network) run_playbook playbooks/activate-network.yml ;;
  upgrade) run_playbook playbooks/upgrade.yml ;;
  reboot) run_playbook playbooks/reboot.yml ;;
  *)
    printf 'Unknown container-nodes action: %s\n' "${action:-<missing>}" >&2
    printf '%s\n' 'Supported actions: bootstrap test lint audit check diff deploy verify drift provision-storage provision-secrets rotate-secrets prepare-applications rollout-applications activate-network upgrade reboot'
    exit 2
    ;;
esac
