#!/bin/sh
set -eu

mode="${1:-}"
case "$mode" in
    renew | dry-run) ;;
    *)
        printf '%s\n' 'usage: renew_certificate.sh renew|dry-run' >&2
        exit 2
        ;;
esac

lock=/run/certbot/renew.lock
while ! mkdir "$lock" 2>/dev/null; do
    sleep 1 &
    wait "$!"
done
cleanup() {
    rmdir "$lock" 2>/dev/null || true
}
trap cleanup EXIT HUP INT TERM

if [ "$mode" = dry-run ]; then
    certbot renew \
        --dry-run \
        --non-interactive \
        --no-random-sleep-on-renew
else
    certbot renew \
        --non-interactive \
        --no-random-sleep-on-renew \
        --deploy-hook 'python3 /usr/local/bin/install_certificate.py install --lineage /etc/letsencrypt/live/vault.monosense.io --target /openbao/tls --hostname vault.monosense.io --reload-pid 1'
fi
