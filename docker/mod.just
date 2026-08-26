set default-script
set no-exit-message
set quiet
set script-interpreter := ['bash', '-euo', 'pipefail']
set shell := ['bash', '-euo', 'pipefail', '-c']

[private]
default:
    just -l docker

[doc('Validate the c0 host-scoped Doco-CD configuration')]
validate-c0: validate-openbao validate-powerdns validate-blocky validate-omada-controller
    cd "{{ source_directory() }}/.."
    yamllint .sops.yaml docker/c0/.doco-cd.yaml docker/c0/.doco-cd/docker-compose.app.yaml docker/c0/.doco-cd/poll-config.yml
    yq -e '.working_dir == "./docker/c0" and .auto_discovery.enabled == true and .auto_discovery.depth == 1 and .auto_discovery.delete == false and .force_recreate == false and .reconciliation.enabled == false' docker/c0/.doco-cd.yaml >/dev/null
    yq -e 'length == 1 and .[0].url == "https://github.com/trosvald/infrastructure.git" and .[0].reference == "refs/heads/main" and .[0].interval == "180s" and .[0].watch == false and (.[0] | has("target") | not)' docker/c0/.doco-cd/poll-config.yml >/dev/null
    yq -e '.services.doco-cd.image == "ghcr.io/kimdre/doco-cd:0.111.0@sha256:8c31f63f6bde1b67f0802619bad0599bf5e41503f5532be9cc58d0f063b1eeea" and .services.doco-cd.environment.DEPLOY_CONFIG_BASE_DIR == "./docker/c0/" and .services.doco-cd.environment.POLL_CONFIG_FILE == "/etc/doco-cd/poll-config.yml"' docker/c0/.doco-cd/docker-compose.app.yaml >/dev/null
    DOCO_CD_API_SECRET_FILE=/dev/null DOCO_CD_SOPS_AGE_KEY_FILE=/dev/null docker compose -f docker/c0/.doco-cd/docker-compose.app.yaml config --quiet
    python3 - <<'PY'
    from pathlib import Path

    recognized = {"compose.yaml", "compose.yml", "docker-compose.yml", "docker-compose.yaml"}
    for boundary in (Path("docker/c0/.doco-cd"), Path("docker/c0/.host")):
        offenders = sorted(path for path in boundary.rglob("*") if path.name in recognized)
        assert not offenders, f"Doco-CD can auto-discover forbidden files: {offenders}"
    PY

[doc('Validate the c1 host-scoped Doco-CD and libreFS configuration')]
validate-c1:
    cd "{{ source_directory() }}/.."
    docker/c1/tests/validate.sh

[private]
validate-openbao:
    cd "{{ source_directory() }}/.."
    yamllint .sops.yaml docker/c0/openbao/.doco-cd.yaml docker/c0/openbao/compose.yml
    test "$(sops filestatus docker/c0/openbao/encrypted/acme.env | jq -r '.encrypted')" = true
    test "$(sops filestatus docker/c0/openbao/encrypted/cloudflare.ini | jq -r '.encrypted')" = true
    python3 - <<'PY'
    from pathlib import Path

    dotenv = Path("docker/c0/openbao/encrypted/acme.env").read_text()
    ini = Path("docker/c0/openbao/encrypted/cloudflare.ini").read_text()
    assert dotenv.startswith("ACME_EMAIL=ENC[AES256_GCM,")
    assert "sops_age__list_0__map_enc=-----BEGIN AGE ENCRYPTED FILE-----" in dotenv
    assert "sops_mac=ENC[AES256_GCM," in dotenv
    assert ini.startswith("dns_cloudflare_api_token = ENC[AES256_GCM,")
    assert "\n[sops]\n" in ini
    assert "age__list_0__map_enc       = -----BEGIN AGE ENCRYPTED FILE-----" in ini
    assert "\nmac                        = ENC[AES256_GCM," in ini
    PY
    docker run --rm --platform linux/amd64 --entrypoint python3 \
        --mount type=bind,src="$PWD/docker/c0/openbao",dst=/src,readonly \
        --tmpfs /tmp:mode=1777 \
        certbot/dns-cloudflare:v5.7.0@sha256:ed5e95feb4d64690df77b4628876f3b72ae856d6e0acd51927a2fd45baf1ccd2 \
        -m unittest discover -s /src/tests -v
    rendered="$(mktemp)"
    trap 'rm -f "$rendered"' EXIT
    docker compose -f docker/c0/openbao/compose.yml config --format json >"$rendered"
    jq -e '
        all(.services[]; ((.ports // []) | length) == 0)
        and .services.openbao.networks.c0_services.ipv4_address == "10.25.13.34"
        and ([.services | to_entries[] | select(.value.networks.c0_services? != null) | .key] == ["openbao"])
        and .services["certificate-init"].secrets[0].target == "cloudflare.ini"
        and .services["certificate-renewer"].secrets[0].target == "cloudflare.ini"
        and .services["certificate-renewer"].pid == "service:openbao"
        and .volumes["openbao-data"].name == "openbao-data"
        and .volumes["openbao-acme"].name == "openbao-acme"
        and .volumes["openbao-tls"].name == "openbao-tls"
        and all(.services[]; all((.volumes // [])[]; .source != "/var/run/docker.sock"))
    ' "$rendered" >/dev/null

[private]
validate-powerdns:
    cd "{{ source_directory() }}/.."
    yamllint docker/c0/powerdns/.doco-cd.yaml docker/c0/powerdns/compose.yml
    yq -e '.name == "powerdns-c0" and has("force_recreate") == false' docker/c0/powerdns/.doco-cd.yaml >/dev/null
    docker/c0/powerdns/tests/validate.sh
    rendered="$(mktemp)"
    trap 'rm -f "$rendered"' EXIT
    docker compose -f docker/c0/powerdns/compose.yml config --format json >"$rendered"
    jq -e '
        (.services | keys | sort) == ["data-init", "powerdns", "zone-reconcile"]
        and all(.services[]; ((.ports // []) | length) == 0)
        and .services.powerdns.networks.c0_services.ipv4_address == "10.25.13.33"
        and ([.services | to_entries[] | select(.value.networks.c0_services? != null) | .key] == ["powerdns"])
        and .services["data-init"].network_mode == "none"
        and .services["zone-reconcile"].network_mode == "none"
        and any(.services["zone-reconcile"].volumes[]; .target == "/zones" and .type == "bind" and .read_only == true)
        and any(.services["zone-reconcile"].volumes[]; .target == "/usr/local/bin/reconcile.sh" and .type == "bind" and .read_only == true)
        and any(.services.powerdns.volumes[]; .target == "/deployment/zones" and .type == "bind" and .read_only == true)
        and any(.services.powerdns.volumes[]; .target == "/deployment/reconcile.sh" and .type == "bind" and .read_only == true)
        and all(.services[]; all((.volumes // [])[]; (.type != "volume") or .volume.nocopy == true))
        and .volumes["powerdns-data"].name == "powerdns-data"
        and .services.powerdns.cap_drop == ["ALL"]
        and .services.powerdns.cap_add == ["NET_BIND_SERVICE"]
        and .services.powerdns.user == null
        and (.services.powerdns.command | index("--api=no")) != null
        and (.services.powerdns.command | index("--webserver=no")) != null
        and all(.services[]; (.environment // {}) == {})
        and all(.services[]; (.secrets // []) == [])
        and all(.services[]; all((.volumes // [])[]; .source != "/var/run/docker.sock"))
        and all(.services[]; all((.volumes // [])[]; (.source | contains("openbao")) | not))
    ' "$rendered" >/dev/null

[private]
validate-blocky:
    cd "{{ source_directory() }}/.."
    yamllint docker/c0/blocky/.doco-cd.yaml docker/c0/blocky/compose.yml docker/c0/blocky/config.yml
    bash -n docker/c0/blocky/tests/validate.sh
    yq -e '.name == "blocky-c0" and has("force_recreate") == false' docker/c0/blocky/.doco-cd.yaml >/dev/null
    yq -e '
        length == 11
        and has("blocking")
        and has("caching")
        and has("conditional")
        and has("connectIPVersion")
        and has("dnssec")
        and has("log")
        and has("ports")
        and has("prometheus")
        and has("queryLog")
        and has("statistics")
        and has("upstreams")
        and .upstreams.init.strategy == "blocking"
        and (.upstreams.groups.default | length) == 2
        and .upstreams.groups.default[0] == "https://1.1.1.1/dns-query#cloudflare-dns.com"
        and .upstreams.groups.default[1] == "https://9.9.9.9/dns-query#dns.quad9.net"
        and .upstreams.strategy == "random"
        and .upstreams.timeout == "3s"
        and .connectIPVersion == "v4"
        and .conditional.fallbackUpstream == false
        and (.conditional.mapping | length) == 5
        and .conditional.mapping."monosense.io" == "10.25.13.33"
        and .conditional.mapping."10.25.10.in-addr.arpa" == "10.25.13.33"
        and .conditional.mapping."11.25.10.in-addr.arpa" == "10.25.13.33"
        and .conditional.mapping."12.25.10.in-addr.arpa" == "10.25.13.33"
        and .conditional.mapping."13.25.10.in-addr.arpa" == "10.25.13.33"
        and (.blocking.denylists.default | length) == 1
        and .blocking.denylists.default[0] == "https://raw.githubusercontent.com/hagezi/dns-blocklists/a3d0c5c7a0402f669f3f1392527b8a50622128cf/wildcard/multi.txt"
        and (.blocking.allowlists.default | length) == 1
        and (.blocking.allowlists.default[0] | contains("monosense.io\n*.monosense.io\n"))
        and (.blocking.allowlists.default[0] | contains("10.25.10.in-addr.arpa\n*.10.25.10.in-addr.arpa\n"))
        and (.blocking.allowlists.default[0] | contains("11.25.10.in-addr.arpa\n*.11.25.10.in-addr.arpa\n"))
        and (.blocking.allowlists.default[0] | contains("12.25.10.in-addr.arpa\n*.12.25.10.in-addr.arpa\n"))
        and (.blocking.allowlists.default[0] | contains("13.25.10.in-addr.arpa\n*.13.25.10.in-addr.arpa\n"))
        and (.blocking.clientGroupsBlock.default | length) == 1
        and .blocking.clientGroupsBlock.default[0] == "default"
        and .blocking.blockType == "nxDomain"
        and .blocking.blockTTL == "5m"
        and .blocking.loading.strategy == "fast"
        and .blocking.loading.refreshPeriod == "12h"
        and (.blocking.loading.downloads | length) == 3
        and .blocking.loading.downloads.timeout == "10s"
        and .blocking.loading.downloads.attempts == 3
        and .blocking.loading.downloads.cooldown == "1s"
        and (.caching | length) == 5
        and .caching.minTime == "0s"
        and .caching.maxTime == "0s"
        and .caching.cacheTimeNegative == "5m"
        and .caching.maxItemsCount == 10000
        and .caching.prefetching == false
        and (.queryLog | length) == 1
        and .queryLog.type == "none"
        and (.ports | length) == 4
        and (.ports.dns | length) == 1
        and .ports.dns[0] == ":53"
        and (.ports.http | length) == 0
        and (.ports.https | length) == 0
        and (.ports.tls | length) == 0
        and (.dnssec | length) == 1
        and .dnssec.validate == false
        and (.prometheus | length) == 1
        and .prometheus.enable == false
        and (.statistics | length) == 1
        and .statistics.enable == false
        and (.log | length) == 3
        and .log.level == "info"
        and .log.format == "json"
        and .log.privacy == true
    ' docker/c0/blocky/config.yml >/dev/null
    docker/c0/blocky/tests/validate.sh
    rendered="$(mktemp)"
    trap 'rm -f "$rendered"' EXIT
    docker compose -f docker/c0/blocky/compose.yml config --format json >"$rendered"
    jq -e '
        .name == "blocky-c0"
        and (.services | keys) == ["blocky"]
        and .services.blocky.image == "docker.io/spx01/blocky:v0.34.0@sha256:595136fb127f4c952b621113e668c09acdcf15ac054d96ee6d4c51a76c35f5fd"
        and .services.blocky.platform == "linux/amd64"
        and .services.blocky.user == "100:100"
        and .services.blocky.read_only == true
        and .services.blocky.privileged != true
        and .services.blocky.cap_drop == ["ALL"]
        and ((.services.blocky.cap_add // []) | length) == 0
        and .services.blocky.security_opt == ["no-new-privileges:true"]
        and .services.blocky.sysctls == {"net.ipv4.ip_unprivileged_port_start": "53"}
        and ((.services.blocky.mem_swappiness // 0) == 0)
        and .services.blocky.restart == "unless-stopped"
        and .services.blocky.stop_grace_period == "15s"
        and .services.blocky.cpus == 0.5
        and (.services.blocky.mem_limit | tonumber) == 268435456
        and (.services.blocky.memswap_limit | tonumber) == 268435456
        and .services.blocky.ulimits.nofile == {"soft": 4096, "hard": 8192}
        and ((.services.blocky.ports // []) | length) == 0
        and ((.services.blocky.expose // []) | length) == 0
        and ((.services.blocky.environment // {}) | length) == 0
        and ((.services.blocky.secrets // []) | length) == 0
        and ((.services.blocky.configs // []) | length) == 0
        and ((.services.blocky.tmpfs // []) | length) == 0
        and (.services.blocky.volumes | length) == 1
        and .services.blocky.volumes[0].type == "bind"
        and (.services.blocky.volumes[0].source | endswith("/docker/c0/blocky/config.yml"))
        and .services.blocky.volumes[0].target == "/app/config.yml"
        and .services.blocky.volumes[0].read_only == true
        and (.services.blocky.networks | keys) == ["c0_services"]
        and .services.blocky.networks.c0_services.ipv4_address == "10.25.13.35"
        and .services.blocky.healthcheck.test == ["CMD", "/app/blocky", "healthcheck"]
        and .services.blocky.healthcheck.start_period == "1m0s"
        and .services.blocky.healthcheck.start_interval == "2s"
        and .services.blocky.healthcheck.interval == "30s"
        and .services.blocky.healthcheck.timeout == "3s"
        and .services.blocky.healthcheck.retries == 3
        and .services.blocky.logging.driver == "json-file"
        and .services.blocky.logging.options == {"max-file": "3", "max-size": "10m"}
        and (.networks | keys) == ["c0_services"]
        and .networks.c0_services.name == "c0_services"
        and .networks.c0_services.external == true
        and ((.volumes // {}) | length) == 0
        and all(.services[]; all((.volumes // [])[]; .source != "/var/run/docker.sock"))
        and all(.services[]; all((.volumes // [])[]; (.source | contains("openbao")) | not))
    ' "$rendered" >/dev/null

[private]
validate-omada-controller:
    cd "{{ source_directory() }}/.."
    yamllint docker/c0/omada-controller/.doco-cd.yaml docker/c0/omada-controller/compose.yml
    yq -e '.name == "omada-controller-c0" and has("force_recreate") == false' docker/c0/omada-controller/.doco-cd.yaml >/dev/null
    yq -e '.name == "omada-controller-c0" and .services["omada-controller"].mem_swappiness == 0' docker/c0/omada-controller/compose.yml >/dev/null
    bash -n docker/c0/.host/networks/omada-mgmt/ensure.sh docker/c0/.host/networks/omada-mgmt/tests/ensure.sh
    docker/c0/.host/networks/omada-mgmt/tests/ensure.sh
    rendered="$(mktemp)"
    trap 'rm -f "$rendered"' EXIT
    docker compose -f docker/c0/omada-controller/compose.yml config --format json >"$rendered"
    jq -e '
        .name == "omada-controller-c0"
        and (.services | keys | sort) == ["omada-controller", "volume-init"]
        and all(.services[]; .image == "docker.io/mbentley/omada-controller:6.2.14.11@sha256:157f0e730e6ce4211ab5df533af656495c9803791356ced7fcec28b3caca03ad")
        and all(.services[]; .platform == "linux/amd64")
        and all(.services[]; ((.ports // []) | length) == 0)
        and all(.services[]; ((.secrets // []) | length) == 0)
        and all(.services[]; ((.configs // []) | length) == 0)
        and all(.services[]; .privileged != true)
        and all(.services[]; all((.volumes // [])[]; .type == "volume" and .source != "/var/run/docker.sock" and .volume.nocopy == true))
        and .services["volume-init"].user == "0:0"
        and .services["volume-init"].network_mode == "none"
        and .services["volume-init"].entrypoint == ["/bin/sh", "-c"]
        and .services["volume-init"].command == ["chown 508:508 /opt/tplink/EAPController/data /opt/tplink/EAPController/logs"]
        and .services["volume-init"].cap_drop == ["ALL"]
        and .services["volume-init"].cap_add == ["CHOWN"]
        and .services["volume-init"].security_opt == ["no-new-privileges:true"]
        and (.services["volume-init"].restart // "") == ""
        and ((.services["volume-init"].networks // {}) | length) == 0
        and (.services["volume-init"].volumes | length) == 2
        and ([.services["volume-init"].volumes[].source] | sort) == ["omada-controller-data", "omada-controller-logs"]
        and (.services["volume-init"].environment // {}) == {}
        and any(.services["volume-init"].volumes[]; .source == "omada-controller-data" and .target == "/opt/tplink/EAPController/data")
        and any(.services["volume-init"].volumes[]; .source == "omada-controller-logs" and .target == "/opt/tplink/EAPController/logs")
        and .services["omada-controller"].user == "508:508"
        and .services["omada-controller"].cap_drop == ["ALL"]
        and (.services["omada-controller"].cap_add // []) == []
        and .services["omada-controller"].security_opt == ["no-new-privileges:true"]
        and .services["omada-controller"].restart == "unless-stopped"
        and .services["omada-controller"].stop_grace_period == "1m0s"
        and .services["omada-controller"].depends_on["volume-init"].condition == "service_completed_successfully"
        and .services["omada-controller"].environment == {
            "MANAGE_HTTP_PORT": "8088",
            "MANAGE_HTTPS_PORT": "8043",
            "PORTAL_HTTP_PORT": "8088",
            "PORTAL_HTTPS_PORT": "8843",
            "PORT_ADOPT_V1": "29812",
            "PORT_APP_DISCOVERY": "27001",
            "PORT_DEVICE_MONITOR": "29817",
            "PORT_DISCOVERY": "29810",
            "PORT_MANAGER_V1": "29811",
            "PORT_MANAGER_V2": "29814",
            "PORT_RTTY": "29816",
            "PORT_TRANSFER_V2": "29815",
            "PORT_UPGRADE_V1": "29813",
            "ROOTLESS": "true",
            "TZ": "Asia/Jakarta",
            "UPGRADE_HTTPS_PORT": "8043",
            "WEB_CONFIG_OVERRIDE": "false"
        }
        and .services["omada-controller"].healthcheck.test == ["CMD", "/healthcheck.sh"]
        and .services["omada-controller"].healthcheck.start_period == "5m0s"
        and .services["omada-controller"].healthcheck.interval == "30s"
        and .services["omada-controller"].healthcheck.timeout == "5s"
        and .services["omada-controller"].healthcheck.retries == 3
        and .services["omada-controller"].cpus == 2
        and (.services["omada-controller"].mem_limit | tonumber) == 4294967296
        and (.services["omada-controller"].memswap_limit | tonumber) == 5368709120
        and ((.services["omada-controller"].mem_swappiness // 0) == 0)
        and .services["omada-controller"].ulimits.nofile.soft == 4096
        and .services["omada-controller"].ulimits.nofile.hard == 8192
        and .services["omada-controller"].logging.driver == "json-file"
        and .services["omada-controller"].logging.options == {"max-file": "3", "max-size": "10m"}
        and (.services["omada-controller"].volumes | length) == 2
        and ([.services["omada-controller"].volumes[].source] | sort) == ["omada-controller-data", "omada-controller-logs"]
        and any(.services["omada-controller"].volumes[]; .source == "omada-controller-data" and .target == "/opt/tplink/EAPController/data")
        and any(.services["omada-controller"].volumes[]; .source == "omada-controller-logs" and .target == "/opt/tplink/EAPController/logs")
        and (.services["omada-controller"].networks | keys) == ["c0_omada_mgmt"]
        and .services["omada-controller"].networks.c0_omada_mgmt.ipv4_address == "10.25.10.26"
        and ([.services | to_entries[] | select(.value.networks.c0_omada_mgmt? != null) | .key] == ["omada-controller"])
        and (.networks | keys) == ["c0_omada_mgmt"]
        and .networks.c0_omada_mgmt.name == "c0_omada_mgmt"
        and .networks.c0_omada_mgmt.external == true
        and (.networks.c0_services? == null)
        and (.volumes | keys | sort) == ["omada-controller-data", "omada-controller-logs"]
        and .volumes["omada-controller-data"].name == "omada-controller-data"
        and .volumes["omada-controller-logs"].name == "omada-controller-logs"
    ' "$rendered" >/dev/null
