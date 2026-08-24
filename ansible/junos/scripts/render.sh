#!/usr/bin/env bash
set -euo pipefail

project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=toolchain.sh
source "$project_dir/scripts/toolchain.sh"
topology="${JUNOS_TOPOLOGY_FILE:-}"
build_dir="$project_dir/.build"
mkdir -p -m 0700 "$build_dir"
[[ -n "$topology" && -f "$topology" ]] || {
  echo "JUNOS_TOPOLOGY_FILE must reference topology materialized by OpenBao or the synthetic test fixture" >&2
  exit 1
}
require_mise_tools python yq
python scripts/junos_intent.py \
  --intent-dir host_vars/srx1500/intent \
  --topology "$topology" --output .build/srx1500.set "$@"
