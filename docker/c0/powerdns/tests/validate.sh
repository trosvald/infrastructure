#!/usr/bin/env bash
set -euo pipefail

image='docker.io/powerdns/pdns-auth-51:5.1.4@sha256:bb5b1c133bcca1dd455075321de7d55db4945a8d7f2ba23339e3c7bbe416b205'
project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work_dir="$(mktemp -d)"

docker_run=(docker run --rm --platform linux/amd64)
managed_zones=(
    monosense.io
    10.25.10.in-addr.arpa
    11.25.10.in-addr.arpa
    12.25.10.in-addr.arpa
    13.25.10.in-addr.arpa
)
host_uid="$(id -u)"
host_gid="$(id -g)"

cleanup() {
    local data_dir
    set +e
    for data_dir in "$work_dir"/*-data "$work_dir/data"; do
        [[ -d "$data_dir" ]] || continue
        "${docker_run[@]}" \
            --user 0:0 \
            --mount "type=bind,src=$data_dir,dst=/var/lib/powerdns" \
            --entrypoint chown "$image" -R "$host_uid:$host_gid" /var/lib/powerdns \
            >/dev/null
    done
    rm -rf "$work_dir"
}
trap cleanup EXIT HUP INT TERM

identity="$("${docker_run[@]}" --entrypoint id "$image" pdns)"
[[ "$identity" == 'uid=953(pdns) gid=953(pdns) groups=953(pdns)' ]]
[[ "$("${docker_run[@]}" --entrypoint pdns_server "$image" --version 2>&1)" == *'PowerDNS Authoritative Server 5.1.4'* ]]
"${docker_run[@]}" --entrypoint /bin/sh "$image" -c \
    'command -v pdns_server && command -v pdnsutil && command -v pdns_control && command -v sqlite3' \
    >/dev/null

initialize_data_volume() {
    local data_dir=$1
    if [[ ! -d "$data_dir" ]]; then
        mkdir "$data_dir"
        chmod 0750 "$data_dir"
    fi
    "${docker_run[@]}" \
        --user 0:0 --network none --cap-drop ALL --cap-add CHOWN \
        --mount "type=bind,src=$data_dir,dst=/var/lib/powerdns" \
        --entrypoint /bin/sh "$image" -ec '
            pdns_uid="$(id -u pdns)"
            pdns_gid="$(id -g pdns)"
            test "$pdns_uid" = 953
            chown "$pdns_uid:$pdns_gid" /var/lib/powerdns
            test "$(stat -c "%u:%g" /var/lib/powerdns)" = "$pdns_uid:$pdns_gid"
            test "$(stat -c "%a" /var/lib/powerdns)" = 750
        '
}

reconcile() {
    local data_dir=$1
    local zones_dir=${2:-"$project_dir/zones"}
    "${docker_run[@]}" \
        --network none --cap-drop ALL --security-opt no-new-privileges:true \
        --mount "type=bind,src=$project_dir/scripts/reconcile.sh,dst=/usr/local/bin/reconcile.sh,readonly" \
        --mount "type=bind,src=$zones_dir,dst=/zones,readonly" \
        --mount "type=bind,src=$data_dir,dst=/var/lib/powerdns" \
        --entrypoint /usr/local/bin/reconcile.sh "$image"
}

sqlite() {
    local data_dir=$1
    local query=$2
    "${docker_run[@]}" \
        --mount "type=bind,src=$data_dir,dst=/var/lib/powerdns" \
        --entrypoint sqlite3 "$image" /var/lib/powerdns/pdns.sqlite3 "$query"
}

database_hash() {
    local data_dir=$1
    "${docker_run[@]}" \
        --mount "type=bind,src=$data_dir,dst=/var/lib/powerdns,readonly" \
        --entrypoint sha256sum "$image" /var/lib/powerdns/pdns.sqlite3 |
        cut -d ' ' -f 1
}

database_path_exists() {
    local data_dir=$1
    local path=$2
    "${docker_run[@]}" \
        --mount "type=bind,src=$data_dir,dst=/var/lib/powerdns,readonly" \
        --entrypoint test "$image" -e "$path"
}

copy_zones() {
    local destination=$1
    mkdir "$destination"
    cp -R "$project_dir/zones/." "$destination/"
}

prepare_case() {
    local name=$1
    local data_dir="$work_dir/$name-data"
    local zones_dir="$work_dir/$name-zones"
    initialize_data_volume "$data_dir"
    copy_zones "$zones_dir"
    reconcile "$data_dir" "$zones_dir"
}

expect_atomic_failure() {
    local label=$1
    local data_dir=$2
    local zones_dir=$3
    local before
    local after
    before="$(database_hash "$data_dir")"
    if reconcile "$data_dir" "$zones_dir"; then
        printf '%s\n' "reconciler accepted $label" >&2
        exit 1
    fi
    after="$(database_hash "$data_dir")"
    [[ "$after" == "$before" ]] || {
        printf '%s\n' "$label changed the current database" >&2
        exit 1
    }
}

data_dir="$work_dir/data"
initialize_data_volume "$data_dir"
initialize_data_volume "$data_dir"
reconcile "$data_dir"
reconcile "$data_dir"

[[ "$(sqlite "$data_dir" 'PRAGMA integrity_check;')" == ok ]]
[[ -z "$(sqlite "$data_dir" 'PRAGMA foreign_key_check;')" ]]
[[ "$(sqlite "$data_dir" 'PRAGMA journal_mode;')" == delete ]]

zone_inventory="$(sqlite "$data_dir" 'SELECT name || "|" || type FROM domains ORDER BY name;')"
[[ "$zone_inventory" == $'10.25.10.in-addr.arpa|NATIVE\n11.25.10.in-addr.arpa|NATIVE\n12.25.10.in-addr.arpa|NATIVE\n13.25.10.in-addr.arpa|NATIVE\nmonosense.io|NATIVE' ]]

metadata_inventory="$(sqlite "$data_dir" "SELECT d.name || '|' || m.kind || '|' || m.content FROM domainmetadata AS m JOIN domains AS d ON d.id=m.domain_id ORDER BY d.name,m.kind,m.content;")"
[[ "$metadata_inventory" == $'10.25.10.in-addr.arpa|SOA-EDIT-API|DEFAULT\n11.25.10.in-addr.arpa|SOA-EDIT-API|DEFAULT\n12.25.10.in-addr.arpa|SOA-EDIT-API|DEFAULT\n13.25.10.in-addr.arpa|SOA-EDIT-API|DEFAULT\nmonosense.io|SOA-EDIT-API|DEFAULT' ]]

a_inventory="$(sqlite "$data_dir" "SELECT name || '|' || content || '|' || ttl FROM records WHERE type='A' ORDER BY name;")"
[[ "$a_inventory" == $'adguard.monosense.io|10.25.10.100|300\nc0.monosense.io|10.25.10.20|300\nc1.monosense.io|10.25.10.101|300\nk1.monosense.io|10.25.11.11|300\nk2.monosense.io|10.25.11.12|300\nk3.monosense.io|10.25.11.13|300\nk4.monosense.io|10.25.11.14|300\nk5.monosense.io|10.25.11.15|300\nns1.monosense.io|10.25.13.33|300\nvault.monosense.io|10.25.13.34|300' ]]

ptr_inventory="$(sqlite "$data_dir" "SELECT name || '|' || content || '|' || ttl FROM records WHERE type='PTR' ORDER BY name;")"
[[ "$ptr_inventory" == $'100.10.25.10.in-addr.arpa|adguard.monosense.io|300\n101.10.25.10.in-addr.arpa|c1.monosense.io|300\n11.11.25.10.in-addr.arpa|k1.monosense.io|300\n12.11.25.10.in-addr.arpa|k2.monosense.io|300\n13.11.25.10.in-addr.arpa|k3.monosense.io|300\n14.11.25.10.in-addr.arpa|k4.monosense.io|300\n15.11.25.10.in-addr.arpa|k5.monosense.io|300\n20.10.25.10.in-addr.arpa|c0.monosense.io|300\n33.13.25.10.in-addr.arpa|ns1.monosense.io|300\n34.13.25.10.in-addr.arpa|vault.monosense.io|300' ]]

"${docker_run[@]}" \
    --network none --cap-drop ALL \
    --mount "type=bind,src=$data_dir,dst=/var/lib/powerdns" \
    --entrypoint /bin/sh "$image" -ec "
        config_dir=\"\$(mktemp -d)\"
        trap 'rm -rf \"\$config_dir\"' EXIT
        printf '%s\n' 'launch=gsqlite3' 'gsqlite3-database=/var/lib/powerdns/pdns.sqlite3' >\"\$config_dir/pdns.conf\"
        for zone in ${managed_zones[*]}; do
            pdnsutil --config-dir=\"\$config_dir\" zone check \"\$zone\"
        done
    "

"${docker_run[@]}" \
    --network none --cap-drop ALL \
    --mount "type=bind,src=$data_dir,dst=/var/lib/powerdns" \
    --entrypoint /bin/sh "$image" -ec '
        config_dir="$(mktemp -d)"
        trap '"'"'rm -rf "$config_dir"'"'"' EXIT
        printf "%s\n" launch=gsqlite3 gsqlite3-database=/var/lib/powerdns/pdns.sqlite3 >"$config_dir/pdns.conf"
        pdnsutil --config-dir="$config_dir" rrset add monosense.io drift.monosense.io A 300 192.0.2.1
    '
[[ "$(sqlite "$data_dir" "SELECT COUNT(*) FROM records WHERE name='drift.monosense.io';")" == 1 ]]
reconcile "$data_dir"
[[ "$(sqlite "$data_dir" "SELECT COUNT(*) FROM records WHERE name='drift.monosense.io';")" == 0 ]]
[[ "$(sqlite "$data_dir" "SELECT COUNT(*) FROM records WHERE name='ns1.monosense.io' AND type='A' AND content='10.25.13.33';")" == 1 ]]

prepare_case missing
rm "$work_dir/missing-zones/12.25.10.in-addr.arpa.zone"
expect_atomic_failure 'a missing canonical zone' "$work_dir/missing-data" "$work_dir/missing-zones"

prepare_case extra
cp "$work_dir/extra-zones/12.25.10.in-addr.arpa.zone" "$work_dir/extra-zones/extra.zone"
expect_atomic_failure 'an extra canonical zone' "$work_dir/extra-data" "$work_dir/extra-zones"

prepare_case malformed
printf '%s\n' 'this is not a zone' >"$work_dir/malformed-zones/11.25.10.in-addr.arpa.zone"
expect_atomic_failure 'malformed canonical zone content' "$work_dir/malformed-data" "$work_dir/malformed-zones"
database_path_exists "$work_dir/malformed-data" /var/lib/powerdns/pdns.sqlite3.tmp

prepare_case partial
"${docker_run[@]}" \
    --network none --cap-drop ALL \
    --mount "type=bind,src=$work_dir/partial-data,dst=/var/lib/powerdns" \
    --entrypoint touch "$image" /var/lib/powerdns/pdns.sqlite3.tmp
expect_atomic_failure 'a pre-existing partial database' "$work_dir/partial-data" "$work_dir/partial-zones"

prepare_case corrupt
"${docker_run[@]}" \
    --network none --cap-drop ALL \
    --mount "type=bind,src=$work_dir/corrupt-data,dst=/var/lib/powerdns" \
    --entrypoint /bin/sh "$image" -ec "printf corrupt >/var/lib/powerdns/pdns.sqlite3"
expect_atomic_failure 'a corrupt current database' "$work_dir/corrupt-data" "$work_dir/corrupt-zones"
if database_path_exists "$work_dir/corrupt-data" /var/lib/powerdns/pdns.sqlite3.tmp; then
    printf '%s\n' 'corrupt current database created a candidate' >&2
    exit 1
fi

"${docker_run[@]}" \
    --network none --cap-drop ALL --cap-add NET_BIND_SERVICE \
    --security-opt no-new-privileges:true \
    --entrypoint pdns_server "$image" \
    --config=check \
    --api=no \
    --disable-axfr=yes \
    --gsqlite3-database=/var/lib/powerdns/pdns.sqlite3 \
    --launch=gsqlite3 \
    --local-address=0.0.0.0 \
    --version-string=anonymous \
    --webserver=no
