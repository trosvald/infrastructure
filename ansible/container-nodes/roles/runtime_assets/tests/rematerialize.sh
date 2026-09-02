#!/usr/bin/env bash
set -euo pipefail
readonly HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT="$HERE/../files/rematerialize-c1-librefs-credentials"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin" "$work/data/git.monosense.io/trosvald/infrastructure/.git" "$work/containers"
printf '%s\n' 'c1-safe-api-secret-canary-abcdefghijklmnopqrstuvwxyz' >"$work/api-secret"
chmod 0600 "$work/api-secret"
containers=(librefs-c1 haproxy-c1 crowdsec-c1 crowdsec-spoa-c1 vector-c1 forgejo-c1 forgejo-postgres-c1 kopia-forgejo-c1)
for container in "${containers[@]}"; do : >"$work/containers/$container"; done
mkdir -p "$work/data/durable"; printf '%s\n' preserve >"$work/data/durable/sentinel"

cat >"$work/bin/docker" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
if [[ "$1" == container && "$2" == inspect ]]; then [[ -f "$CONTAINER_ROOT/$3" ]]; exit; fi
if [[ "$1" == rm && "$2" == -f ]]; then
  [[ "${RM_FAIL:-false}" != true ]] || exit 22
  rm -f "$CONTAINER_ROOT/$3"; exit
fi
if [[ "$1" == inspect ]]; then
  container="$2"; [[ -f "$CONTAINER_ROOT/$container" ]] || exit 1
  if [[ "$#" == 2 ]]; then exit 0; fi
  if [[ "$*" == *'.State.Status'* ]]; then printf '%s\n' running
  elif [[ "$*" == *'.State.Health'* ]]; then printf '%s\n' healthy
  elif [[ "$*" == *'cd.doco.source.url'* ]]; then printf '%s\n' "${PROVENANCE_VALUE:-https://git.monosense.io/trosvald/infrastructure.git}"
  else exit 20; fi
  exit
fi
exit 21
FAKE
cat >"$work/bin/git" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
if [[ "$1" == clone ]]; then
  destination="${@: -1}"
  mkdir -p "$destination/docker/c1"/{librefs,edge,forgejo}
elif [[ "$*" == *'rev-parse HEAD'* ]]; then printf '%040d\n' 1
fi
FAKE
cat >"$work/bin/systemctl" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$SYSTEMCTL_LOG"
FAKE
cat >"$work/bin/controller-gate" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
[[ "${GATE_FAIL:-false}" != true ]]
FAKE
cat >"$work/bin/stat" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "${STAT_RESULT:-root:root:600}"
FAKE
cat >"$work/bin/curl" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
config=''; previous=''
for argument in "$@"; do
  if [[ "$previous" == --config ]]; then config="$argument"; break; fi
  previous="$argument"
done
[[ "$(cat "$config")" == 'header = "x-api-key: c1-safe-api-secret-canary-abcdefghijklmnopqrstuvwxyz"' ]]
[[ "${CURL_FAIL:-false}" != true ]] || exit 22
if [[ "$*" == *'/v1/api/poll/run?wait=true'* ]]; then
  payload="$(cat)"; printf '%s\n' "$payload" >>"$PAYLOAD_LOG"
  if [[ "$payload" == *'file:///data/c1-secret-rematerialize-'* ]]; then : >"$CONTAINER_ROOT/librefs-c1"; fi
  printf '%s\n' '{"job_id":"safe-job-id"}'
elif [[ "$*" == *'/v1/api/run/safe-job-id'* ]]; then
  printf '%s\n' '{"content":{"status":"succeeded"}}'
else exit 23; fi
FAKE
chmod +x "$work/bin/"*

run() {
  PATH="$work/bin:$PATH" FAKE_UID="${FAKE_UID:-0}" DOCKER_BIN="$work/bin/docker" \
    CURL_BIN="$work/bin/curl" GIT_BIN="$work/bin/git" SYSTEMCTL_BIN="$work/bin/systemctl" \
    SLEEP_BIN=true STAT_BIN="$work/bin/stat" CONTROLLER_GATE="$work/bin/controller-gate" \
    DATA_ROOT="$work/data" API_SECRET_FILE="$work/api-secret" CONTAINER_ROOT="$work/containers" \
    SYSTEMCTL_LOG="$work/systemctl.log" PAYLOAD_LOG="$work/payload.log" \
    CURL_FAIL="${CURL_FAIL:-false}" GATE_FAIL="${GATE_FAIL:-false}" RM_FAIL="${RM_FAIL:-false}" \
    STAT_RESULT="${STAT_RESULT:-root:root:600}" PROVENANCE_VALUE="${PROVENANCE_VALUE:-https://git.monosense.io/trosvald/infrastructure.git}" \
    "$SCRIPT"
}
must_fail() { if run >/dev/null 2>&1; then printf 'expected rematerialization failure\n' >&2; exit 1; fi; }

output="$(run)"
[[ "$output" == 'Doco rematerialized exact c1 project allowlist and normalized remote-main provenance' ]]
[[ "$(sed -n '$=' "$work/payload.log")" == 2 ]]
grep -F '"target":"rotation"' "$work/payload.log" >/dev/null
grep -F 'https://git.monosense.io/trosvald/infrastructure.git' "$work/payload.log" >/dev/null
for project in librefs-c1 edge-c1 forgejo-c1; do
  grep -Fx "stop doco-project-$project.service" "$work/systemctl.log" >/dev/null
  grep -Fx "start doco-project-$project.service" "$work/systemctl.log" >/dev/null
done
[[ "$(cat "$work/data/durable/sentinel")" == preserve ]]
! compgen -G "$work/data/data/c1-secret-rematerialize-*" >/dev/null

FAKE_UID=1000; export FAKE_UID; must_fail; unset FAKE_UID
STAT_RESULT=root:root:644; export STAT_RESULT; must_fail; unset STAT_RESULT
mv "$work/api-secret" "$work/api-secret.real"; ln -s "$work/api-secret.real" "$work/api-secret"; must_fail
rm "$work/api-secret"; mv "$work/api-secret.real" "$work/api-secret"

rm -f "$work/systemctl.log" "$work/payload.log"
for container in "${containers[@]}"; do : >"$work/containers/$container"; done
CURL_FAIL=true; export CURL_FAIL; must_fail; unset CURL_FAIL
[[ ! -e "$work/containers/librefs-c1" ]]
[[ "$(cat "$work/data/durable/sentinel")" == preserve ]]
for project in librefs-c1 edge-c1 forgejo-c1; do grep -Fx "start doco-project-$project.service" "$work/systemctl.log" >/dev/null; done
printf 'c1 Doco exact-project rematerialization tests passed\n'
