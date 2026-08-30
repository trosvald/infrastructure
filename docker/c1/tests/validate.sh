#!/usr/bin/env bash
set -euo pipefail
readonly ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
cd "$ROOT"
yamllint docker/c1/.doco-cd.yaml docker/c1/.doco-cd/docker-compose.app.yaml docker/c1/.doco-cd/poll-config.yml \
  docker/c1/librefs/.doco-cd.yaml docker/c1/librefs/compose.yml \
  docker/c1/edge/.doco-cd.yaml docker/c1/edge/compose.yml \
  docker/c1/forgejo/.doco-cd.yaml docker/c1/forgejo/compose.yml
bash -n docker/c1/.host/networks/services/ensure.sh docker/c1/.host/networks/services/ensure-shim.sh \
  docker/c1/.host/networks/services/tests/ensure.sh docker/c1/.host/networks/services/tests/ensure-shim.sh \
  docker/c1/.host/storage/ensure.sh docker/c1/.host/storage/assert-mount.sh \
  docker/c1/.host/storage/install-storage-assets.sh docker/c1/.host/storage/tests/ensure.sh \
  docker/c1/.host/storage/tests/install-storage-assets.sh \
  docker/c1/.host/storage/ensure-forgejo-quotas.sh \
  docker/c1/.host/storage/ensure-edge-state.sh \
  docker/c1/.host/systemd/manage-librefs.sh docker/c1/.host/systemd/tests/manage-librefs.sh \
  docker/c1/.host/openbao/renew-token.sh docker/c1/.host/openbao/check-token-ttl.sh \
  docker/c1/.host/openbao/check-doco-controller.sh docker/c1/.host/openbao/install-token.sh \
  docker/c1/.host/openbao/install-api-secret.sh \
  docker/c1/.host/openbao/rematerialize-librefs-credentials.sh \
  docker/c1/.host/openbao/tests/helpers.sh docker/c1/.host/openbao/tests/controller.sh \
  docker/c1/.host/openbao/tests/rematerialize.sh docker/c1/librefs/tests/validate.sh \
  docker/c1/edge/tests/validate.sh docker/c1/edge/tests/haproxy-config.sh \
  docker/c1/forgejo/tests/validate.sh docker/c1/forgejo/scripts/backup.sh \
  docker/c1/forgejo/scripts/bootstrap-admin.sh \
  docker/c1/.host/networks/edge/ensure.sh docker/c1/.host/networks/edge/install.sh \
  docker/c1/.host/networks/edge/tests/ensure.sh \
  docker/c1/.host/networks/edge/ensure-forgejo-egress.sh \
  docker/c1/.host/networks/edge/tests/ensure-forgejo-egress.sh \
  docker/c1/.host/openbao/update-wildcard-certificate.sh \
  docker/c1/.host/openbao/materialize-forgejo-backup-heartbeat.sh \
  docker/c1/.host/openbao/install-wildcard-assets.sh
python3 -m py_compile docker/scripts/install_certificate.py \
  docker/scripts/fetch_wildcard_certificate.py docker/scripts/materialize_c1_app_secrets.py \
  docker/c1/edge/scripts/publish-wildcard.py docker/c1/forgejo/scripts/haproxy-runtime.py \
  docker/c1/forgejo/scripts/configure-mirror.py
python3 docker/c0/openbao/policies/tests/test_doco_c1_policy.py
docker/c1/.host/networks/services/tests/ensure.sh
docker/c1/.host/networks/services/tests/ensure-shim.sh
docker/c1/.host/storage/tests/ensure.sh
docker/c1/.host/storage/tests/install-storage-assets.sh
docker/c1/.host/storage/tests/ensure-forgejo-quotas.sh
docker/c1/.host/networks/edge/tests/ensure.sh
docker/c1/.host/networks/edge/tests/ensure-forgejo-egress.sh
docker/c1/.host/systemd/tests/manage-librefs.sh
docker/c1/.host/openbao/tests/helpers.sh
docker/c1/.host/openbao/tests/controller.sh
docker/c1/.host/openbao/tests/rematerialize.sh
docker/c1/librefs/tests/validate.sh
docker/c1/edge/tests/validate.sh
docker/c1/edge/tests/haproxy-config.sh
docker/c1/forgejo/tests/validate.sh
DOCO_CD_API_SECRET_FILE=/dev/null DOCO_CD_OPENBAO_TOKEN_FILE=/dev/null docker compose -f docker/c1/.doco-cd/docker-compose.app.yaml config --quiet
python3 - <<'PY'
from pathlib import Path
import json
import subprocess
root=Path("docker/c1")
def yaml(path):
 return json.loads(subprocess.check_output(["yq","-o=json",str(path)],text=True))
mapping=yaml(root/".doco-cd.yaml")
assert mapping == {"working_dir":"./docker/c1","auto_discovery":{"enabled":True,"depth":1,"delete":False},"force_recreate":False,"reconciliation":{"enabled":False}}
poll=yaml(root/".doco-cd/poll-config.yml")
assert poll == [{"url":"https://github.com/trosvald/infrastructure.git","reference":"refs/heads/main","interval":"180s","watch":False}]
c=yaml(root/".doco-cd/docker-compose.app.yaml"); s=c["services"]["doco-cd"]
assert c["name"]=="doco-cd-c1" and s["container_name"]=="doco-cd-c1" and s["restart"]=="no"
assert s["image"]=="ghcr.io/kimdre/doco-cd:0.111.0@sha256:8c31f63f6bde1b67f0802619bad0599bf5e41503f5532be9cc58d0f063b1eeea"
assert s["ports"]==["127.0.0.1:8080:80","127.0.0.1:9120:9120"]
e=s["environment"]
assert e["DEPLOY_CONFIG_BASE_DIR"]=="./docker/c1/" and e["SECRET_PROVIDER"]=="openbao"
assert e["SECRET_PROVIDER_SITE_URL"]=="https://vault.monosense.io:8200" and e["SECRET_PROVIDER_ACCESS_TOKEN_FILE"]=="/run/secrets/openbao_token"
assert not any("SOPS" in key for key in e)
assert s["extra_hosts"]==["vault.monosense.io:10.25.13.34"] and "/var/run/docker.sock:/var/run/docker.sock" in s["volumes"]
assert s["healthcheck"]["test"]==["CMD","/doco-cd","healthcheck"] and s["logging"]["options"]=={"max-size":"10m","max-file":"3"}
assert c["volumes"]["doco-cd-c1-data"]["name"]=="doco-cd-c1-data"
renew=(root/".host/openbao/renew-token.sh").read_text()
gate=(root/".host/openbao/check-token-ttl.sh").read_text()
controller_gate=(root/".host/openbao/check-doco-controller.sh").read_text()
installer=(root/".host/openbao/install-token.sh").read_text()
api_installer=(root/".host/openbao/install-api-secret.sh").read_text()
controller_unit=(root/".host/openbao/doco-cd-c1.service").read_text()
timer=(root/".host/openbao/doco-c1-openbao-renew.timer").read_text()
assert '/dev/fd/3' in renew and 'X-Vault-Token' in renew and "--proto '=https'" in renew and 'renew-self' in renew
assert '/dev/fd/3' in gate and 'lookup-self' in gate and 'ttl>int(sys.argv[1])' in gate
assert '/v1/api/projects' in controller_gate and 'pre-merge API authentication passed' in controller_gate
assert '/v1/api/poll/run?wait=true' in controller_gate and '/v1/api/run/$job_id' in controller_gate
assert 'APP_CONFIG_URL' in controller_gate and 'REQUIRE_PROVIDER_CANARY' in controller_gate
assert 'env REQUIRE_PROVIDER_CANARY=true "$CONTROLLER_GATE"' in installer
assert 'restart "$SERVICE"' in installer
assert 'env REQUIRE_PROVIDER_CANARY=true "$CONTROLLER_GATE"' in api_installer
assert 'os.fsync' in api_installer and 'os.replace' in api_installer
assert 'ExecStartPre=/usr/local/sbin/check-c1-openbao-token' in controller_unit
assert 'ExecStartPre=/usr/local/sbin/materialize-c1-app-secrets' in controller_unit
network_unit=(root/".host/networks/services/c1-services-network.service").read_text()
assert 'c1-services-shim.service' in network_unit
assert 'ExecStart=/usr/local/sbin/ensure-c1-services-network apply' in network_unit
assert 'c1-services-network.service' in controller_unit
assert 'up --force-recreate --no-deps doco-cd' in controller_unit and 'Restart=on-failure' in controller_unit
assert 'c1-librefs-storage.service c1-applications-storage.service' in controller_unit
assert 'Persistent=true' in timer and 'OnBootSec=5min' in timer and 'OnUnitActiveSec=6h' in timer
storage=(root/".host/storage/ensure.sh").read_text()
storage_installer=(root/".host/storage/install-storage-assets.sh").read_text()
librefs_unit=(root/".host/storage/templates/c1-librefs-storage.service").read_text()
applications_unit=(root/".host/storage/templates/c1-applications-storage.service").read_text()
assert '512GB_EXCLUDED=true' in storage and 'DOCKER_ROOTS_REMAIN_OS=true' in storage
assert 'c1_librefs' in storage and 'c1_applications' in storage and '/srv/containers' not in storage
assert 'c1-librefs-storage.service c1-applications-storage.service' in storage_installer
assert 'RequiresMountsFor=/srv/librefs' in librefs_unit
librefs_start_unit=(root/".host/systemd/librefs-c1.service").read_text()
assert 'c1-services-network.service' in librefs_start_unit
assert 'c1-librefs-storage.service' in librefs_start_unit
assert 'ExecStartPre=/usr/local/sbin/assert-c1-mount librefs /srv/librefs' in librefs_start_unit
assert 'ExecStart=/usr/local/sbin/manage-c1-librefs start' in librefs_start_unit
assert 'RequiresMountsFor=/srv/applications' in applications_unit
for obsolete in (
 root/".host/storage/templates/containerd-c1-storage.conf",
 root/".host/storage/templates/docker-c1-storage.conf",
 root/".host/storage/templates/daemon.json",
):
 assert not obsolete.exists()
recognized={"compose.yaml","compose.yml","docker-compose.yml","docker-compose.yaml"}
for boundary in (root/".doco-cd",root/".host"):
 offenders=sorted(p for p in boundary.rglob("*") if p.name in recognized)
 assert not offenders, f"recognized Compose file below bootstrap boundary: {offenders}"
# Every declared c1 SERVICES attachment has exactly one reviewed static endpoint.
expected_services={"librefs-c1":"10.25.13.65"}; seen_services={}
expected_edge={"haproxy-c1":"10.25.15.10"}; seen_edge={}
projects=[]
for compose in root.glob("*/compose.yml"):
 data=yaml(compose)
 projects.append(compose.parent.name)
 for service in data.get("services",{}).values():
  name=service.get("container_name")
  networks=service.get("networks",{})
  network=networks.get("c1_services") if isinstance(networks,dict) else None
  if network is not None:
   ip=network.get("ipv4_address") if isinstance(network,dict) else None
   assert name in expected_services and ip==expected_services[name] and name not in seen_services
   seen_services[name]=ip
  edge=networks.get("c1_edge") if isinstance(networks,dict) else None
  if edge is not None:
   ip=edge.get("ipv4_address") if isinstance(edge,dict) else None
   assert name in expected_edge and ip==expected_edge[name] and name not in seen_edge
   seen_edge[name]=ip
assert seen_services==expected_services
assert seen_edge==expected_edge
edge_interface=(root/".host/networks/edge/interfaces.d/c1-edge").read_text()
assert "bond-mode" not in edge_interface and "vlan-raw-device bond0" in edge_interface
assert "disable_ipv6=1" in edge_interface
assert "ip -6 address flush dev $IFACE scope link" in edge_interface
assert sorted(projects)==["edge","forgejo","librefs"]
PY
printf 'c1 aggregate repository validation passed\n'
