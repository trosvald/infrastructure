import pathlib
import subprocess
import sys
import tempfile
import unittest

from scripts.deploy_lock import (
    CONTENTION_MESSAGE,
    DeploymentLockError,
    deployment_lock,
)


CHILD = """
import pathlib
import sys
from scripts.deploy_lock import DeploymentLockError, deployment_lock
try:
    with deployment_lock(pathlib.Path(sys.argv[1])):
        pass
except DeploymentLockError as error:
    print(error, file=sys.stderr)
    raise SystemExit(1)
"""
ROOT = pathlib.Path(__file__).resolve().parents[1]


class DeploymentLockTests(unittest.TestCase):
    def test_contention_fails_immediately_then_acquisition_succeeds(self):
        with tempfile.TemporaryDirectory() as temporary:
            build = pathlib.Path(temporary) / ".build"
            build.mkdir(mode=0o700)
            lock_path = build / "srx1500.deploy.lock"
            with deployment_lock(lock_path):
                contended = self.run_child(lock_path)
            self.assertEqual(contended.returncode, 1)
            self.assertEqual(contended.stderr.strip(), CONTENTION_MESSAGE)

            acquired = self.run_child(lock_path)
            self.assertEqual(acquired.returncode, 0, acquired.stderr)

    def test_symlink_lock_file_is_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            build = pathlib.Path(temporary) / ".build"
            build.mkdir(mode=0o700)
            target = build / "target"
            target.touch(mode=0o600)
            lock_path = build / "srx1500.deploy.lock"
            lock_path.symlink_to(target)
            with self.assertRaises(DeploymentLockError):
                with deployment_lock(lock_path):
                    self.fail("unsafe symlink lock was acquired")

    def test_unsafe_mode_lock_file_is_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            build = pathlib.Path(temporary) / ".build"
            build.mkdir(mode=0o700)
            lock_path = build / "srx1500.deploy.lock"
            lock_path.touch(mode=0o644)
            with self.assertRaisesRegex(DeploymentLockError, "regular 0600 file"):
                with deployment_lock(lock_path):
                    self.fail("unsafe mode lock was acquired")

    def run_child(self, lock_path):
        return subprocess.run(
            [sys.executable, "-c", CHILD, str(lock_path)],
            cwd=ROOT,
            capture_output=True,
            text=True,
            check=False,
            timeout=5,
        )


if __name__ == "__main__":
    unittest.main()
