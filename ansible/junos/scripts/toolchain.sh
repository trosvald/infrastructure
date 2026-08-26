#!/usr/bin/env bash

toolchain_error() {
  printf 'toolchain error: %s\n' "$*" >&2
  printf 'Run: mise trust && mise install --locked\n' >&2
  return 1
}

sha256_file() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    toolchain_error "operating-system shasum or sha256sum is required"
  fi
}

require_private_dir() {
  local directory="$1" owner mode stat_result
  if [[ -L "$directory" ]]; then
    toolchain_error "artifact directory must not be a symlink: $directory"
    return 1
  fi
  if [[ ! -e "$directory" ]]; then
    (umask 077 && mkdir "$directory")
  fi
  if [[ -L "$directory" ]]; then
    toolchain_error "artifact directory must not be a symlink: $directory"
    return 1
  fi
  if stat -f '%u %Lp' "$directory" >/dev/null 2>&1; then
    stat_result="$(stat -f '%u %Lp' "$directory")"
  else
    stat_result="$(stat -c '%u %a' "$directory")"
  fi
  owner="${stat_result%% *}"
  mode="${stat_result##* }"
  if [[ "$owner" != "$(id -u)" ]]; then
    toolchain_error "artifact directory is not owner-controlled: $directory"
    return 1
  fi
  chmod 0700 "$directory"
  if [[ -L "$directory" ]]; then
    toolchain_error "artifact directory became a symlink: $directory"
    return 1
  fi
  if stat -f '%u %Lp' "$directory" >/dev/null 2>&1; then
    stat_result="$(stat -f '%u %Lp' "$directory")"
  else
    stat_result="$(stat -c '%u %a' "$directory")"
  fi
  owner="${stat_result%% *}"
  mode="${stat_result##* }"
  if [[ "$owner" != "$(id -u)" || ( "$mode" != "700" && "$mode" != "0700" ) ]]; then
    toolchain_error "artifact directory must be owner-controlled mode 0700: $directory"
    return 1
  fi
}

require_mise_tools() {
  command -v mise >/dev/null 2>&1 || toolchain_error "mise is required"

  local executable active resolved
  for executable in "$@"; do
    active="$(command -v "$executable" 2>/dev/null || true)"
    [[ -n "$active" ]] || toolchain_error "missing executable: $executable"
    resolved="$(mise which "$executable" 2>/dev/null || true)"
    [[ -n "$resolved" ]] || toolchain_error "$executable is not declared and installed by mise"

    active="$(cd "$(dirname "$active")" && pwd -P)/$(basename "$active")"
    resolved="$(cd "$(dirname "$resolved")" && pwd -P)/$(basename "$resolved")"
    [[ "$active" == "$resolved" ]] || toolchain_error "$executable resolves outside mise: $active"
    case "$resolved" in
      /opt/homebrew/*|/usr/local/Cellar/*|*/ansible/junos/.venv/*|*/ansible/junos/.verify-venv/*)
        toolchain_error "rejected executable path for $executable: $resolved"
        ;;
    esac
  done
}
