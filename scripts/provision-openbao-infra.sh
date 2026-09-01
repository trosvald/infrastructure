#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_dir"
[[ $# -eq 0 ]] || { echo "provision-openbao-infra accepts no arguments" >&2; exit 2; }

for tool in bao jq sops; do
    command -v "$tool" >/dev/null 2>&1 || {
        echo "missing locked executable: $tool; run: mise install --locked" >&2
        exit 1
    }
done
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
export SOPS_AGE_KEY_FILE="${SOPS_AGE_KEY_FILE:-$HOME/.config/sops/age/keys.txt}"
[[ -f "$SOPS_AGE_KEY_FILE" && ! -L "$SOPS_AGE_KEY_FILE" ]] || {
    echo "SOPS age identity is missing or unsafe: $SOPS_AGE_KEY_FILE" >&2
    exit 1
}


credentials_source="$repo_dir/encrypted/monosense-infra.env"
policy_source="$repo_dir/docker/c0/openbao/policies/monosense-infra.hcl"
service_policies=(
    wildcard-publisher
    wildcard-reader-c0
    wildcard-reader-c1
    doco-c1
)
[[ -f "$credentials_source" && ! -L "$credentials_source" ]] || {
    echo "Tracked encrypted monosense-infra credentials are missing or unsafe" >&2
    exit 1
}
[[ -f "$policy_source" && ! -L "$policy_source" ]] || {
    echo "Tracked monosense-infra policy is missing or unsafe" >&2
    exit 1
}
for policy in "${service_policies[@]}"; do
    service_policy_source="$repo_dir/docker/c0/openbao/policies/$policy.hcl"
    [[ -f "$service_policy_source" && ! -L "$service_policy_source" ]] || {
        echo "Tracked $policy policy is missing or unsafe" >&2
        exit 1
    }
done

umask 077
runtime_dir="$(mktemp -d "${TMPDIR:-/tmp}/monosense-infra-provision.XXXXXX")"
[[ -d "$runtime_dir" && ! -L "$runtime_dir" && "$runtime_dir" == *monosense-infra-provision.* ]] || {
    echo "Failed to create a safe provisioning directory" >&2
    exit 1
}
credentials_json="$runtime_dir/credentials.json"
user_payload="$runtime_dir/user.json"
infra_token=""
admin_token=""
cleanup() {
    local status=$?
    if [[ -n "$infra_token" ]]; then
        BAO_TOKEN="$infra_token" bao token revoke -self >/dev/null 2>&1 || true
    fi
    if [[ -n "$admin_token" ]]; then
        BAO_TOKEN="$admin_token" bao token revoke -self >/dev/null 2>&1 || true
    fi
    unset admin_token BAO_TOKEN
    unset infra_token
    chmod -R u=rwX,go= "$runtime_dir" 2>/dev/null || true
    rm -rf -- "$runtime_dir"
    exit "$status"
}
trap cleanup EXIT
trap 'exit 130' HUP INT TERM

tty_device=/dev/tty
[[ -r "$tty_device" && -w "$tty_device" ]] || {
    echo "monosense-admin authentication requires an interactive terminal" >&2
    exit 1
}
IFS= read -r -s -p "monosense-admin password: " admin_password < "$tty_device" || {
    printf '\n' > "$tty_device"
    echo "Failed to read monosense-admin password" >&2
    exit 1
}
printf '\n' > "$tty_device"
admin_token="$(jq -cn --arg password "$admin_password" '{password: $password}' |
    bao write -field=token auth/userpass/login/monosense-admin -)"
unset admin_password
[[ "$admin_token" =~ ^hvs\.[A-Za-z0-9_-]+$ || "$admin_token" =~ ^s\.[A-Za-z0-9_-]+$ ]] || {
    admin_token=""
    echo "OpenBao did not return a valid monosense-admin token" >&2
    exit 1
}
export BAO_TOKEN="$admin_token"
admin_lookup="$(bao token lookup -format=json)"
jq -e '.data.policies | any(. == "admin" or . == "root")' \
    <<< "$admin_lookup" >/dev/null || {
    echo "monosense-admin token does not carry the admin or root policy" >&2
    exit 1
}
bao auth list -format=json | jq -e 'has("userpass/")' >/dev/null || {
    echo "OpenBao userpass auth must already be enabled" >&2
    exit 1
}

sops decrypt --input-type dotenv --output-type json "$credentials_source" > "$credentials_json"
chmod 0600 "$credentials_json"
jq -e '
    type == "object" and
    (keys | sort) == ["BAO_PASSWORD", "BAO_USERNAME"] and
    .BAO_USERNAME == "monosense-infra" and
    (.BAO_PASSWORD | type) == "string" and
    (.BAO_PASSWORD | length) >= 32 and
    (.BAO_PASSWORD | explode | all(. >= 33 and . <= 126))
' "$credentials_json" >/dev/null || {
    echo "Encrypted credentials have an invalid schema" >&2
    exit 1
}

bao policy write monosense-infra "$policy_source" >/dev/null
for policy in "${service_policies[@]}"; do
    bao policy write "$policy" "$repo_dir/docker/c0/openbao/policies/$policy.hcl" >/dev/null
    bao write "auth/token/roles/$policy" \
        "allowed_policies=$policy" \
        orphan=true \
        renewable=true \
        token_period=24h \
        token_type=service >/dev/null
done
jq '{
    password: .BAO_PASSWORD,
    token_policies: ["monosense-infra"],
    token_ttl: "15m",
    token_max_ttl: "30m"
}' "$credentials_json" > "$user_payload"
chmod 0600 "$user_payload"
bao write auth/userpass/users/monosense-infra - < "$user_payload" >/dev/null

infra_token="$(jq '{password: .BAO_PASSWORD}' "$credentials_json" |
    bao write -field=token auth/userpass/login/monosense-infra -)"
[[ "$infra_token" =~ ^hvs\.[A-Za-z0-9_-]+$ || "$infra_token" =~ ^s\.[A-Za-z0-9_-]+$ ]] || {
    infra_token=""
    echo "OpenBao did not return a valid monosense-infra token" >&2
    exit 1
}

allowed_paths=(
    kv/data/network/junos/srx1500/netconf
    kv/data/network/junos/srx1500/admin
    kv/data/network/bgp/cilium-srx1500
    kv/data/platform/talos/bsd/topology
    kv/data/platform/talos/bsd/secrets
)
for path in "${allowed_paths[@]}"; do
    [[ "$(BAO_TOKEN="$infra_token" bao token capabilities "$path")" == "read" ]] || {
        echo "monosense-infra does not have exact read-only capability on $path" >&2
        exit 1
    }
done
[[ "$(BAO_TOKEN="$infra_token" bao token capabilities \
    kv/data/network/junos/srx1500/topology)" == "read, update" ]] || {
    echo "monosense-infra lacks exact CAS migration capability on Junos topology" >&2
    exit 1
}
managed_records=(
    docker/c1/librefs
    docker/c1/edge
    docker/c1/forgejo
    docker/c0/monitoring
    platform/tls/monosense-wildcard
)
for record in "${managed_records[@]}"; do
    [[ "$(BAO_TOKEN="$infra_token" bao token capabilities "kv/data/$record")" == \
        "create, delete, patch, read, update" ]] || {
        echo "monosense-infra does not have exact data management capability on $record" >&2
        exit 1
    }
    [[ "$(BAO_TOKEN="$infra_token" bao token capabilities "kv/metadata/$record")" == \
        "delete, read" ]] || {
        echo "monosense-infra does not have exact metadata capability on $record" >&2
        exit 1
    }
done
for role in "${service_policies[@]}"; do
    [[ "$(BAO_TOKEN="$infra_token" bao token capabilities "auth/token/create/$role")" == \
        "update" ]] || {
        echo "monosense-infra cannot create the exact $role service token" >&2
        exit 1
    }
    [[ "$(BAO_TOKEN="$infra_token" bao token capabilities "auth/token/roles/$role")" == \
        "read" ]] || {
        echo "monosense-infra cannot read the exact $role service token contract" >&2
        exit 1
    }
done
[[ "$(BAO_TOKEN="$infra_token" bao token capabilities auth/token/revoke-accessor)" == \
    "update" ]] || {
    echo "monosense-infra cannot revoke superseded scoped token accessors" >&2
    exit 1
}
for path in \
    kv/data/network/bgp/not-approved \
    kv/metadata/network/bgp/cilium-srx1500 \
    kv/data/docker/c1/not-approved \
    kv/metadata/docker/c1/not-approved \
    auth/userpass/users/monosense-infra \
    auth/token/create \
    auth/token/create/not-approved \
    sys/policies/acl/monosense-infra; do
    [[ "$(BAO_TOKEN="$infra_token" bao token capabilities "$path")" == "deny" ]] || {
        echo "monosense-infra unexpectedly has capability on $path" >&2
        exit 1
    }
done

BAO_TOKEN="$infra_token" bao token revoke -self >/dev/null
infra_token=""
echo "monosense-infra policy, userpass identity, login, TTL, and capability denials verified"
