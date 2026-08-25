set default-script
set no-exit-message
set quiet
set script-interpreter := ['bash', '-euo', 'pipefail']
set shell := ['bash', '-euo', 'pipefail', '-c']

[private]
default:
    just -l docker

[doc('Validate the c0 Doco-CD bootstrap configuration')]
validate-c0: validate-openbao validate-powerdns
    cd "{{ source_directory() }}/.."
    yamllint .doco-cd.c0.yml .sops.yaml docker/bootstrap/c0/doco-cd/compose.yml docker/bootstrap/c0/doco-cd/poll-config.yml
    DOCO_CD_API_SECRET_FILE=/dev/null DOCO_CD_SOPS_AGE_KEY_FILE=/dev/null docker compose -f docker/bootstrap/c0/doco-cd/compose.yml config --quiet

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
    yq -e '.name == "powerdns-c0" and .force_recreate == true' docker/c0/powerdns/.doco-cd.yaml >/dev/null
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
