#!/bin/sh
set -eu

zone=monosense.io
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

configure_database() {
    config_dir="$(mktemp -d /tmp/pdns-init.XXXXXX)"
    cat >"$config_dir/pdns.conf" <<EOF
launch=gsqlite3
gsqlite3-database=$1
EOF
}

check_database() {
    candidate=$1
    integrity="$(sqlite3 "$candidate" 'PRAGMA integrity_check;')"
    [ "$integrity" = ok ] || {
        printf '%s\n' "SQLite integrity check failed: $integrity" >&2
        exit 1
    }

    [ "$(sqlite3 "$candidate" "SELECT COUNT(*) FROM domains WHERE name='$zone' AND type='NATIVE';")" = 1 ] || {
        printf '%s\n' "missing native $zone zone" >&2
        exit 1
    }
    [ "$(sqlite3 "$candidate" "SELECT COUNT(*) FROM domainmetadata AS m JOIN domains AS d ON d.id=m.domain_id WHERE d.name='$zone' AND m.kind='SOA-EDIT-API' AND m.content='DEFAULT';")" = 1 ] || {
        printf '%s\n' "missing SOA-EDIT-API metadata for $zone" >&2
        exit 1
    }
    [ "$(sqlite3 "$candidate" "SELECT COUNT(*) FROM records AS r JOIN domains AS d ON d.id=r.domain_id WHERE d.name='$zone' AND r.name='ns1.monosense.io' AND r.type='A' AND r.content='10.25.13.33';")" = 1 ] || {
        printf '%s\n' 'missing ns1.monosense.io static record' >&2
        exit 1
    }
    [ "$(sqlite3 "$candidate" "SELECT COUNT(*) FROM records AS r JOIN domains AS d ON d.id=r.domain_id WHERE d.name='$zone' AND r.name='vault.monosense.io' AND r.type='A' AND r.content='10.25.13.34';")" = 1 ] || {
        printf '%s\n' 'missing vault.monosense.io static record' >&2
        exit 1
    }

    configure_database "$candidate"
    pdnsutil --config-dir="$config_dir" zone check "$zone"
}

[ "$(id -u)" = 953 ] || {
    printf '%s\n' 'zone initializer must run as PowerDNS UID 953' >&2
    exit 1
}
[ ! -e "$temporary" ] || {
    printf '%s\n' "partial database exists: $temporary" >&2
    exit 1
}

if [ -e "$database" ]; then
    [ -f "$database" ] || {
        printf '%s\n' "database path is not a regular file: $database" >&2
        exit 1
    }
    check_database "$database"
    exit 0
fi

umask 077
sqlite3 "$temporary" </usr/local/share/doc/pdns/schema.sqlite3.sql
configure_database "$temporary"
pdnsutil --config-dir="$config_dir" zone load "$zone" "/bootstrap/$zone.zone"
pdnsutil --config-dir="$config_dir" zone set-kind "$zone" native
pdnsutil --config-dir="$config_dir" metadata set "$zone" SOA-EDIT-API DEFAULT
pdnsutil --config-dir="$config_dir" zone check "$zone"
sqlite3 "$temporary" 'PRAGMA journal_mode=DELETE; PRAGMA integrity_check;'

rm -rf "$config_dir"
config_dir=
check_database "$temporary"
mv "$temporary" "$database"
printf '%s\n' "initialized $database"
