#!/usr/bin/env bash
set -euo pipefail

command -v mise >/dev/null 2>&1 || { echo "mise is required" >&2; exit 1; }
active="$(command -v gitleaks 2>/dev/null || true)"
managed="$(mise which gitleaks 2>/dev/null || true)"
[[ -n "$active" && "$active" == "$managed" ]] || {
  echo "gitleaks must resolve to the mise-managed binary" >&2
  exit 1
}

canary_dir="$(mktemp -d "${TMPDIR:-/tmp}/gitleaks-canary.XXXXXX")"
cleanup() {
  find "$canary_dir" -type f -exec chmod 0600 {} + 2>/dev/null || true
  find "$canary_dir" -type f -delete 2>/dev/null || true
  rmdir "$canary_dir" 2>/dev/null || true
}
trap cleanup EXIT HUP INT TERM
chmod 0700 "$canary_dir"

# Assemble the synthetic credential at runtime so no complete canary is committed.
printf 'AWS_ACCESS_KEY_ID=%s%s%s\n' 'AKIA' 'A2B3C4D5' 'E6F7G2H3' > "$canary_dir/credential.env"
chmod 0600 "$canary_dir/credential.env"
set +e
gitleaks dir "$canary_dir" --no-banner --redact --exit-code 23 >/dev/null 2>&1
canary_status=$?
set -e
[[ $canary_status -eq 23 ]] || {
  echo "Gitleaks canary was not detected; refusing real scans" >&2
  exit 1
}

gitleaks git --log-opts="--all" --no-banner --redact --verbose
gitleaks dir . --no-banner --redact --verbose
