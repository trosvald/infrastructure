#!/usr/bin/env bash
set -euo pipefail

fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
for command in bao jq mktemp openssl; do
    command -v "$command" >/dev/null 2>&1 || fail "$command is required"
done
[[ -n "${BAO_ADDR:-}" && -n "${BAO_TOKEN:-}" ]] || fail 'run through scripts/with-openbao-runtime.sh'
[[ "${BAO_SKIP_VERIFY:-false}" != true ]] || fail 'OpenBao TLS verification bypasses are forbidden'
: "${TELEGRAM_BOT_TOKEN:?set TELEGRAM_BOT_TOKEN}"
: "${TELEGRAM_CHAT_ID:?set TELEGRAM_CHAT_ID}"
: "${SNMP_USERNAME:?set SNMP_USERNAME}"
: "${SNMP_AUTH_PASSWORD:?set SNMP_AUTH_PASSWORD}"
: "${SNMP_PRIV_PASSWORD:?set SNMP_PRIV_PASSWORD}"
[[ "$TELEGRAM_BOT_TOKEN" =~ ^[0-9]+:[A-Za-z0-9_-]{30,}$ ]] || fail 'Telegram bot token is malformed'
[[ "$TELEGRAM_CHAT_ID" =~ ^-?[0-9]+$ ]] || fail 'Telegram chat ID is malformed'
[[ "$SNMP_USERNAME" =~ ^[A-Za-z0-9._-]{3,32}$ ]] || fail 'SNMPv3 username is malformed'
(( ${#SNMP_AUTH_PASSWORD} >= 16 && ${#SNMP_PRIV_PASSWORD} >= 16 )) || fail 'SNMPv3 passwords must be at least 16 characters'

readonly grafana_record='platform/kubernetes/observability/grafana'
readonly alertmanager_record='platform/kubernetes/observability/alertmanager'
readonly snmp_record='platform/kubernetes/observability/snmp'
readonly tofu_record='platform/kubernetes/security/keycloak-tofu'
readonly c0_record='docker/c0/monitoring'
readonly c1_record='docker/c1/edge'
work="$(mktemp -d)"
chmod 0700 "$work"
created=()
updated=()
cleanup() {
    rc=$?
    if (( rc != 0 )); then
        for record in "${created[@]}"; do
            bao kv metadata delete -mount=kv "$record" >/dev/null 2>&1 || true
        done
        for record in "${updated[@]}"; do
            name="${record//\//_}"
            version="$(jq -r '.data.metadata.version' "$work/$name-after.json" 2>/dev/null || true)"
            [[ "$version" =~ ^[0-9]+$ ]] || continue
            jq --argjson cas "$version" '{data:.data.data,options:{cas:$cas}}' \
                "$work/$name-before.json" | bao write "kv/data/$record" - >/dev/null 2>&1 || true
        done
    fi
    rm -rf "$work"
    exit "$rc"
}
trap cleanup EXIT

for record in "$grafana_record" "$alertmanager_record" "$snmp_record"; do
    ! bao kv get -mount=kv "$record" >/dev/null 2>&1 \
        || fail "$record already exists; rotate it through a separate reviewed transaction"
done
bao kv get -mount=kv -format=json "$tofu_record" >"$work/tofu.json"
grafana_secret="$(jq -er '.data.data.grafana_client_secret | select(length >= 32)' "$work/tofu.json")"
rotated_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

jq -n --arg secret "$grafana_secret" --arg rotated "$rotated_at" \
    '{data:{GF_AUTH_GENERIC_OAUTH_CLIENT_SECRET:$secret,credentials_rotated_at:$rotated},options:{cas:0}}' \
    | bao write "kv/data/$grafana_record" - >/dev/null
created+=("$grafana_record")
jq -n --arg token "$TELEGRAM_BOT_TOKEN" --arg chat "$TELEGRAM_CHAT_ID" --arg rotated "$rotated_at" \
    '{data:{telegram_bot_token:$token,telegram_chat_id:$chat,credentials_rotated_at:$rotated},options:{cas:0}}' \
    | bao write "kv/data/$alertmanager_record" - >/dev/null
created+=("$alertmanager_record")
jq -n --arg username "$SNMP_USERNAME" --arg auth "$SNMP_AUTH_PASSWORD" --arg priv "$SNMP_PRIV_PASSWORD" --arg rotated "$rotated_at" \
    '{data:{username:$username,auth_password:$auth,priv_password:$priv,auth_protocol:"SHA",priv_protocol:"AES",credentials_rotated_at:$rotated},options:{cas:0}}' \
    | bao write "kv/data/$snmp_record" - >/dev/null
created+=("$snmp_record")

for host in c0 c1; do
    cert="$work/$host-cert.json"
    bao write -format=json pki-kubernetes/issue/vector-client common_name="vector-$host" ttl=720h >"$cert"
    jq -e '.data.certificate and .data.private_key and .data.issuing_ca and .data.serial_number and .data.expiration' "$cert" >/dev/null
    printf '%s\n' "$(jq -r '.data.certificate' "$cert")" | openssl x509 -noout -checkend 1209600 >/dev/null \
        || fail "vector-$host certificate has less than 14 days remaining"
done

update_host_record() {
    local record="$1" host="$2" name before version
    name="${record//\//_}"
    before="$work/$name-before.json"
    bao kv get -mount=kv -format=json "$record" >"$before"
    version="$(jq -er '.data.metadata.version' "$before")"
    jq --argjson cas "$version" --slurpfile cert "$work/$host-cert.json" '
        {data:(.data.data + {
          vector_client_certificate:$cert[0].data.certificate,
          vector_client_private_key:$cert[0].data.private_key,
          vector_client_ca:$cert[0].data.issuing_ca,
          vector_client_serial:$cert[0].data.serial_number,
          vector_client_expiration:($cert[0].data.expiration|tostring)
        }),options:{cas:$cas}}' "$before" | bao write "kv/data/$record" - >/dev/null
    bao kv get -mount=kv -format=json "$record" >"$work/$name-after.json"
    updated+=("$record")
}
update_host_record "$c0_record" c0
update_host_record "$c1_record" c1

created=()
updated=()
printf '%s\n' 'Observability OAuth, Telegram, SNMPv3, and Vector mTLS records provisioned'
