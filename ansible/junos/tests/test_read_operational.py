import unittest

from scripts.read_operational import newest_commit_record


class NewestCommitRecordTests(unittest.TestCase):
    def test_extracts_newest_record_and_comment(self):
        output = """Commit history:\n0   2026-08-29 by ansible via netconf commit confirmed, rollback in 10mins\n    Ansible candidate abcdef\n1   2026-08-28 by operator via cli\n"""
        self.assertEqual(
            newest_commit_record(output),
            "0   2026-08-29 by ansible via netconf commit confirmed, rollback in 10mins\n"
            "    Ansible candidate abcdef",
        )

    def test_accepts_record_without_comment(self):
        self.assertEqual(
            newest_commit_record("\n0   2026-08-29 by operator via cli\n1 old\n"),
            "0   2026-08-29 by operator via cli",
        )

    def test_rejects_missing_newest_record(self):
        with self.assertRaisesRegex(RuntimeError, "no newest record"):
            newest_commit_record("commit history unavailable")


if __name__ == "__main__":
    unittest.main()
