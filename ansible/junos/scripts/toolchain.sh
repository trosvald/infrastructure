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
