#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_dir"

[[ $# -eq 1 ]] || { echo "usage: run-container-nodes-openbao-action.sh prepare-applications|provision-secrets|recover-c0-assets|recover-c1|recover-monitoring|verify" >&2; exit 2; }
case "$1" in
  prepare-applications|provision-secrets|recover-c0-assets|recover-c1|recover-monitoring|verify) ;;
  *) echo "unsupported protected container-nodes action: $1" >&2; exit 2 ;;
esac
[[ -n "${BAO_TOKEN:-}" && -n "${OPENBAO_RUNTIME_DIR:-}" ]] || {
    echo "run only through scripts/with-openbao-runtime.sh" >&2
    exit 1
}
[[ -d "$OPENBAO_RUNTIME_DIR" && ! -L "$OPENBAO_RUNTIME_DIR" ]] || exit 1

token_file="$OPENBAO_RUNTIME_DIR/container-nodes.token"
(umask 077; printf '%s' "$BAO_TOKEN" > "$token_file")
unset BAO_TOKEN
export CONTAINER_NODES_OPENBAO_TOKEN_FILE="$token_file"

exec ansible/container-nodes/scripts/dispatch.sh "$1"
