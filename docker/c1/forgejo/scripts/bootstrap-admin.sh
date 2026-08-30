#!/usr/bin/env bash
set -euo pipefail

readonly container="forgejo-c1"
readonly username="trosvald"

if docker exec "${container}" forgejo admin user list --admin | grep -Eq "(^|[[:space:]])${username}([[:space:]]|$)"; then
    printf '%s\n' "Forgejo administrator ${username} already exists"
    exit 0
fi

docker exec "${container}" sh -ceu '
    exec forgejo admin user create \
        --username "$1" \
        --password "$(cat /run/secrets/bootstrap_admin_password)" \
        --email "$(cat /run/secrets/bootstrap_admin_email)" \
        --admin \
        --must-change-password=false
' sh "${username}"

printf '%s\n' "Created Forgejo administrator ${username}; remove bootstrap projections and redeploy"
