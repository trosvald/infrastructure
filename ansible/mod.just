set dotenv-load := false
set positional-arguments
set quiet
set shell := ['bash', '-euo', 'pipefail', '-c']

namespace := source_directory()

[private]
default:
    just --list ansible

[arg('action', pattern='bootstrap|lint|test|render|check|diff|deploy|operational-verify|bgp-preflight|bgp-verify|drift|backup')]
[doc('Run an action in the isolated Junos automation project')]
junos action:
    exec "{{ namespace }}/junos/scripts/dispatch.sh" "$1"
