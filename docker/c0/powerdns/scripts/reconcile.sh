#!/bin/sh
set -eu

managed_zones='monosense.io
10.25.10.in-addr.arpa
11.25.10.in-addr.arpa
12.25.10.in-addr.arpa
13.25.10.in-addr.arpa
15.25.10.in-addr.arpa
20.25.10.in-addr.arpa'
managed_zone_count=0
for zone in $managed_zones; do
    managed_zone_count=$((managed_zone_count + 1))
done

data_dir=/var/lib/powerdns
database="$data_dir/pdns.sqlite3"
temporary="$database.tmp"
config_dir=
tsig_key=/run/secrets/external_dns_tsig
merger=/usr/local/bin/merge_dynamic.py
policy="$data_dir/dnsupdate-policy.lua"
policy_temporary="$policy.tmp"

cleanup() {
    if [ -n "$config_dir" ]; then
        rm -rf "$config_dir"
    fi
    rm -f "$temporary" "$policy_temporary"
}
trap cleanup EXIT HUP INT TERM

fail() {
    printf '%s\n' "$1" >&2
    exit 1
}

configure_database() {
    config_dir="$(mktemp -d /tmp/pdns-reconcile.XXXXXX)"
    cat >"$config_dir/pdns.conf" <<EOF
launch=gsqlite3
gsqlite3-database=$1
EOF
}

require_sql_count() {
    expected=$1
    query=$2
    message=$3
    actual="$(sqlite3 "$temporary" "$query")"
    [ "$actual" = "$expected" ] || fail "$message: expected $expected, found $actual"
}

check_candidate() {
    integrity="$(sqlite3 "$temporary" 'PRAGMA integrity_check;')"
    [ "$integrity" = ok ] || fail "candidate SQLite integrity check failed: $integrity"
    foreign_keys="$(sqlite3 "$temporary" 'PRAGMA foreign_key_check;')"
    [ -z "$foreign_keys" ] || fail "candidate SQLite foreign key check failed: $foreign_keys"
    require_sql_count "$managed_zone_count" 'SELECT COUNT(*) FROM domains;' 'candidate contains an unexpected zone'
    for zone in $managed_zones; do
        require_sql_count 1 "SELECT COUNT(*) FROM domains WHERE name='$zone' AND type='NATIVE';" "missing native managed zone $zone"
        require_sql_count 1 "SELECT COUNT(*) FROM domainmetadata AS m JOIN domains AS d ON d.id=m.domain_id WHERE d.name='$zone' AND m.kind='SOA-EDIT-API' AND m.content='DEFAULT';" "missing SOA-EDIT-API metadata for $zone"
        pdnsutil --config-dir="$config_dir" zone check "$zone"
    done
    require_sql_count 1 "SELECT COUNT(*) FROM tsigkeys WHERE name='external-dns-internal' AND algorithm='hmac-sha256' AND length(secret)=44;" 'candidate lacks the exact ExternalDNS TSIG key'
    require_sql_count 1 "SELECT COUNT(*) FROM domainmetadata AS m JOIN domains AS d ON d.id=m.domain_id WHERE d.name='monosense.io' AND m.kind='TSIG-ALLOW-DNSUPDATE' AND m.content='external-dns-internal';" 'candidate lacks exact TSIG update authorization'
    require_sql_count 1 "SELECT COUNT(*) FROM domainmetadata AS m JOIN domains AS d ON d.id=m.domain_id WHERE d.name='monosense.io' AND m.kind='ALLOW-DNSUPDATE-FROM' AND m.content='10.25.11.0/24';" 'candidate lacks exact update source authorization'
}

[ "$(id -u)" = 953 ] || fail 'zone reconciler must run as PowerDNS UID 953'
[ -x "$merger" ] || fail "dynamic record merger is unavailable: $merger"
[ -f "$tsig_key" ] && [ -r "$tsig_key" ] && [ ! -L "$tsig_key" ] || fail "TSIG key is not a protected readable file: $tsig_key"
[ ! -e "$temporary" ] || fail "partial database exists: $temporary"
[ ! -e "$policy_temporary" ] || fail "partial update policy exists: $policy_temporary"
for zone in $managed_zones; do
    source="/zones/$zone.zone"
    [ -f "$source" ] && [ -r "$source" ] || fail "required zone file is not readable: $source"
done
set -- /zones/*.zone
[ "$#" = "$managed_zone_count" ] || fail "expected exactly $managed_zone_count canonical zone files, found $#"
if [ -e "$database" ]; then
    [ -f "$database" ] || fail "database path is not a regular file: $database"
    integrity="$(sqlite3 "$database" 'PRAGMA integrity_check;')"
    [ "$integrity" = ok ] || fail "current SQLite integrity check failed: $integrity"
fi

umask 077
sqlite3 "$temporary" </usr/local/share/doc/pdns/schema.sqlite3.sql
configure_database "$temporary"
for zone in $managed_zones; do
    pdnsutil --config-dir="$config_dir" zone load "$zone" "/zones/$zone.zone"
    pdnsutil --config-dir="$config_dir" zone set-kind "$zone" native
    pdnsutil --config-dir="$config_dir" metadata set "$zone" SOA-EDIT-API DEFAULT
done
pdnsutil --config-dir="$config_dir" metadata set monosense.io ALLOW-DNSUPDATE-FROM 10.25.11.0/24
pdnsutil --config-dir="$config_dir" metadata set monosense.io TSIG-ALLOW-DNSUPDATE external-dns-internal
python3 "$merger" "$database" "$temporary" "$tsig_key" "$policy_temporary"
check_candidate
[ "$(sqlite3 "$temporary" 'PRAGMA journal_mode=DELETE;')" = delete ] || fail 'could not set candidate journal mode to DELETE'
python3 - "$temporary" "$policy_temporary" <<'PY'
import os, pathlib, sys
for name in sys.argv[1:]:
    path = pathlib.Path(name)
    with path.open("rb") as stream:
        os.fsync(stream.fileno())
PY
mv "$policy_temporary" "$policy"
mv "$temporary" "$database"
python3 - "$data_dir" <<'PY'
import os, sys
fd = os.open(sys.argv[1], os.O_RDONLY | os.O_DIRECTORY)
try:
    os.fsync(fd)
finally:
    os.close(fd)
PY
printf '%s\n' "reconciled $database from $managed_zone_count canonical zones plus validated external-dns-internal records"
