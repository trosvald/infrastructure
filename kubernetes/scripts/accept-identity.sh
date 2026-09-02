#!/usr/bin/env bash
set -euo pipefail

fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
for command in base64 curl jq kubectl mktemp; do
    command -v "$command" >/dev/null 2>&1 || fail "$command is required"
done
work="$(mktemp -d)"
probe="identity-accept-$(date +%s)"
cleanup() {
    kubectl -n security delete pod "$probe" --ignore-not-found --wait=false >/dev/null 2>&1 || true
    rm -rf "$work"
}
trap cleanup EXIT
chmod 0700 "$work"

[[ "$(kubectl -n security get keycloak keycloak -o json | jq -r '.status.conditions[] | select(.type == "Ready") | .status')" == True ]] \
    || fail 'Keycloak is not Ready'
[[ "$(kubectl -n security get pods -l app=keycloak -o json | jq '[.items[] | select(.status.phase == "Running" and all(.status.containerStatuses[]; .ready))] | length')" == 2 ]] \
    || fail 'Keycloak does not have two Ready replicas'
! kubectl -n security get secret keycloak-bootstrap-admin >/dev/null 2>&1 \
    || fail 'one-time bootstrap Secret still exists'
test -z "$(kubectl -n security get keycloak keycloak -o jsonpath='{.spec.bootstrapAdmin}' 2>/dev/null)" \
    || fail 'one-time bootstrapAdmin reference still exists'

kubectl -n security get secret keycloak-tofu-runner -o json \
    | jq -er '.data.keycloak_ca_certificate' | base64 -d >"$work/ca.pem"
kubectl -n security get secret keycloak-tofu-runner -o json \
    | jq -er '.data.tofu_admin_client_secret' | base64 -d >"$work/client-secret"
chmod 0600 "$work/ca.pem" "$work/client-secret"
curl --fail --silent --show-error --cacert "$work/ca.pem" \
    --resolve auth.internal:443:10.25.20.40 \
    https://auth.internal/realms/monosense/.well-known/openid-configuration \
    | jq -e '.issuer == "https://auth.internal/realms/monosense" and .authorization_endpoint and .token_endpoint' >/dev/null
curl --fail --silent --show-error --cacert "$work/ca.pem" \
    --resolve auth-admin.internal:443:10.25.20.40 \
    --data-urlencode client_id=keycloak-tofu --data-urlencode grant_type=client_credentials \
    --data-urlencode "client_secret@${work}/client-secret" \
    https://auth-admin.internal/realms/master/protocol/openid-connect/token >"$work/token.json"
jq -er '.access_token' "$work/token.json" >"$work/access-token"
printf 'header = "Authorization: Bearer %s"\n' "$(<"$work/access-token")" >"$work/admin.conf"
chmod 0600 "$work/access-token" "$work/admin.conf"
admin=(curl --config "$work/admin.conf" --fail --silent --show-error --cacert "$work/ca.pem" --resolve auth-admin.internal:443:10.25.20.40)
"${admin[@]}" https://auth-admin.internal/admin/realms/monosense >"$work/realm.json"
jq -e '
    .accessTokenLifespan == 300 and .ssoSessionIdleTimeout == 28800 and
    .ssoSessionMaxLifespan == 43200 and .revokeRefreshToken == true and
    .refreshTokenMaxReuse == 0 and .bruteForceProtected == true and
    .eventsEnabled == true and .eventsExpiration == 2592000 and
    .adminEventsEnabled == true and .adminEventsDetailsEnabled == false
' "$work/realm.json" >/dev/null || fail 'realm token, session, brute-force, or redacted event policy changed'
"${admin[@]}" https://auth-admin.internal/admin/realms/monosense/authentication/flows >"$work/flows.json"
jq -e '[.[] | select(.alias == "monosense-browser")] | length == 1' "$work/flows.json" >/dev/null \
    || fail 'passkey-first browser flow is absent'
"${admin[@]}" 'https://auth-admin.internal/admin/realms/monosense/users?max=100' >"$work/users.json"
jq -e '[.[] | select(.requiredActions | index("CONFIGURE_TOTP")) | select(.requiredActions | index("CONFIGURE_RECOVERY_AUTHN_CODES")) | select(.requiredActions | index("webauthn-register-passwordless"))] | length >= 1' "$work/users.json" >/dev/null \
    || fail 'no human administrator requires passkey, TOTP, and offline recovery codes'
"${admin[@]}" 'https://auth-admin.internal/admin/realms/monosense/clients?max=100' >"$work/clients.json"
for client in ceph alertmanager victorialogs memini grafana; do
    [[ "$(jq --arg client "$client" '[.[] | select(.clientId == $client and .enabled == true and .publicClient == false and .directAccessGrantsEnabled == false and .serviceAccountsEnabled == false)] | length' "$work/clients.json")" == 1 ]] \
        || fail "OIDC client $client is absent or over-capable"
done

for proxy in ceph alertmanager vlogs memini; do
    [[ "$(kubectl -n security get deployment "oauth2-proxy-$proxy" -o json | jq '.status.readyReplicas // 0')" == 2 ]] \
        || fail "oauth2-proxy-$proxy does not have two Ready replicas"
done
for host in ceph.monosense.io alertmanager.monosense.io vlogs.monosense.io memini.monosense.io; do
    headers="$work/${host}.headers"
    curl --silent --show-error --cacert "$work/ca.pem" --resolve "$host:443:10.25.20.40" \
        --output /dev/null --dump-header "$headers" "https://$host/"
    grep -Eq '^HTTP/[12](\.[01])? 302' "$headers" || fail "$host does not redirect unauthenticated browsers"
    grep -Eiq '^set-cookie: __Host-.*;.*[Ss]ecure;.*[Hh]ttp[Oo]nly;.*[Ss]ame[Ss]ite=[Ll]ax' "$headers" \
        || fail "$host cookie boundary changed"
done

kubectl -n security run "$probe" --restart=Never \
    --image=data.forgejo.org/forgejo/runner:13.1.0@sha256:96af81b1b0cd928f3f135fb8dc021d47cff868c151a4fd28af971e892990ee7a \
    --command -- /bin/sh -ec 'wget -q -T 5 -O /dev/null http://rook-ceph-mgr-dashboard.rook-ceph.svc.cluster.local:7000' >/dev/null
if kubectl -n security wait --for=jsonpath='{.status.phase}'=Succeeded pod/"$probe" --timeout=20s >/dev/null 2>&1; then
    fail 'Ceph dashboard is reachable without its dedicated oauth2-proxy identity'
fi
kubectl -n security delete pod "$probe" --wait=true >/dev/null

kubectl -n security rollout status deployment/keycloak-tofu-runner --timeout=5m >/dev/null
kubectl -n security exec deployment/keycloak-tofu-runner -- /bin/sh -ec '
    work="$(mktemp -d /workspace/accept.XXXXXX)"
    trap '\''rm -rf "$work"'\'' EXIT
    git -c credential.helper= clone --no-tags --filter=blob:none https://git.monosense.io/trosvald/infrastructure.git "$work/repository" >/dev/null 2>&1
    sha="$(git -C "$work/repository" rev-parse HEAD)"
    FORGEJO_SHA="$sha" FORGEJO_REF_NAME=main "$work/repository/kubernetes/apps/security/keycloak-tofu/run-tofu.sh" drift
'
printf 'Identity acceptance passed: fail-closed Keycloak, isolated proxies, bootstrap removal, and clean-runner encrypted drift plan\n'
