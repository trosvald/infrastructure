import pathlib
import re
import subprocess
import shutil
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
REPO_ROOT = ROOT.parents[1]
ACTIONS = {
    "bootstrap",
    "test",
    "lint",
    "audit",
    "check",
    "diff",
    "deploy",
    "verify",
    "drift",
    "provision-storage",
    "provision-secrets",
    "rotate-secrets",
    "prepare-applications",
    "rollout-applications",
    "activate-network",
    "upgrade",
    "reboot",
}


def read(relative):
    return (ROOT / relative).read_text(encoding="utf-8")


def role_text(role):
    files = sorted((ROOT / "roles" / role).rglob("*"))
    return "\n".join(
        path.read_text(encoding="utf-8", errors="strict")
        for path in files
        if path.is_file() and "__pycache__" not in path.parts
    )


class ProjectBoundaryTests(unittest.TestCase):
    def test_inventory_and_adoption_schema_are_complete_for_exact_hosts(self):
        inventory = read("inventory/hosts.yml")
        self.assertRegex(inventory, r"(?m)^container_nodes:\s*$")
        hosts = re.findall(r"(?m)^    (c[01]):\s*$", inventory)
        self.assertEqual(hosts, ["c1", "c0"], "serial actions must converge c1 before c0")

        adoption = read("adoption.yml")
        self.assertRegex(adoption, r"(?m)^container_nodes_adoption_schema_version: 1$")
        self.assertEqual(re.findall(r"(?m)^  (c[01]):$", adoption), ["c0", "c1"])
        for host in ("c0", "c1"):
            block = re.search(rf"(?ms)^  {host}:\n(?P<body>(?:    .+\n)+)", adoption)
            self.assertIsNotNone(block)
            body = block.group("body")
            self.assertRegex(body, r"(?m)^    adopted: (?:true|false)$")
            self.assertRegex(body, r"(?m)^    contract_version: [1-9][0-9]*$")
            self.assertRegex(body, r"(?m)^    audit_schema_version: [1-9][0-9]*$")
            self.assertRegex(body, r"(?m)^    audit_sha256: (?:null|[0-9a-f]{64})$")

    def test_host_vars_supply_mandatory_verification_schema(self):
        required = (
            "container_node_verification_host_units",
            "container_node_verification_host_paths",
            "container_node_verification_docker_networks",
            "container_node_verification_application_containers",
            "container_node_verification_application_health_checks",
        )
        for host in ("c0", "c1"):
            text = read(f"inventory/host_vars/{host}/main.yml")
            with self.subTest(host=host):
                self.assertIn(f"container_node_hostname: {host}", text)
                for variable in required:
                    self.assertRegex(text, rf"(?m)^{re.escape(variable)}:\s*$")

    def test_forgejo_admin_schema_has_no_persistent_bootstrap_projection(self):
        c1_vars = read("inventory/host_vars/c1/main.yml")
        runtime_defaults = read("roles/runtime_assets/defaults/main.yml")
        for text in (c1_vars, runtime_defaults):
            self.assertIn("admin_password", text)
            self.assertIn("admin_email", text)
            self.assertNotIn("bootstrap_admin_password", text)
            self.assertNotIn("bootstrap_admin_email", text)

        forgejo_project = REPO_ROOT / "docker/c1/forgejo"
        legacy_paths = (
            "/run/secrets/bootstrap_admin_password",
            "/run/secrets/bootstrap_admin_email",
            "/srv/applications/apps/forgejo/secrets/bootstrap_admin_password",
            "/srv/applications/apps/forgejo/secrets/bootstrap_admin_email",
        )
        project_text = "\n".join(
            path.read_text(encoding="utf-8")
            for path in forgejo_project.rglob("*")
            if path.is_file()
            and "__pycache__" not in path.parts
            and "tests" not in path.parts
        )
        for legacy_path in legacy_paths:
            self.assertNotIn(legacy_path, project_text)

        removal = read("roles/runtime_assets/tasks/forgejo-admin.yml")
        bootstrap_lines = [
            line.strip() for line in removal.splitlines() if "bootstrap_admin_" in line
        ]
        self.assertEqual(
            bootstrap_lines,
            [
                "- /srv/applications/apps/forgejo/secrets/bootstrap_admin_password",
                "- /srv/applications/apps/forgejo/secrets/bootstrap_admin_email",
                "- /opt/forgejo/secrets/bootstrap_admin_password",
                "- /opt/forgejo/secrets/bootstrap_admin_email",
            ],
        )

    def test_dispatcher_rejects_unknown_actions_and_trailing_arguments(self):
        dispatcher = ROOT / "scripts/dispatch.sh"
        text = dispatcher.read_text(encoding="utf-8")
        dispatched_actions = set(re.findall(r"(?m)^  ([a-z][a-z-]+)\)", text))
        self.assertEqual(dispatched_actions, ACTIONS)
        with tempfile.TemporaryDirectory() as directory:
            project = pathlib.Path(directory)
            (project / "scripts").mkdir()
            for name in ("dispatch.sh", "toolchain.sh"):
                shutil.copy2(ROOT / "scripts" / name, project / "scripts" / name)
            isolated_dispatcher = project / "scripts/dispatch.sh"
            for argv in (("not-an-action",), ("audit", "c0"), ("deploy", "--check")):
                with self.subTest(argv=argv):
                    completed = subprocess.run(
                        ["bash", str(isolated_dispatcher), *argv],
                        cwd=project,
                        env={"PATH": "/usr/bin:/bin"},
                        capture_output=True,
                        text=True,
                        timeout=5,
                    )
                    self.assertNotEqual(completed.returncode, 0)
                    self.assertRegex(completed.stderr + completed.stdout, r"(?i)(unknown|usage|argument|action|reject)")

    def test_every_live_play_is_serial_and_fail_fast(self):
        playbooks = sorted((ROOT / "playbooks").glob("*.yml"))
        self.assertTrue(playbooks)
        for path in playbooks:
            text = path.read_text(encoding="utf-8")
            with self.subTest(playbook=path.name):
                play_count = len(re.findall(r"(?m)^- name:", text))
                self.assertGreater(play_count, 0)
                self.assertEqual(len(re.findall(r"(?m)^  serial:\s*1\s*$", text)), play_count)
                self.assertEqual(
                    len(re.findall(r"(?m)^  any_errors_fatal:\s*true\s*$", text)),
                    play_count,
                )

    def test_deploy_binds_adoption_to_fresh_audit_digest(self):
        deploy = read("playbooks/deploy.yml")
        gate = read("tasks/require-adoption.yml")
        combined = deploy + gate
        self.assertIn("include_tasks: ../tasks/require-adoption.yml", deploy)
        for token in (
            "container_nodes_adoption",
            "adopted",
            "contract_version",
            "audit_schema_version",
            "audit_sha256",
            "container_node_audit_sha256",
        ):
            self.assertIn(token, combined)
        self.assertGreaterEqual(gate.count("match('^[0-9a-f]{64}$')"), 2)
        self.assertRegex(gate, r"(?s)assert:.*container_node_audit_sha256.*audit_sha256")


class OwnershipSafetyTests(unittest.TestCase):
    def test_no_role_performs_direct_application_compose_or_stack_reconcile(self):
        compose_lifecycle = re.compile(
            r"(?i)docker\s+compose\s+(?:up|down|start|stop|create|rm)"
        )
        reconcile = re.compile(r"(?i)/(?:api/)?stacks?/.{0,100}/reconcile")
        for path in sorted((ROOT / "roles").rglob("*")):
            if (
                not path.is_file()
                or "tests" in path.parts
                or "__pycache__" in path.parts
            ):
                continue
            text = path.read_text(encoding="utf-8", errors="strict")
            with self.subTest(path=path.relative_to(ROOT), pattern=reconcile.pattern):
                self.assertIsNone(reconcile.search(text))
            if "doco_controller" not in path.parts:
                with self.subTest(path=path.relative_to(ROOT), pattern=compose_lifecycle.pattern):
                    self.assertIsNone(compose_lifecycle.search(text))

    def test_runtime_lifecycle_uses_authenticated_project_start_stop_only(self):
        lifecycle = read("roles/doco_controller/files/doco_project_lifecycle.py")
        unit = read("roles/doco_controller/templates/doco-project.service.j2")
        combined = lifecycle + unit
        self.assertRegex(combined, r"(?i)(?:/projects?/|project).*(?:start|stop)")
        self.assertNotRegex(combined, r"(?i)reconcile")
        self.assertNotRegex(combined, r"(?i)docker\s+compose")
        self.assertRegex(combined, r"(?i)(authorization|bearer|api[_ -]?secret)")

    def test_network_and_routine_storage_roles_have_no_destructive_disk_operations(self):
        destructive = re.compile(r"(?i)(?:\bmkfs(?:\.|\s)|\bparted\b|\bsfdisk\b|\bwipefs\b|\bsgdisk\b|docker\s+network\s+(?:rm|prune))")
        for role in ("network", "storage"):
            main = ROOT / "roles" / role / "tasks" / "main.yml"
            with self.subTest(role=role):
                self.assertTrue(main.exists())
                self.assertIsNone(destructive.search(main.read_text(encoding="utf-8")))
        provision = read("playbooks/provision-storage.yml")
        self.assertRegex(provision, r"(?i)(typed|approval)")
        self.assertRegex(provision, r"(?i)(digest|sha256)")
        network_role = role_text("network")
        self.assertNotRegex(network_role, r"(?i)docker\s+network\s+(?:rm|prune)")
        c0_services = read("roles/network/files/assert-c0-services-network")
        self.assertNotRegex(c0_services, r"(?i)docker\s+network\s+(?:create|rm|prune)")

    def test_critical_drift_is_asserted_not_reconciled(self):
        critical_roles = ("access", "network", "storage", "firewall", "doco_controller")
        for role in critical_roles:
            text = role_text(role)
            with self.subTest(role=role):
                self.assertRegex(
                    text,
                    r"(?s)(ansible\.builtin\.(?:assert|fail):|ERROR:.{0,500}exit 1|exit 1.{0,500}ERROR:)",
                )
                self.assertRegex(text, r"(?i)(critical drift|refus|mismatch|must match|fail_msg|ERROR:)")

    def test_secret_actions_are_redacted_and_isolated_from_deploy(self):
        runtime_transactions = role_text("runtime_assets")
        for name in ("provision-secrets.yml", "rotate-secrets.yml"):
            playbook = read(f"playbooks/{name}")
            combined = playbook + runtime_transactions
            with self.subTest(playbook=name):
                self.assertIn("no_log: true", combined)
                self.assertIn("diff: false", combined)
                self.assertRegex(combined, r"(?i)(always:|cleanup|state:\s*absent)")
        deploy = read("playbooks/deploy.yml")
        self.assertNotRegex(deploy, r"(?i)(provision|rotate).{0,40}secret")
        self.assertNotRegex(deploy, r"(?i)lookup\([^\n]*(?:sops|vault|bao)")

    def test_verification_role_is_read_only_and_layers_are_explicit(self):
        main = read("roles/verification/tasks/main.yml")
        applications = read("roles/verification/tasks/applications.yml")
        openbao = read("roles/verification/tasks/openbao.yml")
        verify_play = read("playbooks/verify.yml")
        self.assertNotIn("applications.yml", main)
        self.assertNotIn("openbao.yml", main)
        self.assertIn("tasks_from: applications.yml", verify_play)
        self.assertIn("tasks_from: openbao.yml", verify_play)
        self.assertIn("container_nodes_verify_scope", verify_play)
        self.assertIn("RestartPolicy.Name == 'no'", applications)
        self.assertIn("State.Health.Status", applications)
        self.assertIn("seal-status", openbao)
        self.assertIn("no_log: true", openbao)
        combined = main + applications + openbao
        for mutation in (
            "state: restarted",
            "ansible.builtin.copy:",
            "ansible.builtin.template:",
            "ansible.builtin.file:",
            "community.docker.docker_compose",
        ):
            with self.subTest(mutation=mutation):
                self.assertNotIn(mutation, combined)


if __name__ == "__main__":
    unittest.main()
