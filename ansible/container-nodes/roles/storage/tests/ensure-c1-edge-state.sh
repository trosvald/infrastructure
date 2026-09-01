#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT HUP INT TERM
mkdir -p "$work/bin"
cat >"$work/bin/id" <<'SH'
#!/usr/bin/env bash
echo "${FAKE_UID:-0}"
SH
cat >"$work/bin/install" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
args=(); while (($#)); do case "$1" in -o|-g) shift 2;; *) args+=("$1"); shift;; esac; done
/usr/bin/install "${args[@]}"
SH
cat >"$work/bin/stat" <<'SH'
#!/usr/bin/env bash
path="${!#}"
python3 - "$path" <<'PY'
import os
import stat
import sys

path = sys.argv[1]
suffix = path.rsplit("/edge", 1)[-1]
owners = {
    "": (0, 0),
    "/crowdsec": (1000, 1000),
    "/crowdsec-config": (1000, 1000),
    "/geolite": (1000, 1000),
    "/letsencrypt": (0, 0),
    "/runtime": (99, 99),
    "/logs": (1000, 1000),
    "/tls": (0, 0),
    "/tls/releases": (0, 0),
    "/tls/crt-list.txt": (0, 0),
}
uid, gid = owners[suffix]
mode = stat.S_IMODE(os.stat(path).st_mode)
print(f"{uid}:{gid}:{mode:o}")
PY
SH
cat >"$work/bin/chown" <<'SH'
#!/usr/bin/env bash
[[ "$1" == "root:root" ]] || exit 1
SH
chmod +x "$work/bin"/*
run() { PATH="$work/bin:$PATH" ROOT="$work/edge" ID_BIN="$work/bin/id" INSTALL_BIN="$work/bin/install" STAT_BIN="$work/bin/stat" "$root/files/ensure-c1-edge-state" "$@"; }
run apply >/dev/null; run check >/dev/null
[[ "$(cat "$work/edge/tls/crt-list.txt")" == '/run/tls/current/combined.pem git.monosense.io' ]]
rm -rf "$work/edge/geolite"; ln -s "$work/elsewhere" "$work/edge/geolite"
if run check >/dev/null 2>&1; then echo 'symlink edge source was accepted' >&2; exit 1; fi
rm "$work/edge/geolite"; FAKE_UID=1000 run apply >/dev/null 2>&1 && { echo 'non-root apply was accepted' >&2; exit 1; }
printf 'Edge state helper tests passed\n'
