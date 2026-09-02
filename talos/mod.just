set default-list
set default-script
set quiet
set script-interpreter := ['bash', '-euo', 'pipefail']
set shell := ['bash', '-euo', 'pipefail', '-c']

[private]
default:
    just -l talos


[confirm('Apply protected Talos config to ' + node + ' [y|N] ?')]
[doc('Render, preflight, apply if needed, reboot, and verify one Talos node')]
apply-node node:
    "{{ source_directory() }}/scripts/render.sh" apply-node "{{ node }}"

[doc('Render and validate one protected Talos node; print redacted metadata only')]
render-config node:
    "{{ source_directory() }}/scripts/render.sh" render "{{ node }}"

[doc('Verify one installed protected Talos node; print redacted status only')]
verify-node node:
    "{{ source_directory() }}/scripts/render.sh" verify-node "{{ node }}"

[doc('Validate protected hardware inventory; print one topology digest')]
validate-inventory:
    "{{ source_directory() }}/scripts/validate_inventory.sh"

[doc('Inventory exactly one stable approximately-1-TB OSD identity per node')]
inventory-storage:
    "{{ source_directory() }}/scripts/inventory_storage.py"

[doc('Prove reviewed VLAN 2514 switch inventory and five-node tagged L2 reachability')]
validate-storage-network:
    "{{ source_directory() }}/scripts/validate_storage_network.py"

[arg('node', pattern='bsd-k8s-0[1-5]')]
[doc('Capture one pre-storage Talos rollback config after switch inventory review')]
backup-storage-network-node node:
    "{{ source_directory() }}/scripts/render.sh" backup-storage-network "{{ node }}"

[arg('node', pattern='bsd-k8s-0[1-5]')]
[confirm('Apply VLAN 2514 to ' + node + ' after reviewed rollback and switch gates? [y|N]')]
[doc('Apply VLAN 2514 to one fixed node and restore on failed health')]
apply-storage-network-node node:
    "{{ source_directory() }}/scripts/render.sh" apply-storage-network "{{ node }}"

[doc('Render and validate every synthetic Talos inventory node twice')]
test:
    "{{ source_directory() }}/tests/test.sh"
[doc('Generate the reviewed Talos factory schematic ID')]
schematic-id:
    curl -fsS --retry 5 --retry-delay 2 --retry-all-errors \
        --request POST \
        --data-binary @"{{ source_directory() }}/schematic.yaml.j2" \
        https://factory.talos.dev/schematics | jq -er '.id'


[confirm('Reboot node ' + node + ' [y|N] ?')]
[doc('Reboot a node')]
reboot-node node *args:
    talosctl -n "{{ node }}" reboot --wait=false {{ args }}

[confirm('Reset node ' + node + ' [y|N] ?')]
[doc('Reset a node')]
reset-node node *args:
    talosctl -n "{{ node }}" reset --reboot=true --graceful=false {{ args }}

[confirm('Shutdown node ' + node + ' [y|N] ?')]
[doc('Shutdown a node')]
shutdown-node node *args:
    talosctl -n "{{ node }}" shutdown --force {{ args }}

[confirm('Upgrade Kubernetes to ' + version + ' [y|N] ?')]
[doc('Upgrade Kubernetes version on the cluster')]
upgrade-k8s version:
    talosctl -n "$(talosctl config info -o yaml | yq -r -e '.endpoints[0]')" upgrade-k8s --to "{{ version }}"

[confirm('Upgrade node ' + node + ' [y|N] ?')]
[doc('Upgrade a node with its currently configured installer image')]
upgrade-node node *args:
    image="$(talosctl get machineconfig v1alpha1 -n "{{ node }}" -o jsonpath='{.spec.machine.install.image}')"
    talosctl -n "{{ node }}" upgrade -i "$image" -m powercycle --timeout=10m {{ args }}
