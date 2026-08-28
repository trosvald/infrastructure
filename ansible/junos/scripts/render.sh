#!/usr/bin/env bash
set -euo pipefail

project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=toolchain.sh
source "$project_dir/scripts/toolchain.sh"
topology="${JUNOS_TOPOLOGY_FILE:-}"
output="${JUNOS_CANDIDATE_FILE:-$project_dir/.build/srx1500.set}"
if [[ -z "${JUNOS_CANDIDATE_FILE:-}" ]]; then
  require_private_dir "$project_dir/.build"
else
  [[ "$output" == "$OPENBAO_RUNTIME_DIR/"* && ! -L "$(dirname "$output")" ]] || {
    echo "Protected candidate must remain inside the OpenBao runtime directory" >&2
    exit 1
  }
fi
[[ -n "$topology" && -f "$topology" && ! -L "$topology" ]] || {
  echo "JUNOS_TOPOLOGY_FILE must reference topology materialized by OpenBao or the synthetic test fixture" >&2
  exit 1
}
require_mise_tools python yq
if [[ $# -eq 0 ]]; then
  set -- --check
fi
python scripts/junos_intent.py \
  --intent-dir intent/srx1500 \
  --topology "$topology" --output "$output" "$@"
