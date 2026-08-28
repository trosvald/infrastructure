import pathlib
import stat
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]


class NetconfContractTests(unittest.TestCase):
    def read(self, relative):
        return (ROOT / relative).read_text(encoding="utf-8")

    def test_inventory_uses_netconf_connection(self):
        vars_text = self.read("inventory/group_vars/junos/main.yml")
        self.assertIn("ansible_connection: ansible.netcommon.netconf", vars_text)
        self.assertIn("ansible_network_os: juniper.device.junos", vars_text)
        self.assertIn("ansible_host_key_checking: true", vars_text)

    def test_lifecycle_uses_junos_netconf_native_modules(self):
        role = self.read("roles/junos_intent/tasks/main.yml")
        self.assertIn("juniper.device.junos_facts:", role)
        self.assertIn("juniper.device.junos_config:", role)
        self.assertIn("juniper.device.junos_command:", role)
        self.assertIn("src_format: set", role)
        self.assertIn("update: merge", role)
        self.assertIn("check_commit: true", role)
        self.assertIn("confirm:", role)
        self.assertNotIn("juniper.device.facts:", role)
        self.assertNotIn("juniper.device.config:", role)
    def test_read_only_playbooks_use_native_facts_commands(self):
        for relative in (
            "playbooks/verify.yml",
            "playbooks/drift.yml",
            "playbooks/bgp-preflight.yml",
            "playbooks/bgp-verify.yml",
            "playbooks/bgp-acceptance.yml",
        ):
            text = self.read(relative)
            self.assertIn("juniper.device.junos_facts:", text)
            if relative == "playbooks/drift.yml":
                self.assertIn("scripts/read_managed.py", text)
            else:
                self.assertIn("juniper.device.junos_command:", text)
            self.assertNotIn("juniper.device.facts:", text)
            self.assertNotIn("juniper.device.command:", text)
        confirm = self.read("playbooks/confirm.yml")
        self.assertIn("juniper.device.junos_facts:", confirm)
        self.assertIn("juniper.device.junos_config:", confirm)
    def test_deploy_commit_check_runs_in_normal_mode_and_binds_fresh_digest(self):
        role = self.read("roles/junos_intent/tasks/main.yml")
        deploy = self.read("scripts/deploy.sh")
        self.assertIn("junos_intent_fresh_candidate_path", role)
        self.assertIn("junos_intent_fresh_candidate_text | hash('sha256')", role)
        self.assertIn("checksum_algorithm: sha256", role)
        self.assertIn("junos_intent_fresh_candidate_stat.stat.checksum == junos_expected_digest", role)
        self.assertNotIn("check_mode: true", role)
        self.assertIn("check_commit: true", role)
        self.assertIn("check_commit: false", role)
        self.assertIn("confirm: 600", role)
        self.assertIn("ansible.netcommon.netconf_rpc:", role)
        self.assertIn("rpc: discard-changes", role)
        self.assertIn("rstrip=false", role)
        self.assertIn('lines: "{{ junos_intent_fresh_candidate_lines }}"', role)
        self.assertIn('digest="$(sha256_file "$candidate_path")"', deploy)
        self.assertIn('"$emitted_digest" == "$digest"', deploy)
        self.assertIn("ansible-playbook playbooks/verify.yml", deploy)
        self.assertIn("ansible-playbook playbooks/confirm.yml", deploy)
        self.assertIn("JUNOS_CANDIDATE_FILE", deploy)
        self.assertFalse((ROOT / "scripts/verify.sh").exists())

    def test_confirmation_binds_newest_record_and_complete_candidate(self):
        for relative in ("playbooks/verify.yml", "playbooks/confirm.yml"):
            text = self.read(relative)
            self.assertIn("regex_search('(?ms)^\\\\s*0\\\\s+.*?(?=\\\\n\\\\s*[0-9]+\\\\s+|\\\\Z)')", text)
            self.assertIn("Ansible candidate ' ~ junos_expected_digest", text)
            self.assertIn("rstrip=false", text)
            self.assertIn("running_group_lines ==", text)
            self.assertIn("running_apply_lines ==", text)
            self.assertIn("show configuration groups ANSIBLE_SRX1500 | display set", text)
            self.assertIn("show configuration apply-groups | display set", text)
            self.assertIn("running_ordered_lines == ", text)
    def test_bgp_actions_are_secret_suppressed_and_structurally_bounded(self):
        dispatch = self.read("scripts/dispatch.sh")
        runtime = self.read("scripts/with-openbao-runtime.sh")
        for action in ("bgp-preflight", "bgp-verify"):
            self.assertIn(action, dispatch)
            self.assertIn(f"playbooks/{action}.yml", runtime)
            playbook = self.read(f"playbooks/{action}.yml")
            self.assertIn("show bgp summary group CILIUM", playbook)
            self.assertIn("show bgp neighbor 10.25.11.15", playbook)
            self.assertIn("show route protocol bgp", playbook)
            self.assertIn(
                "show route receive-protocol bgp 10.25.11.15",
                playbook,
            )
            self.assertIn("show route 10.25.20.0/24 exact", playbook)
            self.assertIn("no_log: true", playbook)
        self.assertIn("State:\\s+Established", self.read("playbooks/bgp-verify.yml"))
        self.assertIn(
            "State:[ ]+Established",
            self.read("playbooks/bgp-preflight.yml"),
        )


    def test_operational_evidence_is_concrete(self):
        for relative in ("roles/junos_intent/tasks/main.yml", "playbooks/verify.yml", "playbooks/confirm.yml"):
            text = self.read(relative)
            for evidence in (
                "irb[.]2510",
                "irb[.]2512",
                "VLAN-MGMT",
                "VR-XLSATU.inet.0",
                "HOME-TO-XLSATU",
                "MGMT-TO-MYREP",
                "PROD-TO-MYREP",
                "DEV-TO-MYREP",
                "HOME-INTERNET",
                "HOME-BLOCK-MGMT",
            ):
                self.assertIn(evidence, text)

    def test_artifact_ancestor_symlinks_are_rejected_without_following(self):
        toolchain = self.read("scripts/toolchain.sh")
        backup = self.read("scripts/backup.py")
        self.assertIn('[[ -L "$directory" ]]', toolchain)
        self.assertIn("os.lstat(build)", backup)
        self.assertIn("os.O_DIRECTORY", backup)
        self.assertIn("os.O_NOFOLLOW", backup)
        self.assertIn('os.open(output.name, flags, 0o600, dir_fd=backups_fd)', backup)
        self.assertNotIn('chmod 0600 "$output"', self.read("scripts/backup.sh"))

    def test_require_private_dir_rejects_symlink_without_chmod_target(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            target = root / "target"
            target.mkdir()
            target.chmod(0o755)
            link = root / "artifact"
            link.symlink_to(target, target_is_directory=True)
            result = subprocess.run(
                [
                    "bash",
                    "-c",
                    "source \"$1\"; require_private_dir \"$2\"",
                    "_",
                    str(ROOT / "scripts/toolchain.sh"),
                    str(link),
                ],
                capture_output=True,
                text=True,
                check=False,
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(stat.S_IMODE(target.stat().st_mode), 0o755)

    def test_deploy_and_drift_require_committed_adoption(self):
        adoption = self.read("adoption.yml")
        role = self.read("roles/junos_intent/tasks/main.yml")
        drift = self.read("playbooks/drift.yml")
        self.assertIn("adopted: true", adoption)
        self.assertIn("HEAD:ansible/junos/adoption.yml", role)
        self.assertIn("HEAD:ansible/junos/adoption.yml", drift)
        self.assertIn("diff", role)
        self.assertIn("parity migration", drift)

    def test_drift_does_not_persist_whole_configuration(self):
        drift = self.read("playbooks/drift.yml")
        reader = self.read("scripts/read_managed.py")
        self.assertIn("show configuration groups ANSIBLE_SRX1500 | display set", reader)
        self.assertIn("show configuration apply-groups | display set", reader)
        self.assertNotIn("show configuration | display inheritance", drift + reader)
        self.assertNotIn(".drift.set", drift)
        self.assertIn("drift_missing[:50]", drift)
        self.assertIn("drift_extra[:50]", drift)
        self.assertIn("drift_order_mismatch", drift)


if __name__ == "__main__":
    unittest.main()
