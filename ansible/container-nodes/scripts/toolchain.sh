#!/usr/bin/env bash

fail_toolchain() {
  printf 'container-nodes toolchain error: %s\n' "$*" >&2
  printf 'Run: mise trust && mise install --locked\n' >&2
  return 1
}

require_tool() {
  local executable
  for executable in "$@"; do
    command -v "$executable" >/dev/null 2>&1 || fail_toolchain "missing locked executable: $executable"
  done
}

require_private_dir() {
  local path="$1" state owner mode
  [[ ! -L "$path" ]] || fail_toolchain "refusing symlink runtime directory: $path"
  if [[ ! -d "$path" ]]; then
    (umask 077 && mkdir -p "$path")
  fi
  chmod 0700 "$path"
  if stat -f '%u %Lp' "$path" >/dev/null 2>&1; then
    state="$(stat -f '%u %Lp' "$path")"
  else
    state="$(stat -c '%u %a' "$path")"
  fi
  owner="${state%% *}"
  mode="${state##* }"
  [[ "$owner" == "$(id -u)" && ( "$mode" == 700 || "$mode" == 0700 ) ]] ||
    fail_toolchain "runtime directory must be owned by the controller user with mode 0700: $path"
}
