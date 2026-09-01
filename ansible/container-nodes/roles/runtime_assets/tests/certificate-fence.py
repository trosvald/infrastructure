#!/usr/bin/env python3
import importlib.util
import json
import os
import pathlib
import sys
import tempfile
import types

# Fence behavior is independent of X.509 parsing. Host deployment pins python3-cryptography;
# this offline test stubs only the imported module names so controller CI needs no Python package.
cryptography = types.ModuleType("cryptography")
x509 = types.ModuleType("cryptography.x509")
hazmat = types.ModuleType("cryptography.hazmat")
primitives = types.ModuleType("cryptography.hazmat.primitives")
serialization = types.ModuleType("cryptography.hazmat.primitives.serialization")
cryptography.x509 = x509
hazmat.primitives = primitives
primitives.serialization = serialization
sys.modules.update(
    {
        "cryptography": cryptography,
        "cryptography.x509": x509,
        "cryptography.hazmat": hazmat,
        "cryptography.hazmat.primitives": primitives,
        "cryptography.hazmat.primitives.serialization": serialization,
    }
)

HERE = pathlib.Path(__file__).resolve()
ROOT = HERE.parents[5]
sys.path.insert(0, str(ROOT / "docker" / "scripts"))
fetch_spec = importlib.util.spec_from_file_location(
    "runtime_fetch_wildcard", HERE.parent.parent / "files" / "fetch_wildcard_certificate.py"
)
fetch = importlib.util.module_from_spec(fetch_spec)
fetch_spec.loader.exec_module(fetch)
import install_certificate
if os.geteuid() != 0:
    # Production helpers require root; this test exercises fencing as an unprivileged CI user.
    os.fchown = lambda _fd, _uid, _gid: None


with tempfile.TemporaryDirectory() as directory:
    target = pathlib.Path(directory) / "tls"
    fetch._write_fence(target, 7, "aaa")
    fetch._validate_fence(target, 7, "aaa")
    for version, serial in ((7, "bbb"), (6, "aaa")):
        try:
            fetch._validate_fence(target, version, serial)
        except fetch.FetchError:
            pass
        else:
            raise AssertionError("unfenced wildcard regression was accepted")
    releases = target / "releases"
    (releases / "aaa").mkdir(parents=True)
    (releases / "bbb").mkdir()
    (target / "current").symlink_to("releases/bbb")
    (target / "previous").symlink_to("releases/aaa")
    install_certificate.rollback_pair(target, None)
    assert (target / "current").readlink() == pathlib.Path("releases/aaa")
    fence = json.loads((target / ".openbao-certificate-fence.json").read_text())
    assert fence == {"blocked_version": 7, "kv_version": 7, "serial": "aaa"}
    try:
        fetch._validate_fence(target, 7, "bbb")
    except fetch.FetchError:
        pass
    else:
        raise AssertionError("rolled-back KV version was accepted")
    fetch._validate_fence(target, 8, "ccc")
print("wildcard certificate CAS/serial rollback fencing tests passed")
