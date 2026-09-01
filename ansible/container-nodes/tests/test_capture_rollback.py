from __future__ import annotations

import hashlib
import importlib.util
import json
import stat
import tempfile
import unittest
from pathlib import Path


SCRIPT = Path(__file__).parents[1] / "scripts" / "capture_rollback.py"
SPEC = importlib.util.spec_from_file_location("capture_rollback", SCRIPT)
assert SPEC and SPEC.loader
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class CaptureRollbackTests(unittest.TestCase):
    def test_atomic_canonical_generation_and_idempotence(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary)
            source = base / "managed.conf"
            source.write_text("canary\n", encoding="utf-8")
            source.chmod(0o640)
            root = base / "rollback"
            audit = "a" * 64
            generation = hashlib.sha256(f"c1:1:{audit}".encode()).hexdigest()

            self.assertTrue(MODULE.capture(root, generation, "c1", audit, 1, [str(source)]))
            destination = root / generation
            self.assertEqual(stat.S_IMODE(destination.stat().st_mode), 0o700)
            manifest_payload = (destination / "manifest.json").read_bytes()
            marker = (destination / "complete").read_text(encoding="ascii").strip()
            self.assertEqual(marker, hashlib.sha256(manifest_payload).hexdigest())
            manifest = json.loads(manifest_payload)
            self.assertEqual(manifest["generation_id"], generation)
            self.assertEqual(manifest["paths"][0]["mode"], "0640")
            self.assertEqual(manifest["paths"][0]["sha256"], hashlib.sha256(b"canary\n").hexdigest())
            self.assertTrue((destination / "tree" / str(source).lstrip("/")).is_file())
            self.assertFalse(MODULE.capture(root, generation, "c1", audit, 1, [str(source)]))
            self.assertFalse(any(path.name.startswith(f".{generation}.") for path in root.iterdir()))

    def test_secret_and_application_paths_are_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary) / "rollback"
            for forbidden in (
                "/opt/doco-cd/secrets/token",
                "/srv/applications/data",
                "/var/lib/docker/volumes/data",
                "/var/lib/containerd/state",
            ):
                with self.subTest(forbidden=forbidden):
                    with self.assertRaises(ValueError):
                        MODULE.capture(root, "b" * 64, "c0", "c" * 64, 1, [forbidden])

    def test_tampered_complete_generation_fails_closed(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary)
            source = base / "managed.conf"
            source.write_text("one\n", encoding="utf-8")
            root = base / "rollback"
            generation = "d" * 64
            MODULE.capture(root, generation, "c0", "e" * 64, 1, [str(source)])
            (root / generation / "complete").write_text("0" * 64 + "\n", encoding="ascii")
            with self.assertRaises(RuntimeError):
                MODULE.capture(root, generation, "c0", "e" * 64, 1, [str(source)])

    def test_ansible_retention_is_newest_five_and_module_owned(self) -> None:
        tasks = (Path(__file__).parents[1] / "tasks" / "capture-rollback.yml").read_text(encoding="utf-8")
        self.assertIn("ansible.builtin.find:", tasks)
        self.assertIn("ansible.builtin.file:", tasks)
        self.assertIn("sort(attribute='mtime', reverse=true)", tasks)
        self.assertIn("[container_nodes_rollback_generations:]", tasks)
        self.assertIn("/opt/doco-cd/secrets", tasks)


if __name__ == "__main__":
    unittest.main()
