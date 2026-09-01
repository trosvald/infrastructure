#!/usr/bin/env bash
set -euo pipefail

project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$project_dir"
export ANSIBLE_CONFIG="$project_dir/ansible.cfg"
export ANSIBLE_LOCAL_TEMP="$project_dir/.build/tmp/controller"
export ANSIBLE_REMOTE_TEMP="$project_dir/.build/tmp/remote"
export PYTHONDONTWRITEBYTECODE=1
# shellcheck source=toolchain.sh
source scripts/toolchain.sh

require_private_dir .build
require_private_dir .build/tmp
require_private_dir .build/tmp/controller
require_private_dir .build/tmp/remote

action="${1:-}"
[[ -n "$action" ]] && shift || true
[[ $# -eq 0 ]] || {
  echo "Junos actions do not accept trailing arguments" >&2
  exit 2
}


case "$action" in
  bootstrap)
    exec scripts/bootstrap.sh
    ;;
  lint)
    require_mise_tools python ansible-playbook ansible-lint yamllint
    yaml_targets=(../requirements.yml inventory playbooks roles)
    yamllint "${yaml_targets[@]}"
    ansible-lint playbooks
    for playbook in playbooks/*.yml tests/controller-smoke.yml; do
      ansible-playbook --syntax-check "$playbook"
    done
    ;;
  test)
    require_mise_tools python yq
    export JUNOS_TOPOLOGY_FILE="$project_dir/tests/topology.yml"
    python -m unittest discover -s tests -v
    scripts/render.sh --check
    first="$(sha256_file .build/srx1500.set)"
    scripts/render.sh --check
    second="$(sha256_file .build/srx1500.set)"
    [[ "$first" == "$second" ]] || { echo "render is not deterministic" >&2; exit 1; }
    ;;
  render)
    exec scripts/with-openbao-runtime.sh topology scripts/render.sh --check
    ;;
  check)
    require_mise_tools ansible-playbook
    exec scripts/with-openbao-runtime.sh live ansible-playbook playbooks/live.yml -e operation=check
    ;;
  diff)
    require_mise_tools ansible-playbook
    scripts/with-openbao-runtime.sh live ansible-playbook --diff playbooks/live.yml -e operation=diff
    exec less .build/srx1500.diff
    ;;
  pki-bootstrap)
    require_mise_tools ansible-playbook
    exec scripts/with-openbao-runtime.sh live ansible-playbook playbooks/pki-bootstrap.yml
    ;;
  deploy)
    require_mise_tools ansible-playbook
    exec scripts/with-openbao-runtime.sh live scripts/deploy.sh
    ;;
  confirm-pending)
    require_mise_tools ansible-playbook
    exec scripts/with-openbao-runtime.sh live scripts/confirm-pending.sh
    ;;
  rollback-pending)
    require_mise_tools ansible-playbook
    exec scripts/with-openbao-runtime.sh live scripts/rollback-pending.sh
    ;;
  myrep-preflight)
    require_mise_tools ansible-playbook
    exec scripts/with-openbao-runtime.sh live ansible-playbook playbooks/myrep-preflight.yml
    ;;
  operational-verify)
    require_mise_tools ansible-playbook
    exec scripts/with-openbao-runtime.sh live ansible-playbook playbooks/operational-verify.yml
    ;;
  precutover-baseline)
    require_mise_tools ansible-playbook
    exec scripts/with-openbao-runtime.sh live ansible-playbook playbooks/precutover-baseline.yml
    ;;
  syslog-verify)
    require_mise_tools ansible-playbook
    exec scripts/with-openbao-runtime.sh live ansible-playbook playbooks/syslog-verify.yml
    ;;
  bgp-preflight)
    require_mise_tools ansible-playbook
    exec scripts/with-openbao-runtime.sh live ansible-playbook playbooks/bgp-preflight.yml
    ;;
  bgp-verify)
    require_mise_tools ansible-playbook
    exec scripts/with-openbao-runtime.sh live ansible-playbook playbooks/bgp-verify.yml
    ;;
  drift)
    require_mise_tools ansible-playbook
    exec scripts/with-openbao-runtime.sh live ansible-playbook playbooks/drift.yml
    ;;
  backup)
    require_mise_tools python age
    exec scripts/with-openbao-runtime.sh live scripts/backup.sh
    ;;
  *)
    echo "Unknown Junos action: ${action:-<missing>}" >&2
    echo "Supported actions: bootstrap lint test render check diff pki-bootstrap deploy confirm-pending rollback-pending operational-verify myrep-preflight precutover-baseline syslog-verify bgp-preflight bgp-verify drift backup" >&2
    exit 2
    ;;
esac
