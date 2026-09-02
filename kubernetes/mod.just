set default-script
set quiet
set script-interpreter := ['bash', '-euo', 'pipefail']
set shell := ['bash', '-euo', 'pipefail', '-c']

[private]
default:
    just -l kube

[doc('Run all offline Kubernetes and Flux contract checks')]
validate:
    "{{ source_directory() }}/tests/validate.sh"

[arg('root', pattern='flux-repositories|infrastructure-controllers|infrastructure-configs|cluster-apps')]
[doc('Render one exclusive Flux reconciliation root')]
render-root root:
    kustomize build --load-restrictor LoadRestrictionsNone "{{ source_directory() }}/flux/{{ root }}"

[doc('Show redacted Flux source, root, and controller readiness')]
status:
    "{{ source_directory() }}/scripts/operator.sh" status

[doc('Prune pods in Failed, Pending, or Succeeded state')]
prune-pods:
    for phase in Failed Pending Succeeded; do
        kubectl delete pods -A --field-selector status.phase="$phase" \
            --ignore-not-found=true
    done


[doc('Activate and verify the repository source root')]
activate-repositories:
    "{{ source_directory() }}/scripts/operator.sh" activate flux-repositories

[doc('Activate controllers after repositories are Ready')]
activate-controllers:
    "{{ source_directory() }}/scripts/operator.sh" activate infrastructure-controllers

[doc('Activate platform configuration after controllers are Ready')]
activate-configs:
    "{{ source_directory() }}/scripts/operator.sh" activate infrastructure-configs

[doc('Activate applications after platform configuration is Ready')]
activate-apps:
    "{{ source_directory() }}/scripts/operator.sh" activate cluster-apps

[arg('kind', pattern='ks|hr')]
[doc('Suspend one exact Flux-owned Kustomization or HelmRelease')]
suspend kind namespace name:
    "{{ source_directory() }}/scripts/operator.sh" suspend "{{ kind }}" "{{ namespace }}" "{{ name }}"

[arg('kind', pattern='ks|hr')]
[doc('Resume one exact Flux-owned Kustomization or HelmRelease')]
resume kind namespace name:
    "{{ source_directory() }}/scripts/operator.sh" resume "{{ kind }}" "{{ namespace }}" "{{ name }}"

[doc('Inventory retired namespace storage without reading Secret data')]
inventory-retired-data:
    "{{ source_directory() }}/scripts/operator.sh" inventory-retired-data

[confirm('Retire the live media namespace after exact PVC disposition and backup checks? [y|N]')]
[doc('Retire media only after every live PVC is explicitly dispositioned')]
retire-media:
    "{{ source_directory() }}/scripts/retire-media.sh"

[arg('fixed_id', pattern='cilium|coredns|flux-operator|flux-instance')]
[confirm('Retire this exact prune-protected control-plane resource? [y|N]')]
[doc('Retire one fixed allowlisted prune-protected resource')]
retire-protected fixed_id:
    "{{ source_directory() }}/scripts/retire-protected.sh" "{{ fixed_id }}"

[private]
validate-cilium-bgp:
    "{{ source_directory() }}/tests/cilium-bgp/validate.sh"

[doc('Run fixed live Cilium datapath, routing, and reviewed external acceptance')]
accept-cilium:
    "{{ source_directory() }}/scripts/accept-cilium.sh"

[doc('Show per-node Cilium host endpoint audit mode')]
audit-host-firewall:
    "{{ source_directory() }}/scripts/host-firewall.sh" audit

[arg('node', pattern='bsd-k8s-0[1-5]')]
[confirm('Drain, reboot, and enforce the Cilium host firewall on ' + node + '? [y|N]')]
[doc('Enforce one fixed node after Hubble, quorum, and break-glass proof')]
enforce-host-firewall-node node:
    "{{ source_directory() }}/scripts/host-firewall.sh" enforce "{{ node }}"

[doc('Run live Ceph, LocalPV, CSI, and reviewed recovery acceptance')]
accept-storage:
    "{{ source_directory() }}/scripts/accept-storage.sh"

[doc('Run live HAProxy-to-Envoy edge and policy acceptance')]
accept-edge:
    "{{ source_directory() }}/scripts/accept-edge.sh"

[doc('Run live RFC 2136 ownership and PowerDNS reconciliation acceptance')]
accept-powerdns:
    "{{ source_directory() }}/scripts/accept-powerdns.sh"

[doc('Run live Dragonfly TLS, ACL, failover, snapshot, and backup acceptance')]
accept-dragonfly:
    "{{ source_directory() }}/scripts/accept-dragonfly.sh"

[arg('source', pattern='librefs|r2')]
[doc('Restore PostgreSQL into an isolated drill cluster')]
drill-cnpg-restore source:
    "{{ source_directory() }}/scripts/drill-cnpg-restore.sh" "{{ source }}"

[arg('action', pattern='inject|cleanup')]
[confirm('Perform the one-time Keycloak bootstrap ' + action + ' transition? [y|N]')]
[doc('Inject or remove the one-time Keycloak bootstrap administrator')]
bootstrap-keycloak action:
    "{{ source_directory() }}/../scripts/with-openbao-runtime.sh" "{{ source_directory() }}/scripts/bootstrap-keycloak.sh" "{{ action }}"

[doc('Run live Keycloak, proxy, OpenTofu, and bootstrap-removal acceptance')]
accept-identity:
    "{{ source_directory() }}/scripts/accept-identity.sh"

[confirm('Inject observability canaries and simulate a brief VictoriaLogs outage? [y|N]')]
[doc('Run live metrics, logs, alert, isolation, and buffer acceptance')]
accept-observability:
    "{{ source_directory() }}/scripts/accept-observability.sh"

[confirm('Provision new AI credentials and Codex OAuth state in OpenBao? [y|N]')]
[doc('Provision first-use AI secrets through the protected OpenBao runtime')]
provision-ai-secrets:
    "{{ source_directory() }}/../scripts/with-openbao-runtime.sh" "{{ source_directory() }}/../scripts/provision-ai-secrets.sh"

[confirm('Create or update exact LiteLLM virtual-key quotas? [y|N]')]
[doc('Configure LiteLLM Memini and Forgejo quota contracts')]
configure-litellm:
    "{{ source_directory() }}/../scripts/with-openbao-runtime.sh" "{{ source_directory() }}/scripts/configure-litellm.sh"

[arg('action', pattern='issue-csr|revoke|sync|health|upgrade|rollback|uninstall')]
[doc('Operate the fixed LLMKube Mac identity and lifecycle helper')]
llmkube-mac action *args:
    "{{ source_directory() }}/scripts/llmkube-mac.sh" "{{ action }}" {{ args }}

[confirm('Reboot the Mac and run disruptive AI fail-closed acceptance? [y|N]')]
[doc('Run live Metal, Memini, LiteLLM, Codex, and telemetry acceptance')]
accept-ai:
    "{{ source_directory() }}/../scripts/with-openbao-runtime.sh" "{{ source_directory() }}/scripts/accept-ai.sh"

[doc('Run the non-upgrading live gate for the suspended Kubernetes upgrade target')]
accept-upgrade-preflight:
    "{{ source_directory() }}/scripts/accept-upgrade-preflight.sh"

[confirm('Resume the Kubernetes target in its separate attended Sunday window? [y|N]')]
[doc('Lease exact silences and attend the one-minor Kubernetes upgrade')]
attend-kubernetes-upgrade:
    "{{ source_directory() }}/scripts/attend-upgrade.sh" kubernetes
