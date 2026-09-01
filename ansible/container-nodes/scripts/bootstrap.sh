#!/usr/bin/env bash
set -euo pipefail
project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$project_dir"
# shellcheck source=toolchain.sh
source scripts/toolchain.sh
require_tool python ansible ansible-playbook ansible-galaxy ansible-doc
[[ "$(python -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')" == 3.13 ]] ||
  fail_toolchain 'expected locked Python 3.13'
ansible_version="$(ansible --version | sed -n '1s/.*core \([^]]*\).*/\1/p')"
[[ "$ansible_version" == 2.21.* ]] || fail_toolchain "expected ansible-core 2.21, found ${ansible_version:-unknown}"
require_private_dir .ansible
require_private_dir .ansible/collections
require_private_dir .build
require_private_dir .build/tmp
require_private_dir .build/tmp/controller
ansible-galaxy collection install -r ../requirements.yml -p .ansible/collections
ansible-doc -t module ansible.posix.sysctl >/dev/null
ansible-doc -t module ansible.posix.mount >/dev/null
