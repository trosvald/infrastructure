set dotenv-load := false
set positional-arguments
set quiet
set shell := ['bash', '-euo', 'pipefail', '-c']

namespace := source_directory()

[private]
default:
    just --list ansible

[arg('action', pattern='bootstrap|lint|test|render|check|diff|pki-bootstrap|deploy|confirm-pending|operational-verify|myrep-preflight|precutover-baseline|syslog-verify|bgp-preflight|bgp-verify|drift|backup')]
[doc('Run an action in the isolated Junos automation project')]
junos action:
    exec "{{ namespace }}/junos/scripts/dispatch.sh" "$1"

[arg('action', pattern='bootstrap|test|lint|audit|check|diff|deploy|verify|drift|provision-storage|provision-secrets|rotate-secrets|prepare-applications|rollout-applications|recover-c0|recover-c1|recover-monitoring|forgejo-source-prepare|forgejo-source-cutover|activate-network|upgrade|reboot')]
[doc('Run a fixed action in the isolated c0/c1 container-node project')]
container-nodes action:
    exec "{{ namespace }}/container-nodes/scripts/dispatch.sh" "$1"
