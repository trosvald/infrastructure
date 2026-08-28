#!/usr/bin/env python3
from pathlib import Path

root = Path(__file__).resolve().parents[2]
provision = (root / "scripts/provision-openbao-infra.sh").read_text(encoding="utf-8")
runtime = (root / "scripts/with-openbao-runtime.sh").read_text(encoding="utf-8")
justfile = (root / ".justfile").read_text(encoding="utf-8")

assert 'SOPS_AGE_KEY_FILE="${SOPS_AGE_KEY_FILE:-$HOME/.config/sops/age/keys.txt}"' in provision
assert 'SOPS_AGE_KEY_FILE="${SOPS_AGE_KEY_FILE:-$HOME/.config/sops/age/keys.txt}"' in runtime
assert "bao policy write monosense-infra" in provision
assert "auth/userpass/users/monosense-infra" in provision
assert 'token_ttl: "15m"' in provision
assert 'token_max_ttl: "30m"' in provision
assert "token capabilities" in provision
assert provision.count("kv/data/") >= 6
assert "kv/metadata/network/bgp/cilium-srx1500" in provision
assert "auth/token/create" in provision
assert "sys/policies/acl/monosense-infra" in provision
assert 'bao token revoke -self' in provision
assert "auth/userpass/login/monosense-infra -" in provision
assert "password=$" not in provision
assert "jq '{password: .BAO_PASSWORD}'" in provision
assert "jq -er '.BAO_PASSWORD'" not in provision
assert "BAO_PASSWORD=" not in provision
assert "jq '{password: .BAO_PASSWORD}'" in runtime
assert "auth/userpass/login/monosense-infra -" in runtime
assert "jq -er '.BAO_PASSWORD'" not in runtime
assert "password=-" not in runtime
assert "BAO_PASSWORD=" not in runtime
assert "openbao-admin-login:" in justfile
assert "provision-openbao-infra:" in justfile
assert "bao login -method=userpass -no-print username=monosense-admin" in justfile
assert "scripts/provision-openbao-infra.sh" in justfile
print("OpenBao provisioner keeps password material off argv and verifies exact capabilities")
