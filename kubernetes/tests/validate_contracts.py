#!/usr/bin/env python3
from __future__ import annotations

import json
import pathlib
import subprocess
import sys
from collections import Counter

ROOT = pathlib.Path(sys.argv[1]).resolve()
KUBE = ROOT / "kubernetes"
ROOT_NAMES = (
    "flux-repositories",
    "infrastructure-controllers",
    "infrastructure-configs",
    "cluster-apps",
)
PROHIBITED = (
    "onepassword",
    "op://",
    "buroa",
    "tank.internal",
    "America/Chicago",
    "k13-dev",
    "gpu.amd.com",
    "--kubelet-insecure-tls",
    "kubernetes/apps/media",
    "kubernetes/apps/actions-runner-system",
    "networking/cloudflared",
    "networking/multus",
)


def fail(message: str) -> None:
    raise SystemExit(message)


def yaml_documents(path: pathlib.Path) -> list[dict]:
    result = subprocess.run(
        ["yq", "-o=json", "-I=0", ".", str(path)],
        check=True,
        text=True,
        capture_output=True,
    )
    documents: list[dict] = []
    decoder = json.JSONDecoder()
    text = result.stdout
    offset = 0
    while offset < len(text):
        while offset < len(text) and text[offset].isspace():
            offset += 1
        if offset == len(text):
            break
        document, offset = decoder.raw_decode(text, offset)
        if isinstance(document, dict):
            documents.append(document)
    return documents


def all_yaml() -> list[pathlib.Path]:
    return sorted((*KUBE.rglob("*.yaml"), *KUBE.rglob("*.yml")))


def validate_root_boundary() -> None:
    cluster_docs = yaml_documents(KUBE / "flux/cluster/ks.yaml")
    roots = [doc for doc in cluster_docs if doc.get("kind") == "Kustomization"]
    names = [doc.get("metadata", {}).get("name") for doc in roots]
    if names != list(ROOT_NAMES):
        fail(f"root order mismatch: {names!r}")
    for index, doc in enumerate(roots):
        spec = doc.get("spec", {})
        expected_depends = [] if index == 0 else [{"name": ROOT_NAMES[index - 1], "namespace": "flux-system"}]
        if spec.get("dependsOn", []) != expected_depends:
            fail(f"root dependency mismatch for {ROOT_NAMES[index]}: {spec.get('dependsOn')!r}")
        for key, expected in (("interval", "1h"), ("prune", True), ("suspend", True)):
            if spec.get(key) != expected:
                fail(f"root {ROOT_NAMES[index]} must set {key}={expected!r}")
        if spec.get("path") != f"./kubernetes/flux/{ROOT_NAMES[index]}":
            fail(f"root path mismatch for {ROOT_NAMES[index]}")

    exclusions_file = KUBE / "tests/root-exclusions.txt"
    exclusions: set[str] = set()
    if exclusions_file.exists():
        exclusions = {
            line.split(" # ", 1)[0]
            for line in exclusions_file.read_text().splitlines()
            if line and not line.startswith("#") and " # " in line
        }
    candidates = {
        path.relative_to(ROOT).as_posix()
        for path in (KUBE / "apps").rglob("ks.yaml")
    }
    owned: list[str] = []
    for name in ROOT_NAMES[1:]:
        allowlist = KUBE / "flux" / name / "kustomization.yaml"
        doc = yaml_documents(allowlist)[0]
        for resource in doc.get("resources", []):
            resolved = (allowlist.parent / resource).resolve()
            if resolved.name == "ks.yaml" and KUBE / "apps" in resolved.parents:
                owned.append(resolved.relative_to(ROOT).as_posix())
    duplicates = sorted(path for path, count in Counter(owned).items() if count != 1)
    missing = sorted(candidates - set(owned) - exclusions)
    unknown_exclusions = sorted(exclusions - candidates)
    if duplicates or missing or unknown_exclusions:
        fail(
            "root child ownership failed: "
            f"duplicates={duplicates}, missing={missing}, unknown_exclusions={unknown_exclusions}"
        )


def validate_prohibited_values() -> None:
    scopes = (KUBE / "apps", KUBE / "flux", ROOT / "bootstrap", ROOT / "talos")
    offenders: list[str] = []
    for scope in scopes:
        if not scope.exists():
            continue
        for path in scope.rglob("*"):
            if not path.is_file() or "tests" in path.parts:
                continue
            try:
                content = path.read_text().lower()
            except UnicodeDecodeError:
                continue
            for value in PROHIBITED:
                if value.lower() in content:
                    offenders.append(f"{path.relative_to(ROOT)}: {value}")
    if offenders:
        fail("prohibited copied/rejected values remain:\n" + "\n".join(offenders))


def validate_secret_contracts(paths: list[pathlib.Path]) -> None:
    allowlist_path = KUBE / "tests/openbao-remote-allowlist.txt"
    allowed = {
        line.strip()
        for line in allowlist_path.read_text().splitlines()
        if line.strip() and not line.startswith("#")
    }
    seen: set[str] = set()
    for path in paths:
        for doc in yaml_documents(path):
            kind = doc.get("kind")
            if kind not in {"ExternalSecret", "PushSecret"}:
                continue
            spec = doc.get("spec", {})
            if kind == "ExternalSecret":
                if spec.get("refreshPolicy") != "Periodic" or spec.get("refreshInterval") != "15m":
                    fail(f"ExternalSecret refresh contract failed: {path.relative_to(ROOT)}")
                if spec.get("target", {}).get("deletionPolicy") != "Retain":
                    fail(f"ExternalSecret deletion policy failed: {path.relative_to(ROOT)}")
                for item in spec.get("data", []):
                    key = item.get("remoteRef", {}).get("key")
                    if key:
                        seen.add(key)
                for item in spec.get("dataFrom", []):
                    key = item.get("extract", {}).get("key")
                    if key:
                        seen.add(key)
            else:
                if spec.get("deletionPolicy") != "None":
                    fail(f"PushSecret deletion policy failed: {path.relative_to(ROOT)}")
                for item in spec.get("data", []):
                    key = item.get("match", {}).get("remoteRef", {}).get("remoteKey")
                    if key:
                        seen.add(key)
    unknown = sorted(seen - allowed)
    stale = sorted(allowed - seen)
    if unknown or stale:
        fail(f"OpenBao remote allowlist mismatch: unknown={unknown}, stale={stale}")


def validate_openbao_auth(paths: list[pathlib.Path]) -> None:
    expected_namespaces = [
        "flux-system",
        "kube-system",
        "networking",
        "rook-ceph",
        "kopiur-system",
        "observability",
        "database",
        "security",
        "ai",
        "system-upgrade",
    ]
    stores = [
        doc
        for path in paths
        for doc in yaml_documents(path)
        if doc.get("kind") == "ClusterSecretStore"
    ]
    if len(stores) != 1 or stores[0].get("metadata", {}).get("name") != "openbao":
        fail("exactly one OpenBao ClusterSecretStore is required")
    if stores[0].get("spec", {}).get("conditions") != [{"namespaces": expected_namespaces}]:
        fail("OpenBao ClusterSecretStore namespace allowlist is not exact")
    issuers = [
        doc
        for path in paths
        for doc in yaml_documents(path)
        if doc.get("kind") == "Issuer"
    ]
    if any(doc.get("kind") == "ClusterIssuer" for path in paths for doc in yaml_documents(path)):
        fail("ClusterIssuer is prohibited")
    expected_issuers = {
        ("networking", "openbao-envoy-edge"),
        ("networking", "openbao-envoy-internal"),
        ("networking", "openbao-mac-caddy"),
        ("networking", "openbao-vector-srx"),
        ("database", "openbao-cnpg"),
        ("database", "openbao-dragonfly"),
        ("security", "openbao-keycloak"),
        ("security", "openbao-cnpg-client"),
        ("ai", "openbao-mac-embedding"),
        ("ai", "openbao-cnpg-client"),
    }
    actual_issuers = {
        (doc.get("metadata", {}).get("namespace"), doc.get("metadata", {}).get("name"))
        for doc in issuers
    }
    if actual_issuers != expected_issuers:
        fail(f"OpenBao namespaced Issuer set mismatch: {sorted(actual_issuers)}")
    if any("acme" in doc.get("spec", {}) for doc in issuers):
        fail("ACME issuer configuration remains")


def validate_services_and_sources(paths: list[pathlib.Path]) -> None:
    approved_classes = {"infrastructure", "internal", "edge-backend"}
    for path in paths:
        for doc in yaml_documents(path):
            kind = doc.get("kind")
            spec = doc.get("spec", {})
            metadata = doc.get("metadata", {})
            if kind == "Service" and spec.get("type") == "LoadBalancer":
                labels = metadata.get("labels", {})
                lb_class = labels.get("lbipam.monosense.io/class")
                if lb_class not in approved_classes:
                    fail(f"LoadBalancer class missing or invalid: {path.relative_to(ROOT)}")
            if kind == "HelmRelease":
                chart_ref = spec.get("chartRef")
                if chart_ref and chart_ref.get("namespace") != "flux-system":
                    fail(f"HelmRelease chartRef is not centralized: {path.relative_to(ROOT)}")
            if kind in {"OCIRepository", "HelmRepository"} and KUBE / "apps" in path.parents:
                fail(f"application-local chart source remains: {path.relative_to(ROOT)}")

    source_names = {
        doc["metadata"]["name"]
        for path in paths
        for doc in yaml_documents(path)
        if doc.get("kind") in {"OCIRepository", "HelmRepository"}
        and doc.get("metadata", {}).get("namespace") == "flux-system"
    }
    chart_refs = {
        doc["spec"]["chartRef"]["name"]
        for path in paths
        for doc in yaml_documents(path)
        if doc.get("kind") == "HelmRelease" and doc.get("spec", {}).get("chartRef")
    }
    unresolved = sorted(chart_refs - source_names)
    if unresolved:
        fail(f"HelmRelease chart sources are unresolved: {unresolved}")


def validate_storage_contracts() -> None:
    openebs = yaml_documents(KUBE / "apps/openebs-system/openebs/app/helmrelease.yaml")[0]
    openebs_values = openebs["spec"]["values"]
    disabled = (
        "zfs-localpv",
        "lvm-localpv",
        "rawfile-localpv",
        "mayastor",
        "loki",
        "alloy",
        "minio",
    )
    if any(openebs_values.get(name, {}).get("enabled") is not False for name in disabled):
        fail("OpenEBS non-Hostpath engines or bundled services are not explicitly disabled")
    if openebs_values["openebs-crds"]["csi"]["volumeSnapshots"] != {"enabled": False, "keep": False}:
        fail("OpenEBS snapshot CRDs must remain disabled")
    local_classes = list(yaml_documents(KUBE / "apps/openebs-system/openebs/app/storageclasses.yaml"))
    expected_local = {
        "local-hostpath-delete": "Delete",
        "local-hostpath-retain": "Retain",
    }
    if {doc["metadata"]["name"]: doc["reclaimPolicy"] for doc in local_classes} != expected_local:
        fail("LocalPV classes must encode exact Delete/Retain semantics")
    for doc in local_classes:
        annotations = doc["metadata"].get("annotations", {})
        if doc["volumeBindingMode"] != "WaitForFirstConsumer" or "XFSQuota" not in annotations.get(
            "cas.openebs.io/config", ""
        ):
            fail("LocalPV classes must use delayed binding and XFS project quota")

    rook = yaml_documents(KUBE / "apps/rook-ceph/rook-ceph/cluster/helmrelease.yaml")[0]
    values = rook["spec"]["values"]
    cluster = values["cephClusterSpec"]
    expected_devices = {
        "bsd-k8s-01": "/dev/disk/by-id/nvme-eui.6479a7726a304b94",
        "bsd-k8s-02": "/dev/disk/by-id/nvme-eui.6479a77cda30650b",
        "bsd-k8s-03": "/dev/disk/by-id/nvme-nvme.10ec-5450424632333132313230303330333031313738-5445414d20544d3846503630303154-00000001",
        "bsd-k8s-04": "/dev/disk/by-id/nvme-eui.6479a7726a304bbf",
        "bsd-k8s-05": "/dev/disk/by-id/nvme-nvme.10ec-5450424632333132313230303330333031353935-5445414d20544d3846503630303154-00000001",
    }
    devices = {
        node["name"]: node["devices"][0]["name"]
        for node in cluster["storage"]["nodes"]
        if len(node.get("devices", [])) == 1
    }
    if devices != expected_devices or cluster["storage"]["useAllNodes"] or cluster["storage"]["useAllDevices"]:
        fail("Rook OSD selection differs from the five reviewed stable by-id devices")
    if cluster["network"].get("provider") != "host" or cluster["network"]["addressRanges"] != {
        "public": ["10.25.14.0/24"]
    }:
        fail("Ceph must use only the dedicated host storage subnet")
    if cluster["network"]["connections"]["encryption"]["enabled"] is not False:
        fail("Ceph device/network encryption decision drifted")
    if values["toolbox"]["enabled"] is not False or cluster["dashboard"] != {
        "enabled": True,
        "ssl": False,
    }:
        fail("Ceph toolbox must remain disabled and dashboard must use the oauth2-proxy upstream")
    if values.get("cephObjectStores") != []:
        fail("Ceph object storage is prohibited")

    repository = next(
        doc
        for doc in yaml_documents(KUBE / "apps/kopiur-system/kopiur/repository/clusterrepository.yaml")
        if doc.get("kind") == "ClusterRepository"
    )
    spec = repository["spec"]
    if spec["allowedNamespaces"] != {
        "selector": {"matchLabels": {"kopiur.home-operations.com/backup": "true"}}
    }:
        fail("Kopiur ClusterRepository must use the explicit namespace selector")
    s3 = spec["backend"]["s3"]
    if (s3["bucket"], s3["endpoint"], s3["prefix"]) != (
        "kubernetes-backups",
        "s3.monosense.io:443",
        "primary",
    ):
        fail("Kopiur primary repository must use TLS libreFS")
    if spec["scheduleDefaults"]["timezone"] != "Asia/Jakarta":
        fail("Kopiur timezone must be Asia/Jakarta")
    replication = yaml_documents(KUBE / "apps/kopiur-system/kopiur/repository/replication.yaml")[0]
    replication_spec = replication["spec"]
    if replication_spec["destination"]["s3"]["endpoint"] != "${R2_ENDPOINT}" or replication_spec[
        "destination"
    ]["s3"]["bucket"] != "${R2_BUCKET}":
        fail("R2 replication must bind its reviewed OpenBao-derived endpoint and bucket")
    if (
        replication_spec["sync"].get("deleteExtra") is not False
        or replication_spec["schedule"].get("timezone") != "Asia/Jakarta"
        or replication_spec.get("suspend") is not True
    ):
        fail("R2 replication must be additive, Jakarta-scheduled, and suspended until restore proof")
    rook_gate = yaml_documents(KUBE / "apps/rook-ceph/rook-ceph/config/ks.yaml")[0]
    kopiur_gate = yaml_documents(KUBE / "apps/kopiur-system/kopiur/config/ks.yaml")[0]
    if rook_gate["spec"].get("suspend") is not True:
        fail("Rook cluster must remain suspended until live storage acceptance")
    if kopiur_gate["spec"].get("suspend") is not True or kopiur_gate["spec"].get("prune") is not False:
        fail("Kopiur repository CRs must remain suspended and prune-protected until restore proof")

def validate_routing_contracts() -> None:
    proxy_path = KUBE / "apps/networking/envoy-gateway/proxy/envoy.yaml"
    proxy_docs = yaml_documents(proxy_path)
    indexed = {
        (doc.get("kind"), doc.get("metadata", {}).get("name")): doc
        for doc in proxy_docs
    }
    expected_gateways = {
        "envoy-edge": ("10.25.20.80", "envoy-edge-backend-tls"),
        "envoy-internal": ("10.25.20.40", "envoy-internal-tls"),
    }
    expected_sources = {
        "envoy-edge": ["10.25.15.10/32"],
        "envoy-internal": [
            "10.25.10.0/24",
            "10.25.11.0/24",
            "10.25.12.0/24",
            "10.25.13.0/24",
        ],
    }
    expected_listeners = {
        "envoy-edge": [("HTTPS", 443)],
        "envoy-internal": [("HTTPS", 443), ("HTTPS", 8444)],
    }
    for name, (vip, certificate) in expected_gateways.items():
        envoy_proxy = indexed[("EnvoyProxy", name)]
        provider = envoy_proxy["spec"]["provider"]["kubernetes"]
        deployment = provider["envoyDeployment"]
        if deployment.get("replicas") != 2:
            fail(f"{name} must run exactly two data-plane replicas")
        spread = deployment.get("pod", {}).get("topologySpreadConstraints", [])
        if len(spread) != 1 or spread[0].get("whenUnsatisfiable") != "DoNotSchedule":
            fail(f"{name} must use one hard hostname topology-spread constraint")
        if provider.get("envoyPDB") != {"minAvailable": 1}:
            fail(f"{name} must retain one available data-plane replica")
        if provider.get("envoyServiceAccount") != {"name": name}:
            fail(f"{name} must use its exact service account")
        service = provider["envoyService"]
        if service.get("loadBalancerSourceRanges") != expected_sources[name]:
            fail(f"{name} LoadBalancer source ranges are not exact")

        gateway = indexed[("Gateway", name)]
        gateway_spec = gateway["spec"]
        if gateway_spec["infrastructure"]["annotations"].get("lbipam.cilium.io/ips") != vip:
            fail(f"{name} VIP must remain {vip}")
        listeners = gateway_spec.get("listeners", [])
        if [
            (listener.get("protocol"), listener.get("port"))
            for listener in listeners
        ] != expected_listeners[name]:
            fail(f"{name} listener set is not exact")
        if any(
            listener.get("tls", {}).get("certificateRefs")
            != [{"kind": "Secret", "name": certificate}]
            for listener in listeners
        ):
            fail(f"{name} certificate references are not exact")

        traffic = indexed[("BackendTrafficPolicy", f"{name}-defaults")]
        if traffic["spec"].get("timeout", {}).get("http") != {
            "requestTimeout": "30s",
            "connectionIdleTimeout": "60s",
        }:
            fail(f"{name} HTTP timeout policy changed")

    edge_client = indexed[("ClientTrafficPolicy", "envoy-edge")]["spec"]
    if edge_client.get("clientIPDetection") != {"xForwardedFor": {"numTrustedHops": 1}}:
        fail("edge client IP policy must trust exactly one HAProxy hop")
    serialized_proxy = proxy_path.read_text()
    if any(term in serialized_proxy for term in ("HTTP3", "QUIC", "retry:", "compressor:")):
        fail("Envoy proxy configuration enables a rejected transport feature")

    external_dns = yaml_documents(
        KUBE / "apps/networking/external-dns/app/helmrelease.yaml"
    )[0]["spec"]["values"]
    if external_dns.get("sources") != ["gateway-httproute"]:
        fail("ExternalDNS must watch only Gateway API HTTPRoutes")
    if (
        external_dns.get("gatewayNamespace") != "networking"
        or external_dns.get("domainFilters") != ["monosense.io"]
        or external_dns.get("policy") != "sync"
        or external_dns.get("registry") != "txt"
        or external_dns.get("txtOwnerId") != "external-dns-internal"
    ):
        fail("ExternalDNS ownership or routing scope changed")
    required_args = {
        "--gateway-name=envoy-internal",
        "--rfc2136-host=10.25.13.33",
        "--rfc2136-port=53",
        "--rfc2136-zone=monosense.io",
        "--rfc2136-create-ptr=false",
        "--rfc2136-insecure=false",
        "--rfc2136-tsig-keyname=external-dns-internal.",
        "--rfc2136-tsig-secret-alg=hmac-sha256",
        "--rfc2136-tsig-axfr=false",
    }
    if not required_args.issubset(set(external_dns.get("extraArgs", []))):
        fail("ExternalDNS RFC2136 arguments are incomplete")
    if list((KUBE / "apps/networking/echo-server").rglob("*.yaml")):
        fail("permanent echo-server manifests remain")


def validate_database_contracts() -> None:
    cnpg = yaml_documents(
        KUBE / "apps/database/cloudnative-pg/app/helmrelease.yaml"
    )[0]["spec"]["values"]
    if cnpg.get("replicaCount") != 2 or cnpg.get("config", {}).get("clusterWide") is not False:
        fail("CloudNativePG operator must be two-replica and namespace-scoped")
    if cnpg.get("rbac", {}).get("aggregateClusterRoles") is not False:
        fail("CloudNativePG aggregate ClusterRoles are forbidden")

    postgres_docs = yaml_documents(KUBE / "apps/database/postgres/cluster/postgres.yaml")
    postgres = next(doc for doc in postgres_docs if doc.get("kind") == "Cluster")["spec"]
    if (
        postgres.get("instances") != 3
        or "@sha256:" not in postgres.get("imageName", "")
        or postgres.get("storage", {}).get("storageClass") != "local-hostpath-retain"
        or postgres.get("affinity", {}).get("podAntiAffinityType") != "required"
        or (postgres.get("minSyncReplicas"), postgres.get("maxSyncReplicas")) != (1, 1)
    ):
        fail("PostgreSQL HA, digest, and retained LocalPV contract changed")
    expected_limits = {"keycloak_a": 50, "keycloak_b": 50, "litellm_a": 30, "litellm_b": 30}
    roles = {
        role["name"]: role.get("connectionLimit")
        for role in postgres.get("managed", {}).get("roles", [])
    }
    if roles != expected_limits:
        fail(f"PostgreSQL alternating tenant roles or connection budgets changed: {roles!r}")
    stores = {
        doc["metadata"]["name"]: doc["spec"]["configuration"]["destinationPath"]
        for doc in postgres_docs
        if doc.get("kind") == "ObjectStore"
    }
    if stores != {
        "postgres-librefs": "s3://kubernetes-postgres/primary",
        "postgres-r2": "s3://${R2_BUCKET}/postgres",
    }:
        fail("PostgreSQL local-primary and R2-mirror destinations changed")
    mirror = (KUBE / "apps/database/postgres/cluster/mirror.yaml").read_text()
    if "mc mirror --preserve --retry" not in mirror or "mc diff" not in mirror or "--remove" in mirror:
        fail("PostgreSQL R2 mirror must be additive and verified")
    postgres_gate = yaml_documents(KUBE / "apps/database/postgres/config/ks.yaml")[0]["spec"]
    if postgres_gate.get("suspend") is not True or postgres_gate.get("prune") is not False:
        fail("PostgreSQL must remain prune-protected and suspended until restore proof")

    dragonfly_docs = yaml_documents(KUBE / "apps/database/dragonfly/cluster/dragonfly.yaml")
    dragonfly = next(doc for doc in dragonfly_docs if doc.get("kind") == "Dragonfly")["spec"]
    if (
        dragonfly.get("replicas") != 3
        or "@sha256:" not in dragonfly.get("image", "")
        or dragonfly.get("tlsSecretRef", {}).get("name") != "dragonfly-server-tls"
        or dragonfly.get("pdb") != {"minAvailable": 2}
        or dragonfly.get("snapshot", {}).get("cron") != "0 * * * *"
    ):
        fail("Dragonfly HA, TLS, PDB, or hourly snapshot contract changed")
    args = set(dragonfly.get("args", []))
    if "--cache_mode=false" not in args or "--maxmemory=4Gi" not in args:
        fail("Dragonfly must reject memory pressure instead of evicting durable state")
    service_doc = next(doc for doc in dragonfly_docs if doc.get("kind") == "Service")
    service = service_doc["spec"]
    if (
        service_doc.get("metadata", {}).get("annotations", {}).get("lbipam.cilium.io/ips")
        != "10.25.20.41"
        or service.get("loadBalancerSourceRanges") != ["10.25.10.101/32"]
        or service.get("ports") != [
            {"name": "dragonfly-tls", "port": 6379, "targetPort": 6379, "protocol": "TCP"}
        ]
    ):
        fail("Dragonfly internal VIP exposure changed")
    dragonfly_gate = yaml_documents(KUBE / "apps/database/dragonfly/config/ks.yaml")[0]["spec"]
    if dragonfly_gate.get("suspend") is not True or dragonfly_gate.get("prune") is not False:
        fail("Dragonfly must remain prune-protected and suspended until recovery proof")


def validate_identity_contracts() -> None:
    keycloak_docs = yaml_documents(KUBE / "apps/security/keycloak/cluster/keycloak.yaml")
    keycloak = next(doc for doc in keycloak_docs if doc.get("kind") == "Keycloak")
    spec = keycloak["spec"]
    if (
        spec.get("instances") != 2
        or "@sha256:" not in spec.get("image", "")
        or spec.get("bootstrapAdmin") is not None
        or spec.get("http", {}).get("httpEnabled") is not False
        or spec.get("http", {}).get("httpsPort") != 8443
        or spec.get("resources", {}).get("requests") != {"cpu": "500m", "memory": "1Gi"}
        or spec.get("resources", {}).get("limits") != {"cpu": "2", "memory": "2Gi"}
    ):
        fail("Keycloak HA, native TLS, resources, or bootstrap-removal contract changed")
    pdb = next(doc for doc in keycloak_docs if doc.get("kind") == "PodDisruptionBudget")
    if pdb["spec"].get("minAvailable") != 1:
        fail("Keycloak PDB must preserve one replica")

    routes = yaml_documents(KUBE / "apps/security/keycloak/cluster/routes.yaml")
    backend_tls = next(doc for doc in routes if doc.get("kind") == "BackendTLSPolicy")
    if backend_tls["spec"]["validation"] != {
        "caCertificateRefs": [
            {"group": "", "kind": "ConfigMap", "name": "keycloak-backend-ca"}
        ],
        "hostname": "keycloak.security.svc.cluster.local",
    }:
        fail("Keycloak Gateway backend must verify native TLS hostname and OpenBao CA")
    if any(
        backend.get("port") != 8443
        for route in routes
        if route.get("kind") == "HTTPRoute"
        for rule in route["spec"]["rules"]
        for backend in rule["backendRefs"]
    ):
        fail("Keycloak routes must not use plaintext backends")

    tofu = (KUBE / "apps/security/keycloak-tofu/tofu/main.tf").read_text()
    required_tofu = (
        'required_version = "= 1.12.6"',
        'version = "= 5.9.0"',
        'method "aes_gcm" "state"',
        "use_lockfile",
        "enforced = true",
        'access_token_lifespan',
        '"5m"',
        'sso_session_idle_timeout',
        '"8h"',
        'sso_session_max_lifespan',
        '"12h"',
        "revoke_refresh_token",
        "refresh_token_max_reuse",
        "webauthn-passwordless",
        "CONFIGURE_TOTP",
        "CONFIGURE_RECOVERY_AUTHN_CODES",
        "monosense-browser",
    )
    if not all(value in tofu for value in required_tofu):
        fail("Keycloak OpenTofu encryption, token, or passkey-first identity contract changed")
    if "offline_access" in tofu or "tls_insecure_skip_verify" in tofu:
        fail("Keycloak must not grant offline tokens or bypass TLS verification")

    runner_docs = yaml_documents(
        KUBE / "apps/security/keycloak-tofu/app/resources.yaml"
    )
    runner = next(doc for doc in runner_docs if doc.get("kind") == "Deployment")
    pod = runner["spec"]["template"]["spec"]
    container = pod["containers"][0]
    mounts = [mount["mountPath"] for mount in container["volumeMounts"]]
    if (
        runner["spec"].get("replicas") != 1
        or "@sha256:" not in container.get("image", "")
        or pod.get("automountServiceAccountToken") is not False
        or container["securityContext"].get("readOnlyRootFilesystem") is not True
        or container["securityContext"].get("allowPrivilegeEscalation") is not False
        or any("docker.sock" in mount for mount in mounts)
        or any(volume.get("persistentVolumeClaim") for volume in pod["volumes"])
    ):
        fail("Keycloak OpenTofu runner isolation contract changed")
    resources = (KUBE / "apps/security/keycloak-tofu/app/resources.yaml").read_text()
    if "--ephemeral" not in resources or "keycloak-tofu:host" not in resources:
        fail("Keycloak OpenTofu runner must remain one-job ephemeral and host-only")
    workflow = (ROOT / ".forgejo/workflows/keycloak-tofu.yaml").read_text()
    if (
        "environment: keycloak-production" not in workflow
        or "group: keycloak-tofu-global" not in workflow
        or "cancel-in-progress: false" not in workflow
        or "run-tofu.sh\" drift" not in workflow
        or "run-tofu.sh\" apply" not in workflow
    ):
        fail("Keycloak protected-main apply, global lock, or drift-only workflow changed")

    releases = yaml_documents(
        KUBE / "apps/security/oauth2-proxy/app/helmreleases.yaml"
    )
    expected = {"ceph", "alertmanager", "vlogs", "memini"}
    found = {doc["metadata"]["name"].removeprefix("oauth2-proxy-") for doc in releases}
    if found != expected:
        fail("Accepted oauth2-proxy deployment set changed")
    for release in releases:
        values = release["spec"]["values"]
        args = values["extraArgs"]
        if (
            values["config"].get("cookieName", "").startswith("__Host-") is False
            or args.get("cookie-secure") != "true"
            or args.get("cookie-httponly") != "true"
            or args.get("cookie-samesite") != "lax"
            or args.get("cookie-path") != "/"
            or args.get("cookie-csrf-per-request") != "true"
            or args.get("pass-authorization-header") != "false"
            or args.get("pass-access-token") != "false"
            or args.get("pass-user-headers") != "false"
        ):
            fail(f"oauth2-proxy boundary changed: {release['metadata']['name']}")


def validate_observability_contracts() -> None:
    metrics = yaml_documents(
        KUBE / "apps/observability/victoria-metrics-k8s-stack/app/helmrelease.yaml"
    )[0]["spec"]["values"]
    if (
        metrics["vmsingle"]["spec"].get("retentionPeriod") != "14d"
        or metrics["vmsingle"]["route"].get("enabled") is not False
        or metrics["alertmanager"]["spec"].get("configSecret") != "alertmanager-config"
        or metrics["alertmanager"]["route"].get("enabled") is not False
        or metrics["vmagent"]["spec"].get("statefulMode") is not True
        or metrics["vmagent"]["spec"]["statefulStorage"]["volumeClaimTemplate"]["spec"][
            "storageClassName"
        ]
        != "ceph-block"
    ):
        fail("VictoriaMetrics retention, protected routes, Telegram config, or vmagent buffer changed")

    logs = yaml_documents(
        KUBE / "apps/observability/victoria-logs/app/helmrelease.yaml"
    )[0]["spec"]["values"]
    server = logs["server"]
    if (
        server.get("retentionPeriod") != "30d"
        or server["persistentVolume"] != {
            "enabled": True,
            "storageClassName": "ceph-block",
            "size": "50Gi",
        }
        or server["route"].get("enabled") is not False
        or logs["vector"].get("enabled") is not False
    ):
        fail("VictoriaLogs 30-day/50GiB, private-query, or external-shipper contract changed")
    access = (KUBE / "apps/observability/victoria-logs/app/access.yaml").read_text()
    for value in (
        "sectionName: vlogs-ingest",
        "vlogs-ingest.internal",
        'path: "^/insert/.*"',
        'path: "^/select/.*"',
        "oauth2-proxy-vlogs",
        "serviceaccount.name: fluent-bit",
        "serviceaccount.name: envoy-internal",
    ):
        if value not in access:
            fail(f"VictoriaLogs query/ingestion isolation changed: {value}")

    fluent = (
        KUBE / "apps/observability/fluent-bit/app/helmrelease.yaml"
    ).read_text()
    for value in (
        "Keep_Log Off",
        "Name lua",
        "sanitize.lua",
        '\"authorization\", \"cookie\", \"token\", \"password\", \"secret\"',
        "_msg_field=message",
        "victoria-logs.observability.svc.cluster.local",
    ):
        if value not in fluent:
            fail(f"Fluent Bit metadata/redaction contract changed: {value}")

    grafana = yaml_documents(
        KUBE / "apps/observability/grafana-operator/instance/grafana.yaml"
    )[0]["spec"]["config"]
    oauth = grafana["auth.generic_oauth"]
    if (
        grafana["auth"].get("disable_login_form") != "true"
        or grafana["auth.anonymous"].get("enabled") != "false"
        or grafana["auth.basic"].get("enabled") != "false"
        or oauth.get("enabled") != "true"
        or oauth.get("use_pkce") != "true"
        or oauth.get("use_refresh_token") != "true"
        or oauth.get("allowed_groups") != "/platform/grafana-admins"
        or oauth.get("role_attribute_strict") != "true"
        or oauth.get("allow_assign_grafana_admin") != "false"
        or grafana["security"].get("disable_initial_admin_creation") != "true"
    ):
        fail("Grafana Keycloak-only authentication contract changed")
    datasources = (
        KUBE / "apps/observability/grafana-operator/instance/grafanadatasource.yaml"
    ).read_text()
    if "victoria-logs" in datasources or "vmalertmanager" in datasources:
        fail("Grafana must not bypass protected VictoriaLogs or Alertmanager routes")

    alert_config = (
        KUBE
        / "apps/observability/victoria-metrics-k8s-stack/app/alertmanager-secret.yaml"
    ).read_text()
    if (
        "telegram_configs:" not in alert_config
        or "telegram_bot_token" not in alert_config
        or ".CommonAnnotations" in alert_config
        or "blackhole" in alert_config
    ):
        fail("Alertmanager must use sanitized Telegram notifications from OpenBao")
    alert_policy = (
        KUBE / "apps/observability/victoria-metrics-k8s-stack/app/networkpolicy.yaml"
    ).read_text()
    if "api.telegram.org" not in alert_policy or 'port: "443"' not in alert_policy:
        fail("Alertmanager Telegram egress is not exact")

    probes = yaml_documents(
        KUBE / "apps/observability/blackbox-exporter/app/probes.yaml"
    )
    targets = {
        target
        for probe in probes
        for target in probe["spec"]["targets"]["staticConfig"]["static"]
    }
    expected_targets = {
        "https://vault.monosense.io:8200/v1/sys/health?standbyok=true",
        "https://git.monosense.io/api/healthz",
        "https://1.1.1.1/cdn-cgi/trace",
        "10.25.20.10:6443",
        "kube-dns.kube-system.svc.cluster.local:53",
        "10.25.13.35:53",
        "10.25.10.100:53",
        "10.25.13.33:53",
        "10.25.20.40:443",
        "10.25.20.80:443",
        "9.9.9.9:853",
        "10.25.13.16",
        "10.25.10.101",
    }
    if targets != expected_targets:
        fail("tiered blackbox critical-path targets changed")

    snmp = yaml_documents(
        KUBE / "apps/observability/snmp-exporter/app/helmrelease.yaml"
    )[0]
    snmp_ks = yaml_documents(KUBE / "apps/observability/snmp-exporter/ks.yaml")[0]
    if (
        "public_v2" in str(snmp)
        or "authPriv" not in (
            KUBE / "apps/observability/snmp-exporter/app/externalsecret.yaml"
        ).read_text()
        or snmp["spec"]["values"]["serviceMonitor"].get("params") != []
        or snmp_ks["spec"].get("suspend") is not True
        or snmp_ks["metadata"].get("annotations", {}).get(
            "infrastructure.monosense.io/blocked-by"
        )
        != "reviewed-snmpv3-target-inventory"
    ):
        fail("SNMP must remain fail-closed until exact SNMPv3 target inventory is pinned")
    smart_ks = yaml_documents(
        KUBE / "apps/observability/smartctl-exporter/ks.yaml"
    )[0]
    if (
        smart_ks["spec"].get("suspend") is not True
        or smart_ks["metadata"].get("annotations", {}).get(
            "infrastructure.monosense.io/blocked-by"
        )
        != "reviewed-smart-device-inventory"
    ):
        fail("smartctl must remain fail-closed until exact non-USB devices are pinned")

    envoy = (
        KUBE / "apps/networking/envoy-gateway/proxy/envoy.yaml"
    ).read_text()
    for value in (
        "name: vlogs-ingest",
        "port: 8444",
        "sectionName: vlogs-ingest",
        "clientValidation:",
        "name: vector-client-ca",
    ):
        if value not in envoy:
            fail(f"Vector mTLS ingestion listener changed: {value}")
    for path in (
        ROOT / "docker/c0/monitoring/config/vector.yaml.template",
        ROOT / "docker/c1/edge/config/vector.yaml",
    ):
        text = path.read_text()
        for value in (
            "https://vlogs-ingest.internal:8444/insert/jsonline",
            "verify_certificate: true",
            "verify_hostname: true",
            "type: disk",
            "when_full: block",
            "/run/vector-client/certificate.pem",
        ):
            if value not in text:
                fail(f"external Vector buffer/mTLS contract changed in {path}: {value}")
        if "verify_certificate: false" in text or "verify_hostname: false" in text:
            fail(f"external Vector TLS bypass remains in {path}")

    rejected = ("karma", "kromgo", "prometheus-adapter", "unpoller", "zfs", "zigbee")
    observability_text = "\\n".join(
        path.read_text(errors="ignore")
        for path in (KUBE / "apps/observability").rglob("*")
        if path.is_file()
    ).lower()
    for value in rejected:
        if value in observability_text:
            fail(f"rejected observability surface remains: {value}")


def validate_ai_contracts() -> None:
    namespace = yaml_documents(KUBE / "apps/ai/namespace.yaml")[0]
    labels = namespace["metadata"]["labels"]
    if labels.get("pod-security.kubernetes.io/enforce") != "restricted":
        fail("AI namespace must enforce the restricted Pod Security baseline")

    llmkube = yaml_documents(
        KUBE / "apps/ai/llmkube/app/helmrelease.yaml"
    )[0]
    if llmkube["spec"]["chart"]["spec"]["version"] != "0.9.24":
        fail("LLMKube chart version changed")
    controller = llmkube["spec"]["values"]["controllerManager"]
    if (
        controller["replicaCount"] != 2
        or controller["leaderElection"]["enabled"] is not True
        or llmkube["spec"]["values"]["modelCache"]["enabled"] is not False
        or "sha256:" not in controller["image"]["digest"]
    ):
        fail("LLMKube HA, digest, or no-cache contract changed")
    llmkube_text = "\n".join(
        path.read_text() for path in (KUBE / "apps/ai/llmkube/app").glob("*.yaml")
    )
    for value in (
        "f4602530db1d980e16da9d7d3a70294cf5c190be",
        "4279660224",
        "b60ae5ce2dd6a0b77f82cadf21def1f310a3e10cde380ad0081b07a9d416949d",
        "contextSize: 8192",
        "parallelSlots: 2",
        "mode: embedding",
        "Qwen/Qwen3-Embedding-4B-GGUF/resolve/f4602530db1d980e16da9d7d3a70294cf5c190be/Qwen3-Embedding-4B-Q8_0.gguf",
        "qwen3-embedding-tls",
        "qwen3-embedding",
        "10.25.13.95",
    ):
        if value not in llmkube_text:
            fail(f"Mac embedding contract changed: {value}")
    identity = (KUBE / "apps/ai/llmkube/app/identity.yaml").read_text()
    if (
        "resources: [secrets]" not in identity
        or "verbs: [get]" not in identity
        or "list, watch" in identity.split("resources: [secrets]", 1)[1]
        or "expirationSeconds:31536000" not in (
            KUBE / "scripts/llmkube-mac.sh"
        ).read_text()
    ):
        fail("Metal Agent certificate or named-Secret RBAC widened")

    memini_docs = yaml_documents(KUBE / "apps/ai/memini/app/statefulset.yaml")
    memini = next(doc for doc in memini_docs if doc.get("kind") == "StatefulSet")
    container = memini["spec"]["template"]["spec"]["containers"][0]
    if (
        memini["spec"]["replicas"] != 1
        or container["resources"]["requests"] != {"cpu": "50m", "memory": "128Mi"}
        or container["resources"]["limits"] != {"cpu": "1", "memory": "512Mi"}
        or memini["spec"]["volumeClaimTemplates"][0]["spec"]["resources"]["requests"][
            "storage"
        ]
        != "10Gi"
    ):
        fail("Memini singleton resource/storage contract changed")
    memini_text = "\n".join(
        path.read_text() for path in (KUBE / "apps/ai/memini/app").glob("*.yaml")
    )
    for value in (
        "MEMINI_RECALL_EMBED_TIMEOUT",
        "MEMINI_WRITE_EMBED_TIMEOUT",
        "value: 2s",
        "MEMINI_BACKGROUND_EMBED_TIMEOUT",
        "MEMINI_BACKFILL_INTERVAL",
        "MEMINI_CONSOLIDATE_MODE",
        "MEMINI_RERANK",
        "MEMINI_SPLIT_DEDUP_LLM_MERGE",
        "MEMINI_DEDUP_LLM_MERGE",
        'schedule: "17 */6 * * *"',
        'schedule: "43 18 * * *"',
        "VACUUM INTO",
        "PRAGMA integrity_check",
        "-mtime +14",
        "memini-api.internal",
    ):
        if value not in memini_text:
            fail(f"Memini durability or fallback contract changed: {value}")
    if "envoy-edge" in memini_text:
        fail("Memini must have no edge route")

    litellm = yaml_documents(
        KUBE / "apps/ai/litellm/app/helmrelease.yaml"
    )[0]
    values = litellm["spec"]["values"]
    if (
        litellm["spec"]["chart"]["spec"]["version"] != "1.99.0"
        or values["replicaCount"] != 2
        or values["db"]["deployStandalone"] is not False
        or values["redis"]["enabled"] is not False
        or values["resources"]["requests"] != {"cpu": "250m", "memory": "512Mi"}
        or values["resources"]["limits"] != {"cpu": "1", "memory": "1Gi"}
    ):
        fail("LiteLLM official-chart HA or external-state contract changed")
    models = values["proxy_config"]["model_list"]
    if [model["model_name"] for model in models] != [
        "memini-chat",
        "forgejo-codex",
    ]:
        fail("LiteLLM exposes an unreviewed model alias")
    router = values["proxy_config"]["router_settings"]
    if (
        router.get("disable_cache") is not True
        or router.get("fallbacks") != []
        or router.get("context_window_fallbacks") != []
    ):
        fail("LiteLLM cache or fallback must remain disabled")
    litellm_text = "\n".join(
        path.read_text() for path in (KUBE / "apps/ai/litellm/app").glob("*.yaml")
    )
    for value in (
        "minimax/MiniMax-M2.1",
        "turn_off_message_logging: true",
        "litellm-admin.internal",
        "litellm.internal",
    ):
        if value not in litellm_text:
            fail(f"LiteLLM privacy/private-route contract changed: {value}")
    if "envoy-edge" in litellm_text or "oauth2-proxy" in litellm_text:
        fail("LiteLLM must remain private with password-only admin UI")

    adapter = yaml_documents(
        KUBE / "apps/ai/codex-adapter/app/workload.yaml"
    )
    deployment = next(doc for doc in adapter if doc.get("kind") == "Deployment")
    containers = deployment["spec"]["template"]["spec"]["containers"]
    main = next(container for container in containers if container["name"] == "adapter")
    if (
        main["resources"]["requests"] != {"cpu": "100m", "memory": "256Mi"}
        or main["resources"]["limits"] != {"cpu": "1", "memory": "512Mi"}
        or deployment["spec"]["template"]["spec"]["volumes"][1]["emptyDir"].get(
            "medium"
        )
        != "Memory"
    ):
        fail("Codex adapter resources or memory-only OAuth state changed")
    checkpoint = (
        KUBE / "apps/ai/codex-adapter/app/checkpoint.py"
    ).read_text()
    if (
        "platform/data/kubernetes/ai/codex-adapter" not in checkpoint
        or '"codex-checkpoint"' not in checkpoint
        or "json.loads(raw)" not in checkpoint
    ):
        fail("Codex atomic OpenBao checkpoint contract changed")

    for path in (
        KUBE / "scripts/accept-ai.sh",
        KUBE / "scripts/llmkube-mac.sh",
        ROOT / "scripts/provision-ai-secrets.sh",
        ROOT / "docs/LLMKUBE-MACOS-METAL.md",
    ):
        if not path.exists():
            fail(f"AI operator contract is missing: {path}")


def validate_upgrade_contracts() -> None:
    namespace = yaml_documents(KUBE / "apps/system-upgrade/namespace.yaml")[0]
    labels = namespace["metadata"]["labels"]
    if labels.get("pod-security.kubernetes.io/enforce") != "restricted":
        fail("system-upgrade must enforce restricted Pod Security")

    upgrades = KUBE / "apps/system-upgrade/tuppr/upgrades"
    if (upgrades / "talos.yaml").exists():
        fail("TalosUpgrade must be absent until a stable forward v1.14 target is reviewed")
    resources = yaml_documents(upgrades / "kustomization.yaml")[0]["resources"]
    if resources != ["./kubernetes.yaml"]:
        fail("only the suspended Kubernetes upgrade target may be rendered")

    kubernetes = yaml_documents(upgrades / "kubernetes.yaml")[0]
    kube_spec = kubernetes["spec"]
    if (
        kubernetes["metadata"]["annotations"].get(
            "tuppr.home-operations.com/suspend"
        )
        != "separate-attended-window-required"
        or kube_spec["kubernetes"]["version"] != "v1.36.4"
        or "-" in kube_spec["kubernetes"]["version"][1:]
        or kube_spec["maintenance"]
        != {
            "windows": [
                {
                    "start": "0 1 * * 0",
                    "duration": "6h",
                    "timezone": "Asia/Jakarta",
                }
            ]
        }
    ):
        fail("Kubernetes stable, suspended, or attended-window contract changed")
    required_checks = {
        ("v1", "Node", None, None),
        ("ceph.rook.io/v1", "CephCluster", "rook-ceph", "rook-ceph"),
        ("postgresql.cnpg.io/v1", "Cluster", "database", "postgres"),
        (
            "kustomize.toolkit.fluxcd.io/v1",
            "Kustomization",
            "flux-system",
            "cluster-apps",
        ),
    }
    kube_checks = {
        (check["apiVersion"], check["kind"], check.get("namespace"), check.get("name"))
        for check in kube_spec["healthChecks"]
    }
    if not required_checks <= kube_checks:
        fail("Kubernetes upgrade health gates changed")

    release = yaml_documents(
        KUBE / "apps/system-upgrade/tuppr/app/helmrelease.yaml"
    )[0]
    values = release["spec"]["values"]
    if (
        values["replicaCount"] != 2
        or values["talosServiceAccount"]["create"] is not True
        or values["podSecurityContext"]["seccompProfile"]["type"]
        != "RuntimeDefault"
        or values["securityContext"]["readOnlyRootFilesystem"] is not True
    ):
        fail("Tuppr HA, os:admin service account, or restricted security changed")
    security = (KUBE / "apps/system-upgrade/tuppr/app/security.yaml").read_text()
    for value in ("kind: PodDisruptionBudget", "10.25.11.15/32", 'port: "50000"'):
        if value not in security:
            fail(f"Tuppr isolation contract changed: {value}")

    preflight = (KUBE / "scripts/accept-upgrade-preflight.sh").read_text()
    for value in (
        "EXPECTED_NODES",
        "etcd snapshot",
        "bgp-verify",
        "disruptionsAllowed",
        "ALERTMANAGER_RAW",
        "assert_suspended",
        "TalosUpgrade must be absent",
        "kubeletVersion",
    ):
        if value not in preflight:
            fail(f"upgrade preflight gate changed: {value}")
    if " annotate " in preflight or " patch " in preflight:
        fail("non-upgrading preflight must not mutate Kubernetes resources")

    version_guard = KUBE / "scripts/assert-forward-version.sh"
    if not version_guard.exists():
        fail("upgrade forward-version guard is missing")
    allowed_transitions = (
        ("v1.13.8", "v1.13.9", "1"),
        ("v1.12.9", "v1.13.9", "1"),
        ("v1.13.9-rc.2", "v1.13.9", "1"),
        ("v1.35.9", "v1.36.4", "1"),
    )
    forbidden_transitions = (
        ("v1.14.0-rc.2", "v1.13.9", "1"),
        ("v1.13.9", "v1.13.9", "1"),
        ("v1.13.10", "v1.13.9", "1"),
        ("v1.11.9", "v1.13.9", "1"),
        ("v1.13.8", "v1.14.0-rc.2", "1"),
        ("v2.0.0", "v1.13.9", "1"),
    )
    for transition in allowed_transitions:
        result = subprocess.run(
            [str(version_guard), *transition],
            check=False,
            capture_output=True,
            text=True,
        )
        if result.returncode != 0:
            fail(f"safe version transition was rejected: {transition}: {result.stderr}")
    for transition in forbidden_transitions:
        result = subprocess.run(
            [str(version_guard), *transition],
            check=False,
            capture_output=True,
            text=True,
        )
        if result.returncode == 0:
            fail(f"unsafe version transition was accepted: {transition}")

    attended = (KUBE / "scripts/attend-upgrade.sh").read_text()
    for value in (
        "Asia/Jakarta",
        "create_silence",
        "21600",
        "tuppr.home-operations.com/suspend-",
        "FLUX_KUSTOMIZATION",
        "trap cleanup",
    ):
        if value not in attended:
            fail(f"attended upgrade safety contract changed: {value}")
    if "talosupgrades.tuppr.home-operations.com" in attended:
        fail("attended Talos upgrades must remain unavailable without a stable forward target")


def validate_prune_protection(paths: list[pathlib.Path]) -> None:
    allowlist_path = KUBE / "retirement/protected-resources.tsv"
    allowed: dict[tuple[str, str, str, str], str] = {}
    for line in allowlist_path.read_text().splitlines():
        if not line or line.startswith("#"):
            continue
        fixed_id, api_version, kind, namespace, name, reason = line.split("\t", 5)
        if not reason:
            fail(f"protected resource lacks reason: {fixed_id}")
        allowed[(api_version, kind, namespace, name)] = fixed_id
    protected: set[tuple[str, str, str, str]] = set()
    for path in paths:
        for doc in yaml_documents(path):
            metadata = doc.get("metadata", {})
            if metadata.get("annotations", {}).get("kustomize.toolkit.fluxcd.io/prune") != "disabled":
                continue
            key = (
                doc.get("apiVersion", ""),
                doc.get("kind", ""),
                metadata.get("namespace", ""),
                metadata.get("name", ""),
            )
            protected.add(key)
            if key not in allowed:
                fail(f"prune-protected resource is not retirement-allowlisted: {path.relative_to(ROOT)}")
    missing = sorted(set(allowed) - protected)
    if missing:
        fail(f"retirement allowlist entries have no protected manifest: {missing}")


def main() -> None:
    paths = all_yaml()
    validate_root_boundary()
    validate_storage_contracts()
    validate_routing_contracts()
    validate_database_contracts()
    validate_identity_contracts()
    validate_observability_contracts()
    validate_ai_contracts()
    validate_upgrade_contracts()
    validate_prohibited_values()
    validate_secret_contracts(paths)
    validate_openbao_auth(paths)
    validate_services_and_sources(paths)
    validate_prune_protection(paths)
    print("exclusive roots, copied-value, OpenBao, storage, routing, database, identity, observability, AI, upgrade, source, and LoadBalancer contracts passed")


if __name__ == "__main__":
    main()
