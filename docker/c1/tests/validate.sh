#!/usr/bin/env bash
set -euo pipefail
readonly ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
cd "$ROOT"
yamllint docker/c1/.doco-cd.yaml docker/c1/.doco-cd/docker-compose.app.yaml docker/c1/.doco-cd/poll-config.yml \
  docker/c1/librefs/.doco-cd.yaml docker/c1/librefs/compose.yml \
  docker/c1/edge/.doco-cd.yaml docker/c1/edge/compose.yml \
  docker/c1/forgejo/.doco-cd.yaml docker/c1/forgejo/compose.yml
bash -n docker/c1/librefs/tests/validate.sh \
  docker/c1/edge/tests/validate.sh docker/c1/edge/tests/haproxy-config.sh \
  docker/c1/forgejo/tests/validate.sh
python3 -m py_compile docker/scripts/install_certificate.py \
  docker/c1/edge/scripts/publish-wildcard.py \
  docker/c1/forgejo/scripts/configure-mirror.py
python3 docker/c0/openbao/policies/tests/test_doco_c1_policy.py
docker/c1/librefs/tests/validate.sh
docker/c1/edge/tests/validate.sh
printf 'c1 edge Compose contract passed\n'
docker/c1/edge/tests/haproxy-config.sh
printf 'c1 HAProxy runtime contract passed\n'
docker/c1/forgejo/tests/validate.sh
printf 'c1 Forgejo Compose contract passed\n'
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
assert poll == [{"url":"https://git.monosense.io/trosvald/infrastructure.git","reference":"refs/heads/main","interval":"180s","watch":False}]
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
recognized={"compose.yaml","compose.yml","docker-compose.yml","docker-compose.yaml"}
boundary=root/".doco-cd"
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
assert sorted(projects)==["edge","forgejo","librefs"]
PY
printf 'c1 aggregate repository validation passed\n'
