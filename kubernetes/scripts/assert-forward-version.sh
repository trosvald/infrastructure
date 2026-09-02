#!/usr/bin/env bash
set -euo pipefail

[[ $# -eq 3 ]] || {
    printf 'usage: %s <current-version> <stable-target-version> <maximum-minor-delta>\n' "$0" >&2
    exit 2
}

readonly CURRENT_VERSION="$1"
readonly TARGET_VERSION="$2"
readonly MAXIMUM_MINOR_DELTA="$3"

[[ "$CURRENT_VERSION" =~ ^v([0-9]+)\.([0-9]+)\.([0-9]+)(-[0-9A-Za-z.-]+)?$ ]] || {
    printf 'current version is not valid semantic version: %s\n' "$CURRENT_VERSION" >&2
    exit 1
}
readonly CURRENT_MAJOR="${BASH_REMATCH[1]}"
readonly CURRENT_MINOR="${BASH_REMATCH[2]}"
readonly CURRENT_PATCH="${BASH_REMATCH[3]}"
readonly CURRENT_PRERELEASE="${BASH_REMATCH[4]}"

[[ "$TARGET_VERSION" =~ ^v([0-9]+)\.([0-9]+)\.([0-9]+)$ ]] || {
    printf 'target version must be a stable semantic version: %s\n' "$TARGET_VERSION" >&2
    exit 1
}
readonly TARGET_MAJOR="${BASH_REMATCH[1]}"
readonly TARGET_MINOR="${BASH_REMATCH[2]}"
readonly TARGET_PATCH="${BASH_REMATCH[3]}"

[[ "$MAXIMUM_MINOR_DELTA" =~ ^[0-9]+$ ]] || {
    printf 'maximum minor delta must be a non-negative integer: %s\n' "$MAXIMUM_MINOR_DELTA" >&2
    exit 1
}
[[ "$CURRENT_MAJOR" -eq "$TARGET_MAJOR" ]] || {
    printf 'cross-major version transition is forbidden: %s -> %s\n' "$CURRENT_VERSION" "$TARGET_VERSION" >&2
    exit 1
}

if (( TARGET_MINOR < CURRENT_MINOR || TARGET_MINOR - CURRENT_MINOR > MAXIMUM_MINOR_DELTA )); then
    printf 'version transition exceeds the supported minor path: %s -> %s\n' "$CURRENT_VERSION" "$TARGET_VERSION" >&2
    exit 1
fi

if (( TARGET_MINOR > CURRENT_MINOR || TARGET_PATCH > CURRENT_PATCH )); then
    exit 0
fi
if (( TARGET_MINOR == CURRENT_MINOR && TARGET_PATCH == CURRENT_PATCH )) && [[ -n "$CURRENT_PRERELEASE" ]]; then
    exit 0
fi

printf 'target must advance the current version; downgrade and no-op transitions are forbidden: %s -> %s\n' "$CURRENT_VERSION" "$TARGET_VERSION" >&2
exit 1
