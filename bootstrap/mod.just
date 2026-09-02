set default-list
set default-script
set no-exit-message
set quiet
set script-interpreter := ['bash', '-euo', 'pipefail']
set shell := ['bash', '-euo', 'pipefail', '-c']

[private]
default:
    just -l bootstrap

[confirm('Bootstrap the protected five-node Talos/Cilium/Flux cluster? [y|N]')]
[doc('Run the bounded resumable cluster bootstrap')]
cluster:
    "{{ source_directory() }}/scripts/cluster.sh" all

[doc('Run read-only cluster, network, source, and inventory preflight')]
preflight:
    "{{ source_directory() }}/scripts/cluster.sh" preflight

[confirm('Apply the reviewed Talos, Kubernetes, Cilium, BGP, and CoreDNS boundary? [y|N]')]
[doc('Build the bounded cluster network through CoreDNS')]
network:
    "{{ source_directory() }}/scripts/cluster.sh" network

[confirm('Install the pinned Flux Operator and raw public-source FluxInstance? [y|N]')]
[doc('Install Flux and start the suspended four-root handoff')]
flux:
    "{{ source_directory() }}/scripts/cluster.sh" flux

[confirm('Run bootstrap acceptance including bounded BGP withdrawal tests? [y|N]')]
[doc('Verify five nodes, networking, Flux, public source, and suspended roots')]
verify:
    "{{ source_directory() }}/scripts/cluster.sh" verify

[doc('Validate bounded bootstrap and render contracts offline')]
validate: test
    just kube validate-cilium-bgp
    helmfile -f "{{ source_directory() }}/helmfile/apps.yaml" template -q >/dev/null
    cmp "{{ source_directory() }}/flux/fluxinstance.yaml" "{{ source_directory() }}/../kubernetes/apps/flux-system/flux-instance/app/fluxinstance.yaml"
    kustomize build "{{ source_directory() }}/../kubernetes/apps/flux-system/flux-instance/app" >/dev/null

[private]
test:
    "{{ source_directory() }}/tests/test.sh"
