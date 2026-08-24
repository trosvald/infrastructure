import importlib.util
import json
import pathlib
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("junos_intent", ROOT / "scripts/junos_intent.py")
if spec is None:
    raise RuntimeError("unable to load Junos intent module")
module = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(module)


class IntentTests(unittest.TestCase):
    def build(self):
        return module.build(
            ROOT / "host_vars/srx1500/intent",
            ROOT / "tests/topology.yml",
        )[0]

    def test_deterministic_and_group_owned(self):
        first, second = self.build(), self.build()
        self.assertEqual(first, second)
        self.assertEqual(first[0], "delete groups ANSIBLE_SRX1500")
        self.assertEqual(first[-1], "set apply-groups ANSIBLE_SRX1500")
        prefixes = ("delete groups ", "set groups ", "set apply-groups ")
        self.assertTrue(all(command.startswith(prefixes) for command in first))

    def test_no_duplicates_and_quotes_descriptions(self):
        commands = self.build()
        self.assertEqual(len(commands), len(set(commands)))
        self.assertTrue(any('description "Management VLAN"' in x for x in commands))

    def test_order_sensitive_policy_terms(self):
        commands = self.build()
        home = next(i for i, x in enumerate(commands) if "IMPORT-HOME-INTO-MASTER term HOME then accept" in x)
        reject = next(
            index
            for index, command in enumerate(commands)
            if "IMPORT-HOME-INTO-MASTER term REJECT-REST then reject" in command
        )
        self.assertLess(home, reject)

    def test_reservation_must_be_in_subnet(self):
        topology = module.load_yaml(ROOT / "tests/topology.yml")
        topology["reservations"]["mgmt"] = [
            {
                "name": "bad",
                "mac": "02:00:00:00:00:aa",
                "ip": "203.0.113.200",
            }
        ]
        with tempfile.NamedTemporaryFile(mode="w", suffix=".yml") as file:
            json.dump(topology, file)
            file.flush()
            with self.assertRaisesRegex(module.IntentError, "outside"):
                module.build(ROOT / "host_vars/srx1500/intent", pathlib.Path(file.name))

    def test_password_hashes_never_render(self):
        rendered = "\n".join(self.build())
        self.assertNotIn("authentication encrypted-password", rendered)
        self.assertNotIn("root-authentication", rendered)


if __name__ == "__main__":
    unittest.main()
