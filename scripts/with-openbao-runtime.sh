#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_dir"

[[ $# -gt 0 ]] || {
    echo "usage: with-openbao-runtime.sh command [args...]" >&2
    exit 2
}

case "$1" in
    ansible/junos/scripts/with-openbao-runtime.sh)
        [[ "${2:-}" == "--authenticated" ]] || {
            echo "Junos runtime must use the authenticated internal entry point" >&2
            exit 2
        }
        ;;
    scripts/provision-junos-edge-topology.sh)
        [[ $# == 1 ]] || {
            echo "Junos EDGE topology provisioner accepts no arguments" >&2
            exit 2
        }
        ;;
    talos/scripts/render.sh)
        [[ "${2:-}" == "--authenticated" ]] || {
            echo "Talos runtime must use the authenticated internal entry point" >&2
            exit 2
        }
        ;;
    bootstrap/scripts/cluster.sh)
        [[ "${2:-}" == "--authenticated" ]] || {
            echo "Bootstrap runtime must use the authenticated internal entry point" >&2
            exit 2
        }
        ;;
    *)
        echo "OpenBao runtime received an unapproved action" >&2
        exit 2
        ;;
esac

[[ -z "${BAO_TOKEN:-}" && -z "${VAULT_TOKEN:-}" ]] || {
    echo "Preexisting OpenBao tokens are prohibited" >&2
    exit 1
}
[[ -z "${BAO_SKIP_VERIFY:-}" && -z "${VAULT_SKIP_VERIFY:-}" ]] || {
    echo "TLS verification bypass variables are prohibited for OpenBao" >&2
    exit 1
}
[[ -z "${BAO_TLS_SERVER_NAME:-}" && -z "${VAULT_TLS_SERVER_NAME:-}" ]] || {
    echo "Unreviewed OpenBao TLS server-name overrides are prohibited" >&2
    exit 1
}

expected_addr="https://vault.monosense.io:8200"
export BAO_ADDR="${BAO_ADDR:-$expected_addr}"
[[ "$BAO_ADDR" == "$expected_addr" ]] || {
    echo "BAO_ADDR must be $expected_addr" >&2
    exit 1
}

require_locked_tool() {
    local executable="$1"
    command -v "$executable" >/dev/null 2>&1 || {
        echo "missing locked executable: $executable; run: mise install --locked" >&2
        return 1
    }
}

for tool in bao jq sops; do
    require_locked_tool "$tool"
done
export SOPS_AGE_KEY_FILE="${SOPS_AGE_KEY_FILE:-$HOME/.config/sops/age/keys.txt}"
[[ -f "$SOPS_AGE_KEY_FILE" && ! -L "$SOPS_AGE_KEY_FILE" ]] || {
    echo "SOPS age identity is missing or unsafe: $SOPS_AGE_KEY_FILE" >&2
    exit 1
}


credentials_source="$repo_dir/encrypted/monosense-infra.env"
[[ -f "$credentials_source" && ! -L "$credentials_source" ]] || {
    echo "Tracked encrypted credentials are missing or unsafe: encrypted/monosense-infra.env" >&2
    exit 1
}

umask 077
runtime_dir="$(mktemp -d "${TMPDIR:-/tmp}/monosense-infra-runtime.XXXXXX")"
[[ -d "$runtime_dir" && ! -L "$runtime_dir" && "$runtime_dir" == *monosense-infra-runtime.* ]] || {
    echo "Failed to create a safe OpenBao runtime directory" >&2
    exit 1
}
chmod 0700 "$runtime_dir"
credentials_json="$runtime_dir/credentials.json"
token_active=false
cleanup() {
    local status=$?
    unset BAO_PASSWORD
    if [[ "$token_active" == true && -n "${BAO_TOKEN:-}" ]]; then
        bao token revoke -self >/dev/null 2>&1 || true
    fi
    unset BAO_TOKEN
    chmod -R u=rwX,go= "$runtime_dir" 2>/dev/null || true
    rm -rf -- "$runtime_dir"
    exit "$status"
}
trap cleanup EXIT
trap 'exit 130' HUP INT TERM

sops decrypt --input-type dotenv --output-type json "$credentials_source" > "$credentials_json"
chmod 0600 "$credentials_json"
jq -e '
    type == "object" and
    (keys | sort) == ["BAO_PASSWORD", "BAO_USERNAME"] and
    .BAO_USERNAME == "monosense-infra" and
    (.BAO_PASSWORD | type == "string" and length >= 32 and test("^[A-Za-z0-9_-]+$"))
' "$credentials_json" >/dev/null || {
    echo "Encrypted credentials must contain exactly BAO_USERNAME=monosense-infra and a valid BAO_PASSWORD" >&2
    exit 1
}

export BAO_TOKEN
BAO_TOKEN="$(jq '{password: .BAO_PASSWORD}' "$credentials_json" |
    bao write -field=token auth/userpass/login/monosense-infra -)"
unset BAO_PASSWORD
[[ "$BAO_TOKEN" =~ ^hvs\.[A-Za-z0-9_-]+$ || "$BAO_TOKEN" =~ ^s\.[A-Za-z0-9_-]+$ ]] || {
    unset BAO_TOKEN
    echo "OpenBao did not return a valid short-lived token" >&2
    exit 1
}
token_active=true
export OPENBAO_RUNTIME_DIR="$runtime_dir"

"$@"
