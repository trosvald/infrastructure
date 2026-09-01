#!/usr/bin/env bash
set -euo pipefail
readonly HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SHARED="$HERE/../../../scripts"
[[ "$(id -u)" == 0 ]] || { printf '%s\n' 'wildcard asset installation requires root' >&2; exit 1; }
install -d -o root -g root -m 0755 /usr/local/libexec /usr/local/sbin /usr/local/share/monosense-monitoring /etc/systemd/system \
    /opt/monitoring/secrets /var/lib/monosense-monitoring/tls
install -d -o root -g root -m 0700 /var/lib/monosense-monitoring/vector-tls
install -o root -g root -m 0755 "$SHARED/install_certificate.py" /usr/local/libexec/install-certificate.py
install -o root -g root -m 0755 "$SHARED/fetch_wildcard_certificate.py" /usr/local/libexec/fetch-wildcard-certificate.py
install -o root -g root -m 0755 "$HERE/update-wildcard-certificate.sh" /usr/local/sbin/update-c0-wildcard-certificate
install -o root -g root -m 0755 "$HERE/materialize-monitoring-secrets.sh" /usr/local/sbin/materialize-c0-monitoring-secrets
install -o root -g root -m 0644 "$HERE/../../monitoring/config/gatus.yaml.template" /usr/local/share/monosense-monitoring/gatus.yaml.template
install -o root -g root -m 0644 "$HERE/../../monitoring/config/vector.yaml.template" /usr/local/share/monosense-monitoring/vector.yaml.template
install -o root -g root -m 0644 "$HERE/c0-wildcard-certificate.service" /etc/systemd/system/c0-wildcard-certificate.service
install -o root -g root -m 0644 "$HERE/c0-wildcard-certificate.timer" /etc/systemd/system/c0-wildcard-certificate.timer
systemctl daemon-reload
systemctl enable c0-wildcard-certificate.timer
printf '%s\n' 'c0 wildcard assets installed; reader token and first service run remain explicit'
