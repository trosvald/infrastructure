#!/usr/bin/env bash
set -euo pipefail
readonly HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SHARED="$HERE/../../../scripts"
[[ "$(id -u)" == 0 ]] || { printf '%s\n' 'wildcard asset installation requires root' >&2; exit 1; }
install -d -o root -g root -m 0755 /usr/local/libexec /usr/local/sbin /usr/local/share/c1-app-secrets /etc/systemd/system
install -d -o root -g root -m 0700 /opt/edge/secrets /opt/forgejo/secrets
install -o root -g root -m 0755 "$SHARED/install_certificate.py" /usr/local/libexec/install-certificate.py
install -o root -g root -m 0755 "$SHARED/fetch_wildcard_certificate.py" /usr/local/libexec/fetch-wildcard-certificate.py
install -o root -g root -m 0755 "$SHARED/materialize_c1_app_secrets.py" /usr/local/sbin/materialize-c1-app-secrets
install -o root -g root -m 0644 "$HERE/../../edge/config/spoa.yaml.template" /usr/local/share/c1-app-secrets/spoa.yaml
install -o root -g root -m 0644 "$HERE/../../edge/config/GeoIP.conf.template" /usr/local/share/c1-app-secrets/GeoIP.conf
install -o root -g root -m 0644 "$HERE/../../forgejo/config/app.ini.template" /usr/local/share/c1-app-secrets/app.ini
install -o root -g root -m 0755 "$HERE/update-wildcard-certificate.sh" /usr/local/sbin/update-c1-wildcard-certificate
install -o root -g root -m 0755 "$HERE/materialize-forgejo-backup-heartbeat.sh" /usr/local/sbin/materialize-forgejo-backup-heartbeat
install -o root -g root -m 0644 "$HERE/c1-wildcard-certificate.service" /etc/systemd/system/c1-wildcard-certificate.service
install -o root -g root -m 0644 "$HERE/c1-wildcard-certificate.timer" /etc/systemd/system/c1-wildcard-certificate.timer
systemctl daemon-reload
systemctl enable c1-wildcard-certificate.timer
printf '%s\n' 'c1 wildcard and backup heartbeat assets installed; tokens and first service run remain explicit'
