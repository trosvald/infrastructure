import json
import os
import pathlib
import socket
import subprocess
import tempfile
import threading
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
RUNTIME = ROOT / "roles/runtime_assets/files"


def executable(path, content):
    path.write_text(content, encoding="utf-8")
    path.chmod(0o755)


class HaproxyRuntimeHelperTests(unittest.TestCase):
    def invoke(self, action):
        with tempfile.TemporaryDirectory() as directory:
            socket_path = pathlib.Path(directory) / "admin.sock"
            ready = threading.Event()
            received = []

            def server():
                with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as listener:
                    listener.bind(str(socket_path))
                    listener.listen(1)
                    ready.set()
                    connection, _ = listener.accept()
                    with connection:
                        data = b""
                        while not data.endswith(b"\n"):
                            data += connection.recv(4096)
                        received.append(data)
                        connection.sendall(b"")

            thread = threading.Thread(target=server, daemon=True)
            thread.start()
            self.assertTrue(ready.wait(2))
            completed = subprocess.run(
                ["python3", str(RUNTIME / "haproxy-runtime-c1-forgejo.py"), action, "--socket", str(socket_path)],
                capture_output=True,
                text=True,
                timeout=5,
            )
            thread.join(2)
        return completed, received

    def test_drain_and_ready_send_only_the_exact_backend_transition(self):
        for action, state in (("drain", "maint"), ("ready", "ready")):
            with self.subTest(action=action):
                completed, received = self.invoke(action)
                self.assertEqual(completed.returncode, 0, completed.stderr)
                self.assertEqual(received, [f"set server forgejo_http/forgejo state {state}\n".encode()])

    def test_unknown_transition_is_rejected_before_socket_access(self):
        completed = subprocess.run(
            ["python3", str(RUNTIME / "haproxy-runtime-c1-forgejo.py"), "restart", "--socket", "/nonexistent"],
            capture_output=True,
            text=True,
            timeout=5,
        )
        self.assertEqual(completed.returncode, 2)
        self.assertIn("invalid choice", completed.stderr)


class OpenBaoTokenGateTests(unittest.TestCase):
    def run_gate(self, payload):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            token_path = root / "token"
            token_path.write_text("synthetic-sensitive-token\n", encoding="utf-8")
            token_path.chmod(0o600)
            fake_bin = root / "bin"
            fake_bin.mkdir()
            executable(fake_bin / "id", "#!/bin/sh\nprintf '0\\n'\n")
            executable(fake_bin / "stat", "#!/bin/sh\nprintf 'root:root:600\\n'\n")
            executable(fake_bin / "curl", "#!/bin/sh\nprintf '%s\\n' \"$SYNTHETIC_RESPONSE\"\n")
            env = os.environ.copy()
            env.update(
                {
                    "PATH": f"{fake_bin}:{env['PATH']}",
                    "TOKEN_FILE": str(token_path),
                    "CURL_BIN": str(fake_bin / "curl"),
                    "PYTHON_BIN": "python3",
                    "OPENBAO_URL": "https://openbao.invalid",
                    "MIN_TTL": "100",
                    "SYNTHETIC_RESPONSE": json.dumps(payload),
                }
            )
            return subprocess.run(
                ["bash", str(RUNTIME / "check-c1-openbao-token")],
                env=env,
                capture_output=True,
                text=True,
                timeout=5,
            )

    def test_renewable_token_above_threshold_passes_without_disclosure(self):
        completed = self.run_gate({"data": {"ttl": 101, "renewable": True}})
        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertIn("ttl=101 renewable=true", completed.stdout)
        self.assertNotIn("synthetic-sensitive-token", completed.stdout + completed.stderr)

    def test_low_ttl_or_nonrenewable_token_fails_closed(self):
        for data in ({"ttl": 100, "renewable": True}, {"ttl": 1000, "renewable": False}):
            with self.subTest(data=data):
                completed = self.run_gate({"data": data})
                self.assertNotEqual(completed.returncode, 0)
                self.assertNotIn("synthetic-sensitive-token", completed.stdout + completed.stderr)


if __name__ == "__main__":
    unittest.main()
