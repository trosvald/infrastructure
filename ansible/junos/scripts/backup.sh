#!/usr/bin/env bash
set -euo pipefail

project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$project_dir"
# shellcheck source=toolchain.sh
source scripts/toolchain.sh
require_mise_tools ansible-playbook age

backup_dir="$project_dir/.build/backups"
mkdir -p -m 0700 "$backup_dir"
[[ -d "$backup_dir" && ! -L "$backup_dir" ]] || { echo "Unsafe backup directory" >&2; exit 1; }
chmod 0700 "$backup_dir"
candidate="$backup_dir/srx1500-$(date -u +%Y%m%dT%H%M%SZ).conf.age"
[[ ! -e "$candidate" ]] || { echo "Backup name collision; retry after the current UTC second" >&2; exit 1; }
output="$candidate"
completed=false
cleanup() {
  if [[ "$completed" != true ]]; then
    rm -f -- "$output"
  fi
}
trap cleanup EXIT
trap 'exit 130' HUP INT TERM

export JUNOS_BACKUP_OUTPUT="$output"
[[ $# -eq 0 ]] || { echo "backup does not accept trailing arguments" >&2; exit 2; }
ansible-playbook -i localhost, -c local playbooks/backup.yml
chmod 0600 "$output"
completed=true
printf 'Encrypted backup written: %s\n' "$output"
