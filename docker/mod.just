set default-script
set no-exit-message
set quiet
set script-interpreter := ['bash', '-euo', 'pipefail']
set shell := ['bash', '-euo', 'pipefail', '-c']

[private]
default:
    just -l docker

[doc('Validate the c0 Doco-CD bootstrap configuration')]
validate-c0:
    cd "{{ source_directory() }}/.."
    yamllint .doco-cd.c0.yml docker/bootstrap/c0/doco-cd/compose.yml docker/bootstrap/c0/doco-cd/poll-config.yml
    DOCO_CD_API_SECRET_FILE=/dev/null docker compose -f docker/bootstrap/c0/doco-cd/compose.yml config --quiet
