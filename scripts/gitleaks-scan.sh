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
staging_dir="$(mktemp -d "${TMPDIR:-/tmp}/gitleaks-staging.XXXXXX")"
cleanup() {
  find "$canary_dir" "$staging_dir" -type f -exec chmod 0600 {} + 2>/dev/null || true
  rm -rf -- "$canary_dir" "$staging_dir"
}
trap cleanup EXIT HUP INT TERM
chmod 0700 "$canary_dir" "$staging_dir"

# Assemble the synthetic credential at runtime so no complete canary is committed.
mkdir -m 0700 "$canary_dir/.private"
printf 'AWS_ACCESS_KEY_ID=%s%s%s\n' 'AKIA' 'A2B3C4D5' 'E6F7G2H3' > "$canary_dir/.private/credential.env"
chmod 0600 "$canary_dir/.private/credential.env"
set +e
gitleaks dir "$canary_dir/.private" --no-banner --redact --exit-code 23 >/dev/null 2>&1
canary_status=$?
set -e
[[ $canary_status -eq 23 ]] || {
  echo "Gitleaks canary was not detected, including under a formerly excluded path; refusing real scans" >&2
  exit 1
}

# Scan the current worktree without ever traversing ignored local secret directories.
# Force-added/history content remains covered by the unfiltered Git scan below.
while IFS= read -r -d '' path; do
  [[ -f "$path" && ! -L "$path" ]] || continue
  target="$staging_dir/$path"
  mkdir -p -m 0700 "$(dirname "$target")"
  install -m 0600 "$path" "$target"
done < <(git ls-files --cached --others --exclude-standard -z)

gitleaks git --log-opts="--all" --no-banner --redact --verbose
gitleaks dir "$staging_dir" --no-banner --redact --verbose
