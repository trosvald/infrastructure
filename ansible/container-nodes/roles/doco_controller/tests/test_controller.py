#!/usr/bin/env python3
"""Behavior tests for Doco controller readiness, preflight, and project lifecycle gates."""

import importlib.util
import json
import stat
import types
import unittest
from pathlib import Path
from unittest import mock

ROLE = Path(__file__).parents[1]


def load_script(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    assert spec and spec.loader
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


READY = load_script("doco_controller_ready", ROLE / "files" / "doco_controller_ready.py")
LIFECYCLE = load_script("doco_project_lifecycle", ROLE / "files" / "doco_project_lifecycle.py")


class Response:
    status = 200

    def __init__(self, payload=b'{"content":[]}'):
        self.payload = payload

    def __enter__(self):
        return self

    def __exit__(self, *_args):
        return False

    def read(self):
        return self.payload


class ProtectedFile:
    def __init__(self, value="safe-api-secret", *, mode=0o600, uid=0, gid=0):
        self.metadata = types.SimpleNamespace(
            st_mode=stat.S_IFREG | mode,
            st_uid=uid,
            st_gid=gid,
            st_size=len(value),
        )
        self.value = value

    def lstat(self):
        return self.metadata

    def read_text(self, *, encoding):
        self.encoding = encoding
        return self.value

    def __str__(self):
        return "/protected/file"


class ControllerReadinessTests(unittest.TestCase):
    def setUp(self):
        self.secret = ProtectedFile()
        self.patches = [
            mock.patch.object(READY, "SECRET_FILE", self.secret),
            mock.patch.object(READY.os, "geteuid", return_value=0),
        ]
        for patcher in self.patches:
            patcher.start()
            self.addCleanup(patcher.stop)

    def test_authenticated_projects_endpoint_is_the_only_success_path(self):
        with mock.patch.object(READY.urllib.request, "urlopen", return_value=Response()) as urlopen:
            READY.main()
        request = urlopen.call_args.args[0]
        self.assertEqual(request.full_url, "http://127.0.0.1:8080/v1/api/projects")
        self.assertEqual(request.get_header("X-api-key"), "safe-api-secret")
        self.assertNotIn("safe-api-secret", request.full_url)

    def test_non_root_is_rejected_before_network_access(self):
        with mock.patch.object(READY.os, "geteuid", return_value=1000), mock.patch.object(
            READY.urllib.request, "urlopen"
        ) as urlopen:
            with self.assertRaisesRegex(SystemExit, "must run as root"):
                READY.main()
        urlopen.assert_not_called()

    def test_symlink_or_wrong_mode_is_rejected(self):
        for metadata in (
            types.SimpleNamespace(st_mode=stat.S_IFLNK | 0o600, st_uid=0, st_gid=0),
            types.SimpleNamespace(st_mode=stat.S_IFREG | 0o644, st_uid=0, st_gid=0),
        ):
            with self.subTest(mode=metadata.st_mode):
                self.secret.metadata = metadata
                with self.assertRaisesRegex(SystemExit, "custody mismatch"):
                    READY.main()

    def test_secret_whitespace_is_rejected_without_disclosure(self):
        self.secret.value = "safe-api-secret\n"
        with self.assertRaises(SystemExit) as failure:
            READY.main()
        self.assertNotIn("safe-api-secret", str(failure.exception))

    def test_unavailable_controller_fails_after_bounded_deadline(self):
        with mock.patch.object(READY.time, "monotonic", side_effect=[0, 91]), mock.patch.object(
            READY.urllib.request, "urlopen"
        ) as urlopen:
            with self.assertRaisesRegex(SystemExit, "within 90 seconds"):
                READY.main()
        urlopen.assert_not_called()


class ProjectLifecycleTests(unittest.TestCase):
    def setUp(self):
        self.secret = ProtectedFile()
        self.allowlist = ProtectedFile("librefs-c1\nedge-c1\n")
        self.patches = [
            mock.patch.object(LIFECYCLE, "API_SECRET_FILE", self.secret),
            mock.patch.object(LIFECYCLE, "ALLOWLIST_FILE", self.allowlist),
            mock.patch.object(LIFECYCLE.os, "geteuid", return_value=0),
            mock.patch.object(LIFECYCLE.sys, "argv", ["helper", "start", "librefs-c1"]),
        ]
        for patcher in self.patches:
            patcher.start()
            self.addCleanup(patcher.stop)

    def test_start_posts_only_to_exact_project_action(self):
        with mock.patch.object(LIFECYCLE.urllib.request, "urlopen", return_value=Response()) as urlopen:
            LIFECYCLE.main()
        request = urlopen.call_args.args[0]
        self.assertEqual(request.method, "POST")
        self.assertEqual(
            request.full_url,
            "http://127.0.0.1:8080/v1/api/project/librefs-c1/start?timeout=30",
        )
        self.assertNotIn("reconcile", request.full_url)
        self.assertEqual(request.get_header("X-api-key"), "safe-api-secret")

    def test_stop_uses_the_same_allowlisted_existing_project_boundary(self):
        with mock.patch.object(LIFECYCLE.sys, "argv", ["helper", "stop", "edge-c1"]), mock.patch.object(
            LIFECYCLE.urllib.request, "urlopen", return_value=Response()
        ) as urlopen:
            LIFECYCLE.main()
        self.assertEqual(
            urlopen.call_args.args[0].full_url,
            "http://127.0.0.1:8080/v1/api/project/edge-c1/stop?timeout=30",
        )

    def test_unknown_project_and_action_fail_before_api_access(self):
        for argv in (["helper", "start", "unknown-c1"], ["helper", "reconcile", "librefs-c1"]):
            with self.subTest(argv=argv), mock.patch.object(LIFECYCLE.sys, "argv", argv), mock.patch.object(
                LIFECYCLE.urllib.request, "urlopen"
            ) as urlopen:
                with self.assertRaises(SystemExit):
                    LIFECYCLE.main()
                urlopen.assert_not_called()

    def test_api_secret_whitespace_is_rejected_without_disclosure(self):
        self.secret.value = "safe-api-secret\n"
        with self.assertRaises(SystemExit) as failure:
            LIFECYCLE.main()
        self.assertNotIn("safe-api-secret", str(failure.exception))


class ControllerPreflightTests(unittest.TestCase):
    def render(self, contracts):
        source = (ROLE / "templates" / "doco_controller_preflight.py.j2").read_text(
            encoding="utf-8"
        )
        source = source.replace(
            "{{ doco_controller_protected_files | to_json }}", json.dumps(contracts)
        )
        namespace = {"__name__": "rendered_preflight"}
        exec(compile(source, "rendered-preflight", "exec"), namespace)
        return namespace

    def test_preflight_accepts_only_nonempty_root_regular_exact_mode_files(self):
        namespace = self.render([{"path": "/protected/api", "mode": "0600"}])
        protected = ProtectedFile()
        with mock.patch.object(namespace["os"], "geteuid", return_value=0), mock.patch.object(
            namespace["Path"], "lstat", return_value=protected.metadata
        ):
            namespace["main"]()

    def test_preflight_rejects_missing_or_wrong_custody(self):
        namespace = self.render([{"path": "/protected/api", "mode": "0600"}])
        with mock.patch.object(namespace["os"], "geteuid", return_value=0), mock.patch.object(
            namespace["Path"], "lstat", side_effect=FileNotFoundError
        ):
            with self.assertRaisesRegex(SystemExit, "protected file is missing"):
                namespace["main"]()
        wrong = ProtectedFile(mode=0o644)
        with mock.patch.object(namespace["os"], "geteuid", return_value=0), mock.patch.object(
            namespace["Path"], "lstat", return_value=wrong.metadata
        ):
            with self.assertRaisesRegex(SystemExit, "custody mismatch"):
                namespace["main"]()


if __name__ == "__main__":
    unittest.main()
