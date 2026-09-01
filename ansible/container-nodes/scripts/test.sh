#!/usr/bin/env bash
set -euo pipefail
project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$project_dir"
# shellcheck source=toolchain.sh
source scripts/toolchain.sh
require_tool python ansible-playbook
python -m unittest discover -s tests -p 'test_*.py' -v
while IFS= read -r test_script; do
  bash "$test_script"
done < <(find tests roles -type f -path '*/tests/*.sh' -print | LC_ALL=C sort)
