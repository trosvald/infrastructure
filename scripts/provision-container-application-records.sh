#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_dir"
[[ $# -eq 0 ]] || { echo "provision-container-application-records accepts no arguments" >&2; exit 2; }
[[ -n "${BAO_TOKEN:-}" && -n "${OPENBAO_RUNTIME_DIR:-}" ]] || {
    echo "run only through scripts/with-openbao-runtime.sh" >&2
    exit 1
}
[[ -d "$OPENBAO_RUNTIME_DIR" && ! -L "$OPENBAO_RUNTIME_DIR" ]] || exit 1
for tool in bao docker jq mc openssl python3 sops ssh; do
    command -v "$tool" >/dev/null 2>&1 || { echo "missing locked executable: $tool" >&2; exit 1; }
done

tty=/dev/tty
[[ -r "$tty" && -w "$tty" ]] || { echo "application record provisioning requires an interactive terminal" >&2; exit 1; }
runtime="$OPENBAO_RUNTIME_DIR/container-applications"
[[ ! -e "$runtime" ]] || { echo "protected application runtime already exists" >&2; exit 1; }
mkdir -m 0700 "$runtime"
ssh_control="${TMPDIR:-/tmp}/monosense-c1-ssh.$$"
[[ ! -e "$ssh_control" ]] || { echo "protected SSH control socket already exists" >&2; exit 1; }
cleanup() {
    local status=$?
    if [[ -e "$runtime/committed-records" ]]; then
        while IFS= read -r record; do
            bao kv metadata delete -mount=kv "$record" >/dev/null 2>&1 || true
        done < "$runtime/committed-records"
    fi
    if [[ -e "$runtime/librefs-created" ]]; then
        mc --config-dir "$runtime/mc" admin user remove local "$(<"$runtime/librefs_access_key")" \
            >/dev/null 2>&1 || true
        mc --config-dir "$runtime/mc" admin policy remove local forgejo-backups \
            >/dev/null 2>&1 || true
    fi
    if [[ -e "$runtime/ssh-tunnel" ]]; then
        ssh -S "$ssh_control" -O exit monosense@10.25.10.101 >/dev/null 2>&1 || true
    fi
    rm -f -- "$ssh_control"
    chmod -R u=rwX,go= "$runtime" 2>/dev/null || true
    rm -rf -- "$runtime"
    exit "$status"
}
trap cleanup EXIT
trap 'exit 130' HUP INT TERM

for record in docker/c0/monitoring docker/c1/edge docker/c1/forgejo platform/tls/monosense-wildcard; do
    error_file="$runtime/record-error"
    if bao kv get -mount=kv -format=json "$record" > /dev/null 2>"$error_file"; then
        echo "OpenBao record already exists; refusing CAS=0 bootstrap: $record" >&2
        exit 1
    fi
    [[ "$(<"$error_file")" == *"No value found"* ]] || {
        echo "Cannot prove OpenBao record absence: $record" >&2
        exit 1
    }
done
rm -f "$runtime/record-error"

prompt_file() {
    local label="$1" path="$2" pattern="$3" value
    IFS= read -r -s -p "$label: " value < "$tty" || { printf '\n' > "$tty"; return 1; }
    printf '\n' > "$tty"
    [[ -n "$value" && "$value" =~ $pattern ]] || { unset value; echo "invalid value for $label" >&2; return 1; }
    printf '%s' "$value" > "$path"
    chmod 0600 "$path"
    unset value
}

prompt_file "Telegram bot token" "$runtime/telegram_bot_token" '^[0-9]+:[A-Za-z0-9_-]{20,}$'
prompt_file "Telegram chat ID" "$runtime/telegram_chat_id" '^-?[0-9]+$'
prompt_file "MaxMind account ID" "$runtime/maxmind_account_id" '^[0-9]+$'
prompt_file "MaxMind license key" "$runtime/maxmind_license_key" '^[A-Za-z0-9_-]{16,}$'
prompt_file "Forgejo administrator email" "$runtime/admin_email" '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$'
prompt_file "Zoho SMTP username" "$runtime/zoho_username" '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$'
prompt_file "Zoho SMTP app password" "$runtime/zoho_password" '^[^[:space:]]{12,}$'

sops decrypt --input-type dotenv --output-type json docker/c0/openbao/encrypted/acme.env > "$runtime/acme.json"
sops decrypt --input-type ini --output-type json docker/c0/openbao/encrypted/cloudflare.ini > "$runtime/cloudflare.json"
chmod 0600 "$runtime/acme.json" "$runtime/cloudflare.json"
jq -er '.ACME_EMAIL | select(type == "string" and length > 3)' "$runtime/acme.json" > "$runtime/acme_email"
jq -er '.DEFAULT.dns_cloudflare_api_token | select(type == "string" and length > 20)' "$runtime/cloudflare.json" > "$runtime/cloudflare_token"
chmod 0600 "$runtime/acme_email" "$runtime/cloudflare_token"
printf '%s\n' 'Encrypted ACME and Cloudflare sources validated'

for name in vector_ingest_token backup_heartbeat_token crowdsec_lapi_key crowdsec_bouncer_key \
    postgres_password forgejo_secret_key forgejo_internal_token admin_password \
    kopia_repository_password librefs_access_key librefs_secret_key; do
    openssl rand -hex 32 > "$runtime/$name"
    chmod 0600 "$runtime/$name"
done
for name in forgejo_jwt_secret forgejo_lfs_jwt_secret; do
    python3 -c 'import base64, secrets; print(base64.urlsafe_b64encode(secrets.token_bytes(32)).decode().rstrip("="))' > "$runtime/$name"
    chmod 0600 "$runtime/$name"
done

bao kv get -mount=kv -format=json docker/c1/librefs > "$runtime/librefs.json"
chmod 0600 "$runtime/librefs.json"
jq -e '.data.data | keys | sort == ["root_password","root_user"] and all(.[]; type == "string" and length > 0)' \
    "$runtime/librefs.json" >/dev/null

cat > "$runtime/librefs-policy.json" <<'JSON'
{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Action":["s3:GetBucketLocation","s3:ListBucket"],"Resource":["arn:aws:s3:::forgejo-backups"]},{"Effect":"Allow","Action":["s3:GetObject","s3:PutObject","s3:DeleteObject"],"Resource":["arn:aws:s3:::forgejo-backups/*"]}]}
JSON
mkdir -m 0700 "$runtime/mc"
tunnel_port="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()')"
ssh -M -S "$ssh_control" -fN -o BatchMode=yes -o ExitOnForwardFailure=yes \
    -o StrictHostKeyChecking=yes \
    -L "127.0.0.1:$tunnel_port:10.25.13.65:9000" monosense@10.25.10.101
touch "$runtime/ssh-tunnel"
python3 - "$runtime" "$tunnel_port" <<'PY'
import json, pathlib, sys
r = pathlib.Path(sys.argv[1])
record = json.loads((r / "librefs.json").read_text())["data"]["data"]
config = {"version":"10","aliases":{"local":{"url":f"http://127.0.0.1:{sys.argv[2]}","accessKey":record["root_user"],"secretKey":record["root_password"],"api":"S3v4","path":"auto"}}}
(r / "mc" / "config.json").write_text(json.dumps(config, separators=(",",":")))
PY
chmod 0600 "$runtime/mc/config.json" "$runtime/librefs-policy.json"

mc_command=(mc --config-dir "$runtime/mc")
librefs_access_key="$(<"$runtime/librefs_access_key")"
! "${mc_command[@]}" admin user info local "$librefs_access_key" >/dev/null 2>&1
! "${mc_command[@]}" admin policy info local forgejo-backups >/dev/null 2>&1
"${mc_command[@]}" mb --ignore-existing local/forgejo-backups >/dev/null
{
    printf '%s\n' "$librefs_access_key"
    cat "$runtime/librefs_secret_key"
    printf '\n'
} | "${mc_command[@]}" admin user add local >/dev/null
touch "$runtime/librefs-created"
"${mc_command[@]}" admin policy create local forgejo-backups "$runtime/librefs-policy.json" >/dev/null
"${mc_command[@]}" admin policy attach local forgejo-backups --user "$librefs_access_key" >/dev/null
"${mc_command[@]}" stat local/forgejo-backups >/dev/null
unset librefs_access_key
unset tunnel_port
printf '%s\n' 'Scoped libreFS backup identity created'

certbot_image='certbot/dns-cloudflare:v5.7.0@sha256:ed5e95feb4d64690df77b4628876f3b72ae856d6e0acd51927a2fd45baf1ccd2'
printf 'dns_cloudflare_api_token = %s\n' "$(<"$runtime/cloudflare_token")" > "$runtime/cloudflare.ini"
printf 'email = %s\n' "$(<"$runtime/acme_email")" > "$runtime/certbot.ini"
chmod 0600 "$runtime/cloudflare.ini" "$runtime/certbot.ini"
mkdir -m 0700 "$runtime/letsencrypt" "$runtime/work" "$runtime/logs"
docker run --rm --platform linux/amd64 \
    --mount "type=bind,src=$runtime/cloudflare.ini,dst=/run/cloudflare.ini,readonly" \
    --mount "type=bind,src=$runtime/certbot.ini,dst=/run/certbot.ini,readonly" \
    --mount "type=bind,src=$runtime/letsencrypt,dst=/etc/letsencrypt" \
    --mount "type=bind,src=$runtime/work,dst=/var/lib/letsencrypt" \
    --mount "type=bind,src=$runtime/logs,dst=/var/log/letsencrypt" \
    "$certbot_image" certonly --config /run/certbot.ini --non-interactive --agree-tos \
    --dns-cloudflare --dns-cloudflare-credentials /run/cloudflare.ini \
    --cert-name monosense-wildcard -d '*.monosense.io'
printf '%s\n' 'Initial wildcard certificate issued'

python3 - "$runtime" <<'PY'
import datetime, json, pathlib, re, subprocess, sys
r = pathlib.Path(sys.argv[1])
def text(name): return (r / name).read_text().strip()
def payload(path, data):
    (r / path).write_text(json.dumps({"data":data,"options":{"cas":0}}, separators=(",",":")))
lineage = r / "letsencrypt/live/monosense-wildcard"
fullchain = (lineage / "fullchain.pem").read_text()
private_key = (lineage / "privkey.pem").read_text()
leaf = re.search(r"-----BEGIN CERTIFICATE-----.*?-----END CERTIFICATE-----", fullchain, re.S).group(0) + "\n"
serial = format(int(subprocess.check_output(["openssl","x509","-in",str(lineage / "cert.pem"),"-noout","-serial"], text=True).strip().split("=",1)[1], 16), "x")
end = subprocess.check_output(["openssl","x509","-in",str(lineage / "cert.pem"),"-noout","-enddate"], text=True).strip().split("=",1)[1]
not_after = datetime.datetime.strptime(end, "%b %d %H:%M:%S %Y %Z").replace(tzinfo=datetime.timezone.utc).isoformat().replace("+00:00","Z")
payload("monitoring-payload.json", {k:text(k) for k in ["telegram_bot_token","telegram_chat_id","vector_ingest_token","backup_heartbeat_token"]})
payload("edge-payload.json", {"acme_email":text("acme_email"),"cloudflare_dns_token":text("cloudflare_token"),"maxmind_account_id":text("maxmind_account_id"),"maxmind_license_key":text("maxmind_license_key"),"crowdsec_lapi_key":text("crowdsec_lapi_key"),"crowdsec_bouncer_key":text("crowdsec_bouncer_key"),"vector_ingest_token":text("vector_ingest_token")})
payload("forgejo-payload.json", {k:text(k) for k in ["postgres_password","forgejo_secret_key","forgejo_internal_token","forgejo_jwt_secret","forgejo_lfs_jwt_secret","admin_password","admin_email","zoho_username","zoho_password","kopia_repository_password","librefs_access_key","librefs_secret_key"]})
payload("wildcard-payload.json", {"certificate":leaf,"fullchain":fullchain,"private_key":private_key,"serial":serial,"not_after":not_after})
PY
chmod 0600 "$runtime"/*-payload.json

for pair in \
    'docker/c0/monitoring monitoring-payload.json' \
    'docker/c1/edge edge-payload.json' \
    'docker/c1/forgejo forgejo-payload.json' \
    'platform/tls/monosense-wildcard wildcard-payload.json'; do
    set -- $pair
    bao write "kv/data/$1" - < "$runtime/$2" >/dev/null
    printf '%s\n' "$1" >> "$runtime/committed-records"
    chmod 0600 "$runtime/committed-records"
    bao kv get -mount=kv -format=json "$1" >/dev/null
done
printf '%s\n' 'OpenBao application records verified'
scripts/rotate-vector-srx-certificate.sh
rm -f "$runtime/librefs-created" "$runtime/committed-records"

printf '%s\n' 'OpenBao application records, scoped libreFS account, and initial wildcard certificate committed'
