import json
import tempfile
import unittest
from pathlib import Path

from scripts.myrep_preflight import expected_address


class MyrepPreflightTests(unittest.TestCase):
    def topology(self, cidr):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        path = Path(temporary.name) / "topology.json"
        path.write_text(
            json.dumps({"wan": {"secondary_public_cidr": cidr}}),
            encoding="utf-8",
        )
        return str(path)

    def test_requires_exact_global_non_cgnat_address(self):
        self.assertEqual(str(expected_address(self.topology("8.8.8.8/32"))), "8.8.8.8")
        cases = (
            "8.8.8.0/24",
            "10.0.0.1/32",
            "100.64.0.1/32",
            "2001:4860:4860::8888/128",
        )
        for cidr in cases:
            with self.subTest(cidr=cidr), self.assertRaisesRegex(
                RuntimeError,
                "IPv4 /32|globally routable",
            ):
                expected_address(self.topology(cidr))



if __name__ == "__main__":
    unittest.main()
