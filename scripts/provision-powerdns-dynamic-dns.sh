#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_dir"
[[ $# -eq 0 ]] || { echo "provision-powerdns-dynamic-dns accepts no arguments" >&2; exit 2; }
[[ -n "${BAO_TOKEN:-}" && -n "${OPENBAO_RUNTIME_DIR:-}" ]] || {
    echo "run only through scripts/with-openbao-runtime.sh" >&2
    exit 1
}
for tool in bao jq openssl; do
    command -v "$tool" >/dev/null 2>&1 || { echo "missing locked executable: $tool" >&2; exit 1; }
done

runtime="$OPENBAO_RUNTIME_DIR/powerdns-dynamic-dns"
[[ ! -e "$runtime" ]] || { echo "protected PowerDNS runtime already exists" >&2; exit 1; }
mkdir -m 0700 "$runtime"
records=(docker/c0/powerdns platform/kubernetes/networking/external-dns)
committed=()
cleanup() {
    local status=$? record
    if (( status != 0 )); then
        for record in "${committed[@]}"; do
            bao kv metadata delete -mount=kv "$record" >/dev/null 2>&1 || true
        done
    fi
    chmod -R u=rwX,go= "$runtime" 2>/dev/null || true
    rm -rf -- "$runtime"
    exit "$status"
}
trap cleanup EXIT
trap 'exit 130' HUP INT TERM

for record in "${records[@]}"; do
    if bao kv get -mount=kv "$record" >/dev/null 2>"$runtime/error"; then
        echo "OpenBao record already exists; refusing CAS=0 bootstrap: $record" >&2
        exit 1
    fi
    [[ "$(<"$runtime/error")" == *"No value found"* ]] || {
        echo "cannot prove OpenBao record absence: $record" >&2
        exit 1
    }
done
rm -f "$runtime/error"

openssl rand -base64 32 | tr -d '\n' >"$runtime/tsig-secret"
chmod 0600 "$runtime/tsig-secret"
[[ "$(<"$runtime/tsig-secret")" =~ ^[A-Za-z0-9+/]{43}=$ ]] || {
    echo "generated TSIG secret has an invalid format" >&2
    exit 1
}
jq -n --rawfile secret "$runtime/tsig-secret" \
    '{data:{tsig_secret:$secret},options:{cas:0}}' >"$runtime/payload.json"
chmod 0600 "$runtime/payload.json"
for record in "${records[@]}"; do
    bao write "kv/data/$record" - <"$runtime/payload.json" >/dev/null
    committed+=("$record")
    bao kv get -mount=kv -format=json "$record" >"$runtime/verify.json"
    jq -e '.data.data | keys == ["tsig_secret"] and (.tsig_secret | test("^[A-Za-z0-9+/]{43}=$"))' \
        "$runtime/verify.json" >/dev/null
done
committed=()
printf '%s\n' 'PowerDNS and ExternalDNS received one shared, scoped HMAC-SHA256 TSIG identity'
