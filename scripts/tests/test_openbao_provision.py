#!/usr/bin/env python3
from pathlib import Path

root = Path(__file__).resolve().parents[2]
provision = (root / "scripts/provision-openbao-infra.sh").read_text(encoding="utf-8")
runtime = (root / "scripts/with-openbao-runtime.sh").read_text(encoding="utf-8")
applications = (root / "scripts/provision-container-application-records.sh").read_text(encoding="utf-8")
rotation = (root / "scripts/rotate-vector-srx-certificate.sh").read_text(encoding="utf-8")
justfile = (root / ".justfile").read_text(encoding="utf-8")

assert 'SOPS_AGE_KEY_FILE="${SOPS_AGE_KEY_FILE:-$HOME/.config/sops/age/keys.txt}"' in provision
assert 'SOPS_AGE_KEY_FILE="${SOPS_AGE_KEY_FILE:-$HOME/.config/sops/age/keys.txt}"' in runtime
assert "bao policy write monosense-infra" in provision
assert "auth/userpass/users/monosense-infra" in provision
assert 'token_ttl: "15m"' in provision
assert 'token_max_ttl: "30m"' in provision
assert "token capabilities" in provision
for policy in ("wildcard-publisher", "wildcard-reader-c0", "wildcard-reader-c1"):
    assert f"bao policy write \"$policy\"" in provision
    assert f"auth/token/roles/{policy}" not in provision
assert provision.count('bao write "auth/token/roles/$policy"') == 1
assert 'auth/token/create/$role' in provision
assert "token_period=24h" in provision
assert "token_max_ttl=" not in provision
assert provision.count("kv/data/") >= 6
assert "kv/metadata/network/bgp/cilium-srx1500" in provision
assert "auth/token/create" in provision
assert "sys/policies/acl/monosense-infra" in provision
assert 'bao token revoke -self' in provision
assert "auth/userpass/login/monosense-infra -" in provision
assert "password=$" not in provision
assert "jq '{password: .BAO_PASSWORD}'" in provision
assert "monosense-admin password: " in provision
assert "auth/userpass/login/monosense-admin -" in provision
assert "unset admin_password" in provision
assert 'BAO_TOKEN="$admin_token" bao token revoke -self' in provision
assert "jq -er '.BAO_PASSWORD'" not in provision
assert "BAO_PASSWORD=" not in provision
assert "jq '{password: .BAO_PASSWORD}'" in runtime
assert "auth/userpass/login/monosense-infra -" in runtime
assert "jq -er '.BAO_PASSWORD'" not in runtime
assert "password=-" not in runtime
assert "BAO_PASSWORD=" not in runtime
for source in (provision, runtime):
    assert 'test("^[A-Za-z0-9_-]+$")' not in source
    assert "(.BAO_PASSWORD | explode | all(. >= 33 and . <= 126))" in source
assert "openbao-admin-login:" in justfile
assert "provision-openbao-infra:" in justfile
assert "bao login -method=userpass -no-print username=monosense-admin" in justfile
assert "scripts/provision-openbao-infra.sh" in justfile
assert "provision-openbao-applications:" in justfile
assert "scripts/with-openbao-runtime.sh scripts/provision-container-application-records.sh" in justfile
assert "scripts/provision-container-application-records.sh)" in runtime
assert "scripts/run-container-nodes-openbao-action.sh)" in runtime
assert "provision-container-secrets:" in justfile
assert "verify-container-applications:" in justfile
assert "prepare-container-applications:" in justfile
assert "scripts/normalize-wildcard-metadata.sh)" in runtime
assert "scripts/rotate-vector-srx-certificate.sh)" in runtime
assert "rotate-vector-srx-certificate:" in justfile
assert "scripts/rotate-vector-srx-certificate.sh" in applications
assert "subjectAltName=IP:10.25.13.37" in rotation
assert '"options": {"cas": int(sys.argv[2])}' in rotation
assert "BAO_SKIP_VERIFY" not in rotation
assert "IFS= read -r -s -p" in applications
assert '"options":{"cas":0}' in applications
assert 'bao write "kv/data/$1" -' in applications
assert "bao kv put" not in applications
assert "certbot/dns-cloudflare:v5.7.0@sha256:" in applications
assert ".DEFAULT.dns_cloudflare_api_token" in applications
assert "mc --config-dir" in applications
assert "admin user add local >/dev/null" in applications
assert "minio/mc@" not in applications
assert "ExitOnForwardFailure=yes" in applications
assert "10.25.13.65:9000" in applications
assert '"aqua:minio/mc"' in (root / ".mise.toml").read_text(encoding="utf-8")
assert "librefs-created" in applications
assert 'bao kv metadata delete -mount=kv "$record"' in applications
assert '"$runtime/committed-records"' in applications
assert "No placeholder" not in applications
print("OpenBao provisioner keeps password material off argv and verifies exact capabilities")
