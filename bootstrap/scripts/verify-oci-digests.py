#!/usr/bin/env python3
from __future__ import annotations

import json
import re
import urllib.error
import urllib.parse
import urllib.request

ARTIFACTS = (
    ("quay.io", "cilium/charts/cilium", "1.19.6", "sha256:b8d600c542c97dc8652429e12487ecce922d73de9785505457a8f653833e75f9"),
    ("ghcr.io", "coredns/charts/coredns", "1.46.2", "sha256:0557fae64cfbde5c89459025ebcf065b453c29d1fc70036fcb1e1aeb4e81a612"),
    ("ghcr.io", "controlplaneio-fluxcd/charts/flux-operator", "0.55.0", "sha256:9e73c85b586f3649b317b215228ac35c1dd15a10dec87b8806f34bd7a22d42ae"),
)
ACCEPT = ", ".join(
    (
        "application/vnd.oci.image.manifest.v1+json",
        "application/vnd.cncf.helm.chart.v1+json",
        "application/vnd.docker.distribution.manifest.v2+json",
    )
)


def request(url: str, token: str | None = None):
    headers = {"Accept": ACCEPT}
    if token:
        headers["Authorization"] = f"Bearer {token}"
    return urllib.request.urlopen(urllib.request.Request(url, method="HEAD", headers=headers), timeout=15)


def token_from_challenge(challenge: str) -> str:
    if not challenge.startswith("Bearer "):
        raise SystemExit(f"registry did not offer bearer authentication: {challenge}")
    values = dict(re.findall(r'(\w+)="([^"]+)"', challenge[7:]))
    realm = values.pop("realm", None)
    if not realm:
        raise SystemExit("registry bearer challenge omitted realm")
    url = realm + "?" + urllib.parse.urlencode(values)
    with urllib.request.urlopen(url, timeout=15) as response:
        payload = json.load(response)
    token = payload.get("token") or payload.get("access_token")
    if not token:
        raise SystemExit("registry token response omitted token")
    return token


def digest(host: str, repository: str, reference: str) -> str:
    url = f"https://{host}/v2/{repository}/manifests/{reference}"
    try:
        response = request(url)
    except urllib.error.HTTPError as error:
        if error.code != 401:
            raise
        response = request(url, token_from_challenge(error.headers.get("WWW-Authenticate", "")))
    with response:
        value = response.headers.get("Docker-Content-Digest", "")
    if not re.fullmatch(r"sha256:[0-9a-f]{64}", value):
        raise SystemExit(f"registry returned no canonical digest for {host}/{repository}:{reference}")
    return value


def main() -> None:
    for host, repository, reference, expected in ARTIFACTS:
        observed = digest(host, repository, reference)
        if observed != expected:
            raise SystemExit(
                f"OCI tag digest mismatch for {host}/{repository}:{reference}: "
                f"expected {expected}, observed {observed}"
            )
        print(f"verified {host}/{repository}:{reference}@{observed}")


if __name__ == "__main__":
    main()
