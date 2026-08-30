#!/bin/sh
set -eu

managed_zones='monosense.io
10.25.10.in-addr.arpa
11.25.10.in-addr.arpa
12.25.10.in-addr.arpa
13.25.10.in-addr.arpa
15.25.10.in-addr.arpa'

managed_zone_count=0
for zone in $managed_zones; do
    managed_zone_count=$((managed_zone_count + 1))
done

data_dir=/var/lib/powerdns
database="$data_dir/pdns.sqlite3"
temporary="$database.tmp"
config_dir=

cleanup() {
    if [ -n "$config_dir" ]; then
        rm -rf "$config_dir"
    fi
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

    require_sql_count "$managed_zone_count" \
        "SELECT COUNT(*) FROM domains;" \
        'candidate contains an unexpected zone'

    for zone in $managed_zones; do
        require_sql_count 1 \
            "SELECT COUNT(*) FROM domains WHERE name='$zone' AND type='NATIVE';" \
            "missing native managed zone $zone"
        require_sql_count 1 \
            "SELECT COUNT(*) FROM domainmetadata AS m JOIN domains AS d ON d.id=m.domain_id WHERE d.name='$zone' AND m.kind='SOA-EDIT-API' AND m.content='DEFAULT';" \
            "missing SOA-EDIT-API metadata for $zone"
    done

    for zone in $managed_zones; do
        pdnsutil --config-dir="$config_dir" zone check "$zone"
    done
}

[ "$(id -u)" = 953 ] || fail 'zone reconciler must run as PowerDNS UID 953'
[ ! -e "$temporary" ] || fail "partial database exists: $temporary"

for zone in $managed_zones; do
    source="/zones/$zone.zone"
    [ -f "$source" ] && [ -r "$source" ] || fail "required zone file is not readable: $source"
done
set -- /zones/*.zone
[ "$#" = "$managed_zone_count" ] ||
    fail "expected exactly $managed_zone_count canonical zone files, found $#"

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

check_candidate
[ "$(sqlite3 "$temporary" 'PRAGMA journal_mode=DELETE;')" = delete ] ||
    fail 'could not set candidate journal mode to DELETE'
mv "$temporary" "$database"
printf '%s\n' "reconciled $database from $managed_zone_count canonical zones"
