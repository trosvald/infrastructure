#!/usr/bin/env bash
set -euo pipefail

readonly HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT="$HERE/../install-engine-config.sh"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin" "$work/systemd" "$work/docker" "$work/sbin"

cat >"$work/bin/id" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "${FAKE_UID:-0}"
FAKE
cat >"$work/bin/install" <<'FAKE'
#!/usr/bin/env bash
set -eu
args=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        -o|-g) shift 2 ;;
        *) args+=("$1"); shift ;;
    esac
done
/usr/bin/install "${args[@]}"
FAKE
cat >"$work/bin/systemctl" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$SYSTEMCTL_LOG"
[[ "${SYSTEMCTL_FAIL:-false}" != true ]]
FAKE
chmod +x "$work/bin/id" "$work/bin/install" "$work/bin/systemctl"
export SYSTEMCTL_LOG="$work/systemctl.log"

run() {
    PATH="$work/bin:$PATH" ID_BIN="$work/bin/id" INSTALL_BIN="$work/bin/install" \
        SYSTEMCTL_BIN="$work/bin/systemctl" SYSTEMD_ROOT="$work/systemd" \
        DOCKER_CONFIG_DIR="$work/docker" LOCAL_SBIN="$work/sbin" \
        FAKE_UID="${FAKE_UID:-0}" SYSTEMCTL_FAIL="${SYSTEMCTL_FAIL:-false}" \
        "$SCRIPT" "$1" >/dev/null
}
must_fail() {
    if run "$@" 2>/dev/null; then
        printf 'expected engine installer failure: %s\n' "$*" >&2
        exit 1
    fi
}

must_fail check
run apply
run check
run apply
grep -Fx 'daemon-reload' "$SYSTEMCTL_LOG" >/dev/null
grep -Fx 'enable c1-librefs-storage.service' "$SYSTEMCTL_LOG" >/dev/null

printf '%s\n' '{"data-root":"wrong"}' >"$work/docker/daemon.json"
must_fail apply
[[ "$(cat "$work/docker/daemon.json")" == '{"data-root":"wrong"}' ]]
cp "$HERE/../templates/daemon.json" "$work/docker/daemon.json"

rm "$work/systemd/docker.service.d/c1-storage.conf"
ln -s "$HERE/../templates/docker-c1-storage.conf" \
    "$work/systemd/docker.service.d/c1-storage.conf"
must_fail apply
rm "$work/systemd/docker.service.d/c1-storage.conf"
cp "$HERE/../templates/docker-c1-storage.conf" \
    "$work/systemd/docker.service.d/c1-storage.conf"

FAKE_UID=1000; export FAKE_UID; must_fail apply; unset FAKE_UID
SYSTEMCTL_FAIL=true; export SYSTEMCTL_FAIL; must_fail apply; unset SYSTEMCTL_FAIL

printf 'c1 engine configuration installer tests passed\n'
