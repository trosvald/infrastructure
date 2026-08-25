#!/usr/bin/env bash
set -euo pipefail

image='docker.io/powerdns/pdns-auth-51:5.1.4@sha256:bb5b1c133bcca1dd455075321de7d55db4945a8d7f2ba23339e3c7bbe416b205'
project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT HUP INT TERM
mkdir "$work_dir/data"
chmod 0750 "$work_dir/data"

docker_run=(docker run --rm --platform linux/amd64)

identity="$("${docker_run[@]}" --entrypoint id "$image" pdns)"
[[ "$identity" == 'uid=953(pdns) gid=953(pdns) groups=953(pdns)' ]]
[[ "$("${docker_run[@]}" --entrypoint pdns_server "$image" --version 2>&1)" == *'PowerDNS Authoritative Server 5.1.4'* ]]
"${docker_run[@]}" --entrypoint /bin/sh "$image" -c \
    'command -v pdns_server && command -v pdnsutil && command -v pdns_control && command -v sqlite3' \
    >/dev/null

initialize_data_volume() {
    "${docker_run[@]}" \
        --user 0:0 --network none --cap-drop ALL --cap-add CHOWN \
        --mount "type=bind,src=$work_dir/data,dst=/var/lib/powerdns" \
        --entrypoint /bin/sh "$image" -ec '
            pdns_uid="$(id -u pdns)"
            pdns_gid="$(id -g pdns)"
            owner="$(stat -c "%u:%g" /var/lib/powerdns)"
            mode="$(stat -c "%a" /var/lib/powerdns)"
            test "$pdns_uid" = 953
            if [ "$owner" = "0:0" ]; then
                chmod 0750 /var/lib/powerdns
                chown "$pdns_uid:$pdns_gid" /var/lib/powerdns
            else
                test "$owner" = "$pdns_uid:$pdns_gid"
                test "$mode" = 750
            fi
        '
}

initialize_data_volume
initialize_data_volume

initialize() {
    "${docker_run[@]}" \
        --network none --cap-drop ALL --security-opt no-new-privileges:true \
        --mount "type=bind,src=$project_dir/scripts/initialize.sh,dst=/usr/local/bin/initialize.sh,readonly" \
        --mount "type=bind,src=$project_dir/zones,dst=/bootstrap,readonly" \
        --mount "type=bind,src=$work_dir/data,dst=/var/lib/powerdns" \
        --entrypoint /usr/local/bin/initialize.sh "$image"
}

initialize
initialize

integrity="$("${docker_run[@]}" \
    --mount "type=bind,src=$work_dir/data,dst=/var/lib/powerdns" \
    --entrypoint sqlite3 "$image" /var/lib/powerdns/pdns.sqlite3 'PRAGMA integrity_check;')"
[[ "$integrity" == ok ]]

invariants="$("${docker_run[@]}" \
    --mount "type=bind,src=$work_dir/data,dst=/var/lib/powerdns" \
    --entrypoint sqlite3 "$image" /var/lib/powerdns/pdns.sqlite3 \
    "SELECT
       (SELECT COUNT(*) FROM domains WHERE name='monosense.io' AND type='NATIVE'),
       (SELECT COUNT(*) FROM domainmetadata WHERE kind='SOA-EDIT-API' AND content='DEFAULT'),
       (SELECT COUNT(*) FROM records WHERE name='ns1.monosense.io' AND type='A' AND content='10.25.13.33'),
       (SELECT COUNT(*) FROM records WHERE name='vault.monosense.io' AND type='A' AND content='10.25.13.34');")"
[[ "$invariants" == '1|1|1|1' ]]

"${docker_run[@]}" \
    --user 953:953 --network none --cap-drop ALL \
    --mount "type=bind,src=$work_dir/data,dst=/var/lib/powerdns" \
    --entrypoint /bin/sh "$image" -ec 'touch /var/lib/powerdns/pdns.sqlite3.tmp'
if initialize; then
    printf '%s\n' 'initializer accepted a partial database' >&2
    exit 1
fi
"${docker_run[@]}" \
    --user 953:953 --network none --cap-drop ALL \
    --mount "type=bind,src=$work_dir/data,dst=/var/lib/powerdns" \
    --entrypoint rm "$image" -f /var/lib/powerdns/pdns.sqlite3.tmp

"${docker_run[@]}" \
    --user 953:953 --network none --cap-drop ALL \
    --mount "type=bind,src=$work_dir/data,dst=/var/lib/powerdns" \
    --entrypoint /bin/sh "$image" -ec "printf 'corrupt' >/var/lib/powerdns/pdns.sqlite3"
if initialize; then
    printf '%s\n' 'initializer accepted a corrupt database' >&2
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
