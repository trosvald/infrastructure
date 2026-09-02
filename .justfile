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
[confirm('Enable the exact Kubernetes auth and private-PKI administration envelope? [y|N]')]
[doc('Create Kubernetes auth and PKI mounts through offline monosense-admin')]
provision-openbao-kubernetes-envelope:
    scripts/provision-openbao-kubernetes-envelope.sh

[group: 'OpenBao']
[confirm('Configure exact Kubernetes auth roles, policies, and PKI roles? [y|N]')]
[doc('Configure Kubernetes integration through monosense-infra')]
configure-openbao-kubernetes:
    scripts/with-openbao-runtime.sh scripts/configure-openbao-kubernetes.sh

[group: 'OpenBao']
[doc('Verify Kubernetes auth, KV, PKI, audience, and revocation boundaries')]
verify-openbao-kubernetes:
    scripts/with-openbao-runtime.sh scripts/verify-openbao-kubernetes.sh

[group: 'OpenBao']
[confirm('Create first-use application records, libreFS account, and wildcard certificate? [y|N]')]
[doc('Provision application records transactionally through monosense-infra')]
provision-openbao-applications:
    scripts/with-openbao-runtime.sh scripts/provision-container-application-records.sh

[group: 'OpenBao']
[confirm('Create the shared PowerDNS and ExternalDNS TSIG identity? [y|N]')]
[doc('Provision scoped RFC 2136 update credentials')]
provision-powerdns-dynamic-dns:
    scripts/with-openbao-runtime.sh scripts/provision-powerdns-dynamic-dns.sh

[group: 'OpenBao']
[confirm('Create the scoped Kubernetes libreFS bucket and OpenBao record? [y|N]')]
[doc('Provision the TLS libreFS Kubernetes backup identity')]
provision-kubernetes-backup:
    scripts/with-openbao-runtime.sh scripts/provision-kubernetes-backup.sh

[group: 'OpenBao']
[confirm('Verify and lock the private R2 Kopia destination for 30 days? [y|N]')]
[doc('Provision the scoped R2 record and immutable prefix')]
provision-kubernetes-r2-backup:
    scripts/with-openbao-runtime.sh scripts/provision-kubernetes-r2-backup.sh

[group: 'OpenBao']
[confirm('Create database credentials, libreFS identity, and immutable R2 prefix? [y|N]')]
[doc('Provision database credentials and backup destinations')]
provision-database-secrets:
    scripts/with-openbao-runtime.sh scripts/provision-database-secrets.sh

[group: 'OpenBao']
[confirm('Create Keycloak clients, runner, versioned state, and immutable R2 prefix? [y|N]')]
[doc('Provision identity credentials and OpenTofu state')]
provision-identity-secrets:
    scripts/with-openbao-runtime.sh scripts/provision-identity-secrets.sh

[group: 'OpenBao']
[confirm('Create Grafana, Telegram, SNMPv3, and Vector mTLS credentials? [y|N]')]
[doc('Provision observability credentials and host client certificates')]
provision-observability-secrets:
    scripts/with-openbao-runtime.sh scripts/provision-observability-secrets.sh

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
[doc('Recover c1 prerequisites, scoped tokens, and Doco applications after an outage')]
recover-c1-containers:
    scripts/with-openbao-runtime.sh scripts/run-container-nodes-openbao-action.sh recover-c1

[group: 'OpenBao']
[doc('Restore c0 Gatus checks and Telegram alert delivery')]
recover-monitoring-alerts:
    scripts/with-openbao-runtime.sh scripts/run-container-nodes-openbao-action.sh recover-monitoring

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

[group: 'Forgejo']
[confirm('Refresh and prove the public Forgejo infrastructure mirror? [y|N]')]
[doc('Prepare the public Forgejo source and prove exact ref parity')]
prepare-forgejo-source-cutover:
    just ansible container-nodes forgejo-source-prepare

[group: 'Forgejo']
[confirm('Convert Forgejo to the sole writable infrastructure source? [y|N]')]
[doc('Cut over Forgejo only after fresh backup, parity, and anonymous-read proof')]
cutover-forgejo-source:
    just ansible container-nodes forgejo-source-cutover

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
