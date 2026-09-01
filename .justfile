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
[confirm('Rotate and publish the dedicated Vector-to-SRX TLS certificate? [y|N]')]
[doc('Issue a strictly verified Vector certificate for SRX flow streaming')]
rotate-vector-srx-certificate:
    scripts/with-openbao-runtime.sh scripts/rotate-vector-srx-certificate.sh

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
