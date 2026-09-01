import os
import pathlib
import re
import stat
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]

REPO_ROOT = ROOT.parents[1]

class NetconfContractTests(unittest.TestCase):
    def read(self, relative):
        return (ROOT / relative).read_text(encoding="utf-8")

    def test_inventory_uses_netconf_connection(self):
        config_text = self.read("ansible.cfg")
        vars_text = self.read("inventory/group_vars/junos/main.yml")
        self.assertIn("ansible_connection: ansible.netcommon.netconf", vars_text)
        self.assertIn("ansible_network_os: juniper.device.junos", vars_text)
        self.assertIn("ansible_host_key_checking: true", vars_text)
        self.assertIn("[paramiko_connection]", config_text)
        self.assertIn("look_for_keys = False", config_text)
        self.assertNotIn("ansible_paramiko_look_for_keys", vars_text)
        for relative in ("scripts/read_managed.py", "scripts/backup.py"):
            caller = self.read(relative)
            self.assertIn("look_for_keys=False", caller)
            self.assertIn("allow_agent=False", caller)
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
        literal_reader = self.read("scripts/read_operational.py")
        for relative in (
            "playbooks/verify.yml",
            "playbooks/drift.yml",
            "playbooks/operational-verify.yml",
            "playbooks/bgp-preflight.yml",
            "playbooks/bgp-verify.yml",
            "playbooks/bgp-acceptance.yml",
        ):
            text = self.read(relative)
            self.assertIn("juniper.device.junos_facts:", text)
            if relative == "playbooks/drift.yml":
                self.assertIn("scripts/read_managed.py", text)
            elif relative in (
                "playbooks/verify.yml",
                "playbooks/operational-verify.yml",
                "playbooks/bgp-verify.yml",
            ):
                self.assertIn("scripts/read_operational.py", text)
            else:
                self.assertIn("juniper.device.junos_command:", text)
            self.assertNotIn("juniper.device.facts:", text)
            self.assertNotIn("juniper.device.command:", text)
        self.assertIn("device.cli(command, warning=False)", literal_reader)
        confirm = self.read("playbooks/confirm.yml")
        self.assertIn("juniper.device.junos_facts:", confirm)
        self.assertIn("scripts/confirm_commit.py", confirm)
        self.assertIn("scripts/read_operational.py", confirm)
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
        self.assertIn("confirm: 10", role)
        self.assertIn("ansible.netcommon.netconf_rpc:", role)
        self.assertIn("rpc: discard-changes", role)
        self.assertIn("rstrip=false", role)
        self.assertIn('lines: "{{ junos_intent_fresh_candidate_lines }}"', role)
        self.assertIn('digest="$(sha256_file "$candidate_path")"', deploy)
        self.assertIn('"$emitted_digest" == "$digest"', deploy)
        self.assertIn(
            '\\"junos_intent_commit_comment\\":\\"Ansible candidate $digest\\"',
            deploy,
        )
        confirm_pending = self.read("scripts/confirm-pending.sh")
        self.assertIn("confirm-pending $digest", confirm_pending)
        self.assertIn("playbooks/confirm.yml", confirm_pending)
        self.assertIn('\\"junos_commit_comment\\":\\"Ansible candidate $digest\\"', confirm_pending)
        self.assertIn("scripts/confirm-pending.sh", self.read("scripts/dispatch.sh"))
        self.assertIn("scripts/confirm-pending.sh", self.read("scripts/with-openbao-runtime.sh"))
        self.assertIn("ansible-playbook playbooks/verify.yml", deploy)
        self.assertIn("ansible-playbook playbooks/confirm.yml", deploy)
        self.assertIn("JUNOS_CANDIDATE_FILE", deploy)
        self.assertFalse((ROOT / "scripts/verify.sh").exists())

    def test_deploy_serializes_and_rejects_preexisting_transactions(self):
        deploy = self.read("scripts/deploy.sh")
        runtime = self.read("scripts/with-openbao-runtime.sh")
        role = self.read("roles/junos_intent/tasks/main.yml")
        self.assertIn('JUNOS_DEPLOY_LOCK_HELD:-}" != "1"', deploy)
        self.assertIn("exec python scripts/deploy_lock.py", deploy)
        self.assertIn("unset JUNOS_DEPLOY_LOCK_HELD", deploy)
        self.assertIn("unset SSH_AUTH_SOCK JUNOS_DEPLOY_LOCK_HELD", runtime)
        self.assertIn("show system commit", role)
        self.assertIn("junos_intent_preflight_commit_record", role)
        self.assertIn(
            "A pending confirmed commit already exists; wait for rollback or confirm it "
            "through its originating reviewed transaction before deploying.",
            role,
        )

    def test_deploy_handles_changed_and_converged_candidates(self):
        role = self.read("roles/junos_intent/tasks/main.yml")
        deploy = self.read("scripts/deploy.sh")
        self.assertGreaterEqual(
            role.count(
                "junos_intent_candidate_result.changed | default(false) | bool"
            ),
            4,
        )
        self.assertIn(
            "Require the exact managed candidate and common operational evidence",
            role,
        )
        self.assertIn(
            "Require the newest pending commit record for a changed candidate",
            role,
        )
        self.assertIn("junos_intent_deploy_state_file", role)
        self.assertIn("Detect a fully converged candidate before loading secrets", role)
        self.assertIn("junos_intent_candidate_converged", role)
        self.assertIn("junos_intent_runtime_dir ~ '/junos/deploy-state'", role)
        self.assertIn("{{ 'pending' if", role)
        self.assertIn("else 'converged' }}", role)
        self.assertIn('export JUNOS_DEPLOY_STATE_FILE="$state_file"', deploy)
        self.assertIn('"converged $digest"', deploy)
        self.assertIn('"pending $digest"', deploy)
        self.assertIn(
            "Candidate already converged and operationally verified: $digest",
            deploy,
        )

    def test_confirmation_binds_newest_record_and_complete_candidate(self):
        reader = self.read("scripts/read_operational.py")
        self.assertIn("show configuration groups ANSIBLE_SRX1500 | display set | no-more", reader)
        self.assertIn("show configuration apply-groups | display set | no-more", reader)
        self.assertIn(
            "show configuration security policies | display inheritance no-comments "
            "| display set | no-more",
            reader,
        )
        self.assertIn('"postcommit": POSTCOMMIT_COMMANDS', reader)
        self.assertIn("newest_commit_record", reader)
        self.assertIn("output[0] = newest_commit_record(output[0])", reader)
        for relative in ("playbooks/verify.yml", "playbooks/confirm.yml"):
            text = self.read(relative)
            self.assertIn("stdout[0] | default('')", text)
            self.assertIn("Ansible candidate ' ~ junos_expected_digest", text)
            self.assertIn("rstrip=false", text)
            self.assertIn("running_group_lines ==", text)
            self.assertIn("running_apply_lines ==", text)
            self.assertIn("scripts/read_operational.py", text)
            self.assertIn("running_order.stdout | from_json", text)
            self.assertIn("Read managed-group exclusions with a bounded NETCONF XPath", text)
            self.assertIn('<filter type="xpath" select="', text)
            self.assertIn("local-name()='apply-groups-except'", text)
            self.assertIn("stdout | length == 13", text)
            self.assertIn("stdout is not search('apply-groups-except')", text)
            self.assertIn("VECTOR-SRX-ROOT ca-identity VECTOR-SRX-ROOT", text)
        role = self.read("roles/junos_intent/tasks/main.yml")
        self.assertIn("scripts/read_operational.py", role)
        self.assertNotIn(
            "show configuration groups ANSIBLE_SRX1500 | display set",
            role,
        )

    def test_bgp_verification_uses_fixed_literal_cli_reader(self):
        playbook = self.read("playbooks/bgp-verify.yml")
        reader = self.read("scripts/read_operational.py")
        self.assertIn("scripts/read_operational.py", playbook)
        self.assertIn("- bgp-verify", playbook)
        self.assertIn('"bgp-verify": BGP_VERIFY_COMMANDS', reader)
        self.assertIn("if len(sys.argv) != 2 or sys.argv[1] not in MODES", reader)
        self.assertIn("device.cli(command, warning=False)", reader)
        self.assertNotIn("juniper.device.junos_command:", playbook)

    def test_controller_python_is_reached_only_through_just_and_ansible(self):
        dispatch = self.read("scripts/dispatch.sh")
        runtime = self.read("scripts/with-openbao-runtime.sh")
        playbook = self.read("playbooks/operational-verify.yml")
        self.assertIn("operational-verify)", dispatch)
        self.assertIn("playbooks/operational-verify.yml", dispatch)
        self.assertIn("playbooks/operational-verify.yml", runtime)
        self.assertIn("{{ ansible_playbook_python }}", playbook)
        self.assertNotIn("jnpr.junos", playbook)
        forbidden = "/.local/share/mise/" + "installs/"
        paths = [
            *(ROOT / "scripts").glob("*.sh"),
            *(ROOT / "scripts").glob("*.py"),
            *(ROOT / "playbooks").glob("*.yml"),
            *(ROOT / "roles").rglob("*.yml"),
            REPO_ROOT / "ansible" / "mod.just",
        ]
        for path in paths:
            self.assertNotIn(forbidden, path.read_text(encoding="utf-8"), str(path))

    def test_openbao_runtime_allowlist_boundaries(self):
        shared_runtime = REPO_ROOT / "scripts/with-openbao-runtime.sh"
        junos_runtime = ROOT / "scripts/with-openbao-runtime.sh"
        syntax = subprocess.run(
            ["bash", "-n", str(shared_runtime), str(junos_runtime)],
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertEqual(syntax.returncode, 0, syntax.stderr)

        environment = os.environ.copy()
        for name in (
            "BAO_TOKEN",
            "VAULT_TOKEN",
            "BAO_SKIP_VERIFY",
            "VAULT_SKIP_VERIFY",
            "BAO_TLS_SERVER_NAME",
            "VAULT_TLS_SERVER_NAME",
        ):
            environment.pop(name, None)
        no_arguments = subprocess.run(
            ["bash", str(shared_runtime)],
            cwd=REPO_ROOT,
            env=environment,
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertEqual(no_arguments.returncode, 2)
        self.assertIn(
            "usage: with-openbao-runtime.sh command [args...]",
            no_arguments.stderr,
        )
        unapproved = subprocess.run(
            ["bash", str(shared_runtime), "true"],
            cwd=REPO_ROOT,
            env=environment,
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertEqual(unapproved.returncode, 2)
        self.assertIn(
            "OpenBao runtime received an unapproved action",
            unapproved.stderr,
        )

    def test_bgp_actions_are_secret_suppressed_and_structurally_bounded(self):
        dispatch = self.read("scripts/dispatch.sh")
        runtime = self.read("scripts/with-openbao-runtime.sh")
        literal_reader = self.read("scripts/read_operational.py")
        for action in ("bgp-preflight", "bgp-verify"):
            self.assertIn(action, dispatch)
            self.assertIn(f"playbooks/{action}.yml", runtime)
            playbook = self.read(f"playbooks/{action}.yml")
            evidence_source = literal_reader if action == "bgp-verify" else playbook
            self.assertIn("show bgp summary group CILIUM", evidence_source)
            self.assertIn(
                "show bgp neighbor {peer}"
                if action == "bgp-verify"
                else "show bgp neighbor 10.25.11.15",
                evidence_source,
            )
            self.assertIn("show route protocol bgp", evidence_source)
            self.assertIn(
                "show route receive-protocol bgp {peer}"
                if action == "bgp-verify"
                else "show route receive-protocol bgp 10.25.11.15",
                evidence_source,
            )
            self.assertIn("show route 10.25.20.0/24 exact", evidence_source)
            self.assertIn("no_log: true", playbook)
        self.assertIn("State:\\s+Established", self.read("playbooks/bgp-verify.yml"))
        self.assertIn(
            "State: Established",
            self.read("playbooks/bgp-preflight.yml"),
        )
    def test_bgp_peer_as_matches_multiline_display_set_output(self):
        pattern = (
            r"(?m)^set groups ANSIBLE_SRX1500 protocols bgp group CILIUM "
            r"peer-as 64513$"
        )
        playbook = self.read("playbooks/bgp-verify.yml")
        self.assertIn(pattern, playbook)
        display_set = (
            "set groups ANSIBLE_SRX1500 protocols bgp group CILIUM peer-as 64513\n"
            "set groups ANSIBLE_SRX1500 protocols bgp group CILIUM neighbor "
            "10.25.11.11\n"
        )
        self.assertIsNotNone(re.search(pattern, display_set))
        self.assertIsNone(re.search(pattern, display_set.replace("64513", "64514")))



    def test_syslog_verification_is_fixed_and_secret_suppressed(self):
        dispatch = self.read("scripts/dispatch.sh")
        runtime = self.read("scripts/with-openbao-runtime.sh")
        reader = self.read("scripts/read_operational.py")
        playbook = self.read("playbooks/syslog-verify.yml")
        self.assertIn("syslog-verify", dispatch)
        self.assertIn("playbooks/syslog-verify.yml", runtime)
        self.assertIn('"syslog-verify": SYSLOG_VERIFY_COMMANDS', reader)
        self.assertNotIn("show security log stream", reader)
        self.assertIn("show security pki ca-certificate ca-profile VECTOR-SRX-ROOT", reader)
        self.assertIn("show system connections | match 6514", reader)
        installer = self.read("scripts/bootstrap_vector_ca.py")
        self.assertIn("no_log: true", playbook)
        self.assertIn("hostkey_verify=True", installer)
        self.assertIn("VECTOR-SRX-ROOT", installer)
        self.assertIn('"playbooks/syslog-verify.yml" ) ]]; then', runtime)
        self.assertIn("pki-bootstrap", dispatch)

    def test_operational_evidence_is_concrete(self):
        literal_reader = self.read("scripts/read_operational.py")
        for relative in ("roles/junos_intent/tasks/main.yml", "playbooks/verify.yml", "playbooks/confirm.yml"):
            text = self.read(relative) + literal_reader
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

    def test_deploy_requires_committed_true_adoption(self):
        adoption = self.read("adoption.yml")
        role = self.read("roles/junos_intent/tasks/main.yml")
        self.assertIn("adopted: true", adoption)
        self.assertIn("HEAD:ansible/junos/adoption.yml", role)
        self.assertIn("adopted | default(false) | bool", role)
        self.assertIn("junos_intent_operation == 'deploy'", role)

    def test_drift_accepts_and_reports_exact_committed_adoption_boolean(self):
        drift = self.read("playbooks/drift.yml")
        self.assertIn("HEAD:ansible/junos/adoption.yml", drift)
        self.assertIn("drift_adoption_record.adopted | type_debug == 'bool'", drift)
        self.assertIn("drift_adopted: \"{{ drift_adoption_record.adopted }}\"", drift)
        self.assertIn("adopted: {{ drift_adopted | bool | lower }}", drift)
        self.assertNotIn("Require completed adoption from committed Git content", drift)

    def test_direct_reservation_conflicts_are_bounded_and_block_transactions(self):
        reader = self.read("scripts/read_managed.py")
        drift = self.read("playbooks/drift.yml")
        role = self.read("roles/junos_intent/tasks/main.yml")
        for command in (
            "show configuration access address-assignment pool MGMT",
            "show configuration access address-assignment pool PROD",
            "show configuration access address-assignment pool DEV",
            "show configuration routing-instances VR-XLSATU access address-assignment ",
            "pool HOME | display set | no-more",
        ):
            self.assertIn(command, reader)
        self.assertNotIn("DIRECT_RESERVATION_XPATH", reader)
        for text in (
            role,
            self.read("playbooks/verify.yml"),
            self.read("playbooks/confirm.yml"),
        ):
            self.assertIn("scripts/read_managed.py", text)
            self.assertIn("direct_reservation_paths is defined", text)
            self.assertIn("direct_reservation_paths == []", text)
        self.assertIn('"direct_reservation_paths": direct_reservation_paths', reader)
        self.assertIn(
            "drift_managed_configuration.direct_reservation_paths | type_debug == 'list'",
            drift,
        )
        self.assertIn("direct_reservation_count:", drift)
        self.assertIn("direct_reservation_paths:", drift)
        self.assertLess(
            role.index("Reject direct DHCP reservation ownership conflicts"),
            role.index("Load candidate and run commit-check without activation"),
        )
        self.assertIn("when: junos_intent_operation == 'deploy'", role)
        self.assertIn("Reject direct DHCP reservation ownership conflicts", role)
        self.assertIn(
            "Reject direct DHCP reservation ownership conflicts",
            self.read("playbooks/verify.yml"),
        )
        self.assertIn(
            "Reject direct DHCP reservation ownership conflicts before confirmation",
            self.read("playbooks/confirm.yml"),
        )

    def test_drift_does_not_persist_whole_configuration(self):
        drift = self.read("playbooks/drift.yml")
        reader = self.read("scripts/read_managed.py")
        self.assertIn("show configuration groups ANSIBLE_SRX1500 | display set", reader)
        self.assertIn("show configuration apply-groups | display set", reader)
        self.assertIn("device._conn.get_config(", reader)
        self.assertIn('"xpath",', reader)
        self.assertIn(
            "drift_managed_configuration.apply_groups_exceptions == []",
            drift,
        )
        self.assertNotIn("show configuration | display inheritance", drift + reader)
        self.assertNotIn(".drift.set", drift)
        self.assertIn("drift_missing[:50]", drift)
        self.assertIn("drift_extra[:50]", drift)
        self.assertIn("drift_order_mismatch", drift)


if __name__ == "__main__":
    unittest.main()
