import hashlib
import importlib.util
import json
import pathlib
import subprocess
import sys
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
CANONICALIZER = ROOT / "roles/audit/files/canonicalize_audit.py"


def load_canonicalizer():
    spec = importlib.util.spec_from_file_location("container_node_audit", CANONICALIZER)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module


class AuditCanonicalizationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.audit = load_canonicalizer()

    def test_key_order_and_input_whitespace_do_not_change_digest(self):
        first = {"schema_version": 1, "host": "c1", "state": {"z": 1, "a": [3, 2, 1]}}
        second = {"state": {"a": [3, 2, 1], "z": 1}, "host": "c1", "schema_version": 1}
        canonical_first = self.audit.canonicalize(first)
        canonical_second = self.audit.canonicalize(second)
        self.assertEqual(canonical_first, canonical_second)
        self.assertEqual(canonical_first, b'{"host":"c1","schema_version":1,"state":{"a":[3,2,1],"z":1}}\n')

    def test_private_identifiers_are_stably_hashed_and_plaintext_is_absent(self):
        source = {
            "schema_version": 1,
            "machine_id": "machine-identity",
            "interfaces": [{"mac_address": "00:11:22:33:44:55"}],
        }
        canonical = self.audit.canonicalize(source)
        decoded = json.loads(canonical)
        self.assertRegex(decoded["machine_id"], r"^sha256:[0-9a-f]{64}$")
        self.assertRegex(decoded["interfaces"][0]["mac_address"], r"^sha256:[0-9a-f]{64}$")
        self.assertNotIn(b"machine-identity", canonical)
        self.assertNotIn(b"00:11:22:33:44:55", canonical)
        self.assertEqual(canonical, self.audit.canonicalize(decoded))

    def test_secret_bearing_fields_and_wrong_schema_fail_closed(self):
        forbidden = ("password", "api_token", "client_secret", "private_key", "credential_file")
        for key in forbidden:
            with self.subTest(key=key), self.assertRaises(ValueError):
                self.audit.canonicalize({"schema_version": 1, key: "synthetic-not-a-secret"})
        for value in (None, 0, 2, "1"):
            with self.subTest(schema=value), self.assertRaises(ValueError):
                self.audit.canonicalize({"schema_version": value})

    def test_cli_digest_matches_exact_canonical_artifact(self):
        evidence = {"schema_version": 1, "host": "c0", "packages": ["a=1", "b=2"]}
        raw = json.dumps(evidence, indent=2).encode()
        with tempfile.TemporaryDirectory() as directory:
            input_path = pathlib.Path(directory) / "input.json"
            output_path = pathlib.Path(directory) / "audit.json"
            input_path.write_bytes(raw)
            completed = subprocess.run(
                [sys.executable, str(CANONICALIZER), str(input_path), "--output", str(output_path), "--sha256-only"],
                check=True,
                capture_output=True,
                text=True,
            )
            artifact = output_path.read_bytes()
        self.assertEqual(completed.stdout.strip(), hashlib.sha256(artifact).hexdigest())
        self.assertEqual(artifact, self.audit.canonicalize(evidence))

    def test_cli_rejects_secret_without_creating_output(self):
        with tempfile.TemporaryDirectory() as directory:
            output_path = pathlib.Path(directory) / "audit.json"
            completed = subprocess.run(
                [sys.executable, str(CANONICALIZER), "--output", str(output_path)],
                input=b'{"schema_version":1,"token":"synthetic"}',
                capture_output=True,
            )
            self.assertEqual(completed.returncode, 2)
            self.assertFalse(output_path.exists())
            self.assertIn(b"secret-bearing field is forbidden", completed.stderr)


if __name__ == "__main__":
    unittest.main()
