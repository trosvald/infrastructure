#!/usr/bin/env bash
set -euo pipefail

image='docker.io/powerdns/pdns-auth-51:5.1.4@sha256:bb5b1c133bcca1dd455075321de7d55db4945a8d7f2ba23339e3c7bbe416b205'
project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work_dir="$(mktemp -d)"
printf '%s' 'MTIzNDU2Nzg5MDEyMzQ1Njc4OTAxMjM0NTY3ODkwMTI=' >"$work_dir/external_dns_tsig"
chmod 0644 "$work_dir/external_dns_tsig"

docker_run=(docker run --rm --platform linux/amd64)
managed_zones=()
forward_zone=
for zone_file in "$project_dir"/zones/*.zone; do
    zone="${zone_file##*/}"
    zone="${zone%.zone}"
    managed_zones+=("$zone")
    if [[ "$zone" != *.in-addr.arpa ]]; then
        [[ -z "$forward_zone" ]]
        forward_zone=$zone
    fi
done
[[ "${#managed_zones[@]}" == 6 && -n "$forward_zone" ]]
host_uid="$(id -u)"
host_gid="$(id -g)"
case "$(uname -s)" in
    Darwin) expected_bind_owner="0:0" ;;
    Linux) expected_bind_owner="953:953" ;;
    *) echo "unsupported controller platform" >&2; exit 1 ;;
esac

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
    'command -v pdns_server && command -v pdnsutil && command -v pdns_control && command -v sqlite3 && command -v python3' \
    >/dev/null

initialize_data_volume() {
    local data_dir=$1
    if [[ ! -d "$data_dir" ]]; then
        mkdir "$data_dir"
        chmod 0750 "$data_dir"
    fi
    "${docker_run[@]}" \
        --user 0:0 --network none --cap-drop ALL --cap-add CHOWN \
        --env "EXPECTED_BIND_OWNER=$expected_bind_owner" \
        --mount "type=bind,src=$data_dir,dst=/var/lib/powerdns" \
        --entrypoint /bin/sh "$image" -ec '
            pdns_uid="$(id -u pdns)"
            pdns_gid="$(id -g pdns)"
            test "$pdns_uid" = 953
            chown "$pdns_uid:$pdns_gid" /var/lib/powerdns
            test "$(stat -c "%u:%g" /var/lib/powerdns)" = "$EXPECTED_BIND_OWNER"
            test "$(stat -c "%a" /var/lib/powerdns)" = 750
        '
}

reconcile() {
    local data_dir=$1
    local zones_dir=${2:-"$project_dir/zones"}
    "${docker_run[@]}" \
        --network none --cap-drop ALL --security-opt no-new-privileges:true \
        --mount "type=bind,src=$project_dir/scripts/reconcile.sh,dst=/usr/local/bin/reconcile.sh,readonly" \
        --mount "type=bind,src=$project_dir/scripts/merge_dynamic.py,dst=/usr/local/bin/merge_dynamic.py,readonly" \
        --mount "type=bind,src=$zones_dir,dst=/zones,readonly" \
        --mount "type=bind,src=$data_dir,dst=/var/lib/powerdns" \
        --mount "type=bind,src=$work_dir/external_dns_tsig,dst=/run/secrets/external_dns_tsig,readonly" \
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
        --entrypoint /bin/sh "$image" -ec \
        'sha256sum /var/lib/powerdns/pdns.sqlite3 /var/lib/powerdns/dnsupdate-policy.lua | sha256sum' |
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

zone_is_managed() {
    local candidate=$1
    local zone
    for zone in "${managed_zones[@]}"; do
        [[ "$zone" == "$candidate" ]] && return 0
    done
    return 1
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
expected_zone_inventory="$(printf '%s|NATIVE\n' "${managed_zones[@]}" | sort)"
[[ "$zone_inventory" == "$expected_zone_inventory" ]]

metadata_inventory="$(sqlite "$data_dir" "SELECT d.name || '|' || m.kind || '|' || m.content FROM domainmetadata AS m JOIN domains AS d ON d.id=m.domain_id ORDER BY d.name,m.kind,m.content;")"
expected_metadata_inventory="$({
    printf '%s|SOA-EDIT-API|DEFAULT\n' "${managed_zones[@]}"
    printf '%s\n' \
        'monosense.io|ALLOW-DNSUPDATE-FROM|10.25.11.0/24' \
        'monosense.io|TSIG-ALLOW-DNSUPDATE|external-dns-internal'
} | sort)"
[[ "$metadata_inventory" == "$expected_metadata_inventory" ]]
[[ "$(sqlite "$data_dir" "SELECT name || '|' || algorithm || '|' || length(secret) FROM tsigkeys;")" == 'external-dns-internal|hmac-sha256|44' ]]
[[ -s "$data_dir/dnsupdate-policy.lua" ]]

[[ "$(sqlite "$data_dir" "SELECT COUNT(*) FROM records WHERE type='A';")" -gt 0 ]]
[[ "$(sqlite "$data_dir" "SELECT COUNT(*) FROM records WHERE type='PTR';")" -gt 0 ]]
[[ "$(sqlite "$data_dir" "SELECT COUNT(*) FROM records WHERE type IN ('A','PTR') AND ttl != 300;")" == 0 ]]

a_inventory="$(sqlite "$data_dir" "SELECT name || '|' || content FROM records WHERE type='A' ORDER BY name;")"
while IFS='|' read -r name address; do
    IFS=. read -r first second third host remainder <<<"$address"
    [[ -z "$remainder" ]]
    reverse_zone="$third.$second.$first.in-addr.arpa"
    if ! zone_is_managed "$reverse_zone"; then
        printf '%s\n' "A record is outside the managed reverse zones: $name -> $address" >&2
        exit 1
    fi
    if [[ "$address" == 10.25.15.10 && "$name" == git.monosense.io ]]; then
        [[ "$(sqlite "$data_dir" "SELECT COUNT(*) FROM records AS r JOIN domains AS d ON d.id=r.domain_id WHERE d.name='$reverse_zone' AND r.name='$host.$reverse_zone' AND r.type='PTR' AND r.content='edge.monosense.io';")" == 1 ]]
    else
        [[ "$(sqlite "$data_dir" "SELECT COUNT(*) FROM records AS r JOIN domains AS d ON d.id=r.domain_id WHERE d.name='$reverse_zone' AND r.name='$host.$reverse_zone' AND r.type='PTR' AND r.content='$name';")" == 1 ]]
    fi
done <<<"$a_inventory"

ptr_inventory="$(sqlite "$data_dir" "SELECT name || '|' || content FROM records WHERE type='PTR' ORDER BY name;")"
while IFS='|' read -r reverse_name target; do
    IFS=. read -r host third second first suffix <<<"$reverse_name"
    [[ "$suffix" == in-addr.arpa ]]
    address="$first.$second.$third.$host"
    [[ "$(sqlite "$data_dir" "SELECT COUNT(*) FROM records AS r JOIN domains AS d ON d.id=r.domain_id WHERE d.name='$forward_zone' AND r.name='$target' AND r.type='A' AND r.content='$address';")" == 1 ]]
done <<<"$ptr_inventory"

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

copy_zones "$work_dir/additional-zones"
printf '%s\n' 'future 300 IN TXT "reviewed"' >>"$work_dir/additional-zones/$forward_zone.zone"
reconcile "$data_dir" "$work_dir/additional-zones"
[[ "$(sqlite "$data_dir" "SELECT COUNT(*) FROM records WHERE name='future.$forward_zone' AND type='TXT';")" == 1 ]]
reconcile "$data_dir"
[[ "$(sqlite "$data_dir" "SELECT COUNT(*) FROM records WHERE name='future.$forward_zone';")" == 0 ]]

"${docker_run[@]}" \
    --network none --cap-drop ALL \
    --env FORWARD_ZONE="$forward_zone" \
    --mount "type=bind,src=$data_dir,dst=/var/lib/powerdns" \
    --entrypoint /bin/sh "$image" -ec '
        config_dir="$(mktemp -d)"
        trap '"'"'rm -rf "$config_dir"'"'"' EXIT
        printf "%s\n" launch=gsqlite3 gsqlite3-database=/var/lib/powerdns/pdns.sqlite3 >"$config_dir/pdns.conf"
        pdnsutil --config-dir="$config_dir" rrset add "$FORWARD_ZONE" "drift.$FORWARD_ZONE" A 300 192.0.2.1
    '
[[ "$(sqlite "$data_dir" "SELECT COUNT(*) FROM records WHERE name='drift.$forward_zone';")" == 1 ]]
reconcile "$data_dir"
[[ "$(sqlite "$data_dir" "SELECT COUNT(*) FROM records WHERE name='drift.$forward_zone';")" == 0 ]]
[[ "$(sqlite "$data_dir" 'SELECT COUNT(*) FROM records;')" -gt 0 ]]

dynamic_name="dynamic.$forward_zone"
"${docker_run[@]}" \
    --network none --cap-drop ALL \
    --env FORWARD_ZONE="$forward_zone" --env DYNAMIC_NAME="$dynamic_name" \
    --mount "type=bind,src=$data_dir,dst=/var/lib/powerdns" \
    --entrypoint /bin/sh "$image" -ec '
        config_dir="$(mktemp -d)"
        trap '"'"'rm -rf "$config_dir"'"'"' EXIT
        printf "%s\n" launch=gsqlite3 gsqlite3-database=/var/lib/powerdns/pdns.sqlite3 >"$config_dir/pdns.conf"
        pdnsutil --config-dir="$config_dir" rrset add "$FORWARD_ZONE" "$DYNAMIC_NAME" A 300 10.25.20.40
        pdnsutil --config-dir="$config_dir" rrset add "$FORWARD_ZONE" "$DYNAMIC_NAME" TXT 300 \
            '"'"'"heritage=external-dns,external-dns/owner=external-dns-internal,external-dns/resource=httproute/observability/dynamic"'"'"'
    '
reconcile "$data_dir"
[[ "$(sqlite "$data_dir" "SELECT COUNT(*) FROM records WHERE name='$dynamic_name' AND type IN ('A','TXT');")" == 2 ]]
"${docker_run[@]}" \
    --network none --cap-drop ALL \
    --env FORWARD_ZONE="$forward_zone" --env DYNAMIC_NAME="$dynamic_name" \
    --mount "type=bind,src=$data_dir,dst=/var/lib/powerdns" \
    --entrypoint /bin/sh "$image" -ec '
        config_dir="$(mktemp -d)"
        trap '"'"'rm -rf "$config_dir"'"'"' EXIT
        printf "%s\n" launch=gsqlite3 gsqlite3-database=/var/lib/powerdns/pdns.sqlite3 >"$config_dir/pdns.conf"
        pdnsutil --config-dir="$config_dir" rrset replace "$FORWARD_ZONE" "$DYNAMIC_NAME" A 300 10.25.20.41
    '
reconcile "$data_dir"
[[ "$(sqlite "$data_dir" "SELECT COUNT(*) FROM records WHERE name='$dynamic_name' AND type='A' AND content='10.25.20.41';")" == 1 ]]
"${docker_run[@]}" \
    --network none --cap-drop ALL \
    --env FORWARD_ZONE="$forward_zone" --env DYNAMIC_NAME="$dynamic_name" \
    --mount "type=bind,src=$data_dir,dst=/var/lib/powerdns" \
    --entrypoint /bin/sh "$image" -ec '
        config_dir="$(mktemp -d)"
        trap '"'"'rm -rf "$config_dir"'"'"' EXIT
        printf "%s\n" launch=gsqlite3 gsqlite3-database=/var/lib/powerdns/pdns.sqlite3 >"$config_dir/pdns.conf"
        pdnsutil --config-dir="$config_dir" rrset delete "$FORWARD_ZONE" "$DYNAMIC_NAME" A
        pdnsutil --config-dir="$config_dir" rrset delete "$FORWARD_ZONE" "$DYNAMIC_NAME" TXT
    '
reconcile "$data_dir"
[[ "$(sqlite "$data_dir" "SELECT COUNT(*) FROM records WHERE name='$dynamic_name';")" == 0 ]]

python3 - "$data_dir/dnsupdate-policy.lua" <<'PY'
import pathlib, sys
policy = pathlib.Path(sys.argv[1]).read_text()
assert 'tostring(input:getTsigName()) == "external-dns-internal."' in policy
assert 'allowed_types[input:getQType()] == true' in policy
assert '["git.monosense.io."] = true' in policy
PY

prepare_case collision
canonical_name="$(sqlite "$work_dir/collision-data" \
    "SELECT r.name FROM records AS r JOIN domains AS d ON d.id=r.domain_id WHERE d.name='$forward_zone' AND r.type='A' ORDER BY r.name LIMIT 1;")"
"${docker_run[@]}" \
    --network none --cap-drop ALL \
    --env FORWARD_ZONE="$forward_zone" --env CANONICAL_NAME="$canonical_name" \
    --mount "type=bind,src=$work_dir/collision-data,dst=/var/lib/powerdns" \
    --entrypoint /bin/sh "$image" -ec '
        config_dir="$(mktemp -d)"
        trap '"'"'rm -rf "$config_dir"'"'"' EXIT
        printf "%s\n" launch=gsqlite3 gsqlite3-database=/var/lib/powerdns/pdns.sqlite3 >"$config_dir/pdns.conf"
        pdnsutil --config-dir="$config_dir" rrset add "$FORWARD_ZONE" "$CANONICAL_NAME" TXT 300 \
            '"'"'"heritage=external-dns,external-dns/owner=external-dns-internal,external-dns/resource=httproute/networking/collision"'"'"'
    '
expect_atomic_failure 'an owned dynamic RRset shadowing a canonical Git name' \
    "$work_dir/collision-data" "$work_dir/collision-zones"

missing_zone=${managed_zones[0]}
prepare_case missing
rm "$work_dir/missing-zones/$missing_zone.zone"
expect_atomic_failure 'a missing canonical zone' "$work_dir/missing-data" "$work_dir/missing-zones"

extra_source=${managed_zones[0]}
prepare_case extra
cp "$work_dir/extra-zones/$extra_source.zone" "$work_dir/extra-zones/extra.zone"
expect_atomic_failure 'an extra canonical zone' "$work_dir/extra-data" "$work_dir/extra-zones"

malformed_zone=${managed_zones[1]}
prepare_case malformed
printf '%s\n' 'this is not a zone' >"$work_dir/malformed-zones/$malformed_zone.zone"
expect_atomic_failure 'malformed canonical zone content' "$work_dir/malformed-data" "$work_dir/malformed-zones"
if database_path_exists "$work_dir/malformed-data" /var/lib/powerdns/pdns.sqlite3.tmp; then
    printf '%s\n' 'malformed canonical zone left a candidate' >&2
    exit 1
fi

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
    --mount "type=bind,src=$data_dir,dst=/var/lib/powerdns" \
    --entrypoint /bin/sh "$image" -ec '
        pdns_server "$@" &
        server_pid=$!
        trap '"'"'kill "$server_pid" 2>/dev/null || true; wait "$server_pid" 2>/dev/null || true'"'"' EXIT
        sleep 2
        if ! kill -0 "$server_pid"; then
            wait "$server_pid"
            printf "%s\n" "PowerDNS exited during its startup probe" >&2
            exit 1
        fi
        if ! quick_check=$(sqlite3 /var/lib/powerdns/pdns.sqlite3 "PRAGMA quick_check;"); then
            printf "%s\n" "PowerDNS live database quick_check command failed" >&2
            exit 1
        fi
        if [ "$quick_check" != ok ]; then
            printf "%s\n" "PowerDNS live database quick_check failed: $quick_check" >&2
            exit 1
        fi
        exit 0
    ' _ \
    --api=no \
    --dnsupdate=yes \
    --disable-axfr=yes \
    --gsqlite3-database=/var/lib/powerdns/pdns.sqlite3 \
    --launch=gsqlite3 \
    --lua-dnsupdate-policy-script=/var/lib/powerdns/dnsupdate-policy.lua \
    --local-address=0.0.0.0 \
    --version-string=anonymous \
    --webserver=no
