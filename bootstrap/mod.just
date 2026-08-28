set default-list
set default-script
set no-exit-message
set quiet
set script-interpreter := ['bash', '-euo', 'pipefail']
set shell := ['bash', '-euo', 'pipefail', '-c']

[private]
default:
    just -l bootstrap

[confirm('Bootstrap the protected five-node Talos/Cilium cluster? [y|N]')]
[doc('Run the bounded resumable Talos and Cilium bootstrap state machine')]
cluster:
    "{{ source_directory() }}/scripts/cluster.sh" all
[doc('Validate bounded bootstrap state-machine contracts offline')]
test:
    "{{ source_directory() }}/tests/test.sh"
[doc('Validate bootstrap state, Cilium resources, and Helmfile rendering')]
validate: test
    just kube validate-cilium-bgp
    helmfile -f "{{ source_directory() }}/helmfile/crds.yaml" template -q >/dev/null
    helmfile -f "{{ source_directory() }}/helmfile/apps.yaml" template -q >/dev/null



[private]
preflight:
    "{{ source_directory() }}/scripts/cluster.sh" preflight

[private]
nodes:
    "{{ source_directory() }}/scripts/cluster.sh" nodes

[private]
kubernetes:
    "{{ source_directory() }}/scripts/cluster.sh" kubernetes

[private]
kubeconfig-node:
    "{{ source_directory() }}/scripts/cluster.sh" kubeconfig-node

[private]
cilium:
    "{{ source_directory() }}/scripts/cluster.sh" cilium

[private]
bgp:
    "{{ source_directory() }}/scripts/cluster.sh" bgp

[private]
api-vip:
    "{{ source_directory() }}/scripts/cluster.sh" api-vip

[private]
kubeconfig-cilium:
    "{{ source_directory() }}/scripts/cluster.sh" kubeconfig-cilium

[private]
verify:
    "{{ source_directory() }}/scripts/cluster.sh" verify
