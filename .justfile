#!/usr/bin/env -S just --justfile

set default-script
set lazy
set quiet
set script-interpreter := ['bash', '-euo', 'pipefail']
set shell := ['bash', '-euo', 'pipefail', '-c']

# Bootstrap Recipes
[group: 'Bootstrap']
mod bootstrap "bootstrap"

# Kube Recipes
[group: 'Kube']
mod kube "kubernetes"

# Talos Recipes
[group: 'Talos']
mod talos "talos"

# Ansible project dispatcher
[group: 'Ansible']
mod ansible "ansible"

# Docker Recipes
[group: 'Docker']
mod docker "docker"

[group: 'Toolchain']
[confirm('Regenerate the reviewed multi-platform Mise lockfile? [y|N]')]
[doc('Regenerate exact tool versions and checksums from .mise.toml')]
toolchain-lock:
    mise lock

[group: 'Toolchain']
[doc('Install the exact locked repository toolchain')]
toolchain-install:
    mise install --locked

[group: 'OpenBao']
[doc('Unseal c0 OpenBao with two hidden interactive share prompts')]
openbao-unseal:
    scripts/unseal-openbao.sh

[group: 'OpenBao']
[doc('Authenticate the local Bao CLI for an explicit administrator operation')]
openbao-admin-login:
    BAO_ADDR=https://vault.monosense.io:8200 bao login -method=userpass -no-print username=monosense-admin

[group: 'OpenBao']
[confirm('Provision or rotate the live monosense-infra OpenBao identity? [y|N]')]
[doc('Install and verify the least-privilege monosense-infra identity')]
provision-openbao-infra:
    scripts/provision-openbao-infra.sh

[group: 'OpenBao']
[confirm('Create first-use application records, libreFS account, and wildcard certificate? [y|N]')]
[doc('Provision application records transactionally through monosense-infra')]
provision-openbao-applications:
    scripts/with-openbao-runtime.sh scripts/provision-container-application-records.sh

[group: 'OpenBao']
[confirm('Bind protected Junos EDGE topology to the observed MYREP address? [y|N]')]
[doc('Provision exact EDGE, monitoring, Blocky, and MYREP topology fields')]
provision-junos-edge-topology:
    scripts/with-openbao-runtime.sh scripts/provision-junos-edge-topology.sh

[group: 'OpenBao']
[confirm('Enable public Junos EDGE policy and destination NAT? [y|N]')]
[doc('Enable the protected Junos Candidate B deployment gate')]
enable-junos-public-edge:
    scripts/with-openbao-runtime.sh scripts/provision-junos-edge-topology.sh enable-public

[group: 'OpenBao']
[confirm('Disable public Junos EDGE policy and destination NAT? [y|N]')]
[doc('Disable the protected Junos Candidate B deployment gate')]
disable-junos-public-edge:
    scripts/with-openbao-runtime.sh scripts/provision-junos-edge-topology.sh disable-public

[group: 'OpenBao']
[doc('Refresh the Doco token and published TLS libreFS prerequisite')]
prepare-container-applications:
    scripts/with-openbao-runtime.sh scripts/run-container-nodes-openbao-action.sh prepare-applications

[group: 'OpenBao']
[confirm('Materialize protected container application secrets on c1 and c0? [y|N]')]
[doc('Provision protected container secrets through monosense-infra')]
provision-container-secrets:
    scripts/with-openbao-runtime.sh scripts/run-container-nodes-openbao-action.sh provision-secrets

[group: 'OpenBao']
[confirm('Rotate and publish the dedicated Vector-to-SRX TLS certificate? [y|N]')]
[doc('Issue a strictly verified Vector certificate for SRX flow streaming')]
rotate-vector-srx-certificate:
    scripts/with-openbao-runtime.sh scripts/rotate-vector-srx-certificate.sh

[group: 'OpenBao']
[doc('Verify host, application, and OpenBao contracts through monosense-infra')]
verify-container-applications:
    CONTAINER_NODES_VERIFY_SCOPE=all scripts/with-openbao-runtime.sh scripts/run-container-nodes-openbao-action.sh verify

[group: 'OpenBao']
[confirm('Create the reviewed BGP and Talos OpenBao records with CAS=0? [y|N]')]
[doc('Create or validate protected BGP and Talos records without overwriting')]
provision-talos-records:
    scripts/provision-talos-records.sh

[group: 'Security']
[doc('Prove secret detection and scan Git history plus the working tree')]
scan-secrets:
    scripts/gitleaks-scan.sh

[private]
default:
    just -l

[private]
log lvl msg *args:
    gum log -t rfc3339 -s -l "{{ lvl }}" "{{ msg }}" {{ args }}

[private]
template file *args:
    minijinja-cli "{{ file }}" {{ args }} | op inject
