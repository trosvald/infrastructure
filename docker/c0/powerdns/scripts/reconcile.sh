#!/bin/sh
set -eu

managed_zones='monosense.io
10.25.10.in-addr.arpa
11.25.10.in-addr.arpa
12.25.10.in-addr.arpa
13.25.10.in-addr.arpa'
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

    require_sql_count 5 \
        "SELECT COUNT(*) FROM domains WHERE type='NATIVE' AND name IN ('monosense.io','10.25.10.in-addr.arpa','11.25.10.in-addr.arpa','12.25.10.in-addr.arpa','13.25.10.in-addr.arpa');" \
        'native managed zone set is incomplete'
    require_sql_count 5 \
        "SELECT COUNT(*) FROM domains;" \
        'candidate contains an unexpected zone'

    for zone in $managed_zones; do
        require_sql_count 1 \
            "SELECT COUNT(*) FROM domainmetadata AS m JOIN domains AS d ON d.id=m.domain_id WHERE d.name='$zone' AND m.kind='SOA-EDIT-API' AND m.content='DEFAULT';" \
            "missing SOA-EDIT-API metadata for $zone"
    done

    while IFS='|' read -r name address; do
        require_sql_count 1 \
            "SELECT COUNT(*) FROM records AS r JOIN domains AS d ON d.id=r.domain_id WHERE d.name='monosense.io' AND r.name='$name.monosense.io' AND r.type='A' AND r.ttl=300 AND r.content='$address';" \
            "missing managed A record $name.monosense.io -> $address"
    done <<'EOF'
c0|10.25.10.20
adguard|10.25.10.100
c1|10.25.10.101
k1|10.25.11.11
k2|10.25.11.12
k3|10.25.11.13
k4|10.25.11.14
k5|10.25.11.15
ns1|10.25.13.33
vault|10.25.13.34
EOF

    while IFS='|' read -r zone address host; do
        require_sql_count 1 \
            "SELECT COUNT(*) FROM records AS r JOIN domains AS d ON d.id=r.domain_id WHERE d.name='$zone' AND r.name='$address.$zone' AND r.type='PTR' AND r.ttl=300 AND r.content='$host.monosense.io';" \
            "missing managed PTR record $address.$zone -> $host.monosense.io"
    done <<'EOF'
10.25.10.in-addr.arpa|20|c0
10.25.10.in-addr.arpa|100|adguard
10.25.10.in-addr.arpa|101|c1
11.25.10.in-addr.arpa|11|k1
11.25.10.in-addr.arpa|12|k2
11.25.10.in-addr.arpa|13|k3
11.25.10.in-addr.arpa|14|k4
11.25.10.in-addr.arpa|15|k5
13.25.10.in-addr.arpa|33|ns1
13.25.10.in-addr.arpa|34|vault
EOF

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
[ "$#" = 5 ] || fail "expected exactly 5 canonical zone files, found $#"

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
printf '%s\n' "reconciled $database from 5 canonical zones"
