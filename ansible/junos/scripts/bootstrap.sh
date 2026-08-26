#!/usr/bin/env bash
set -euo pipefail

project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$project_dir"
# shellcheck source=toolchain.sh
source scripts/toolchain.sh
require_mise_tools python ansible ansible-playbook ansible-galaxy ansible-doc yq

[[ "$(python -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')" == "3.13" ]] || {
  echo "Expected the locked Python 3.13 compatibility line" >&2
  exit 1
}
ansible_version="$(ansible --version | sed -n '1s/.*core \([^]]*\).*/\1/p')"
[[ "$ansible_version" == 2.21.* ]] || {
  echo "Expected the locked ansible-core 2.21 compatibility line, found ${ansible_version:-unknown}" >&2
  exit 1
}

mkdir -p -m 0700 .build/tmp/controller .build/tmp/remote .ansible/collections
ansible-galaxy collection install -r requirements.yml -p .ansible/collections
ansible-galaxy collection list
ansible-doc -t module juniper.device.junos_config >/dev/null
ansible-doc -t module juniper.device.junos_facts >/dev/null
ansible-doc -t module juniper.device.junos_command >/dev/null
ansible-playbook -i localhost, -c local tests/controller-smoke.yml
