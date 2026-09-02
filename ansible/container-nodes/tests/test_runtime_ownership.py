import pathlib
import re
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
REPO_ROOT = ROOT.parents[1]


def compose_service_blocks(text):
    lines = text.splitlines()
    services_line = next((index for index, line in enumerate(lines) if line == "services:"), None)
    if services_line is None:
        return {}
    starts = []
    for index in range(services_line + 1, len(lines)):
        line = lines[index]
        if line and not line.startswith(" "):
            break
        match = re.match(r"^  ([A-Za-z0-9_.-]+):(?:\s*(?:&\S+)?)?\s*$", line)
        if match:
            starts.append((index, match.group(1)))
    blocks = {}
    for offset, (start, name) in enumerate(starts):
        end = starts[offset + 1][0] if offset + 1 < len(starts) else len(lines)
        blocks[name] = "\n".join(lines[start:end])
    return blocks


class ComposeOwnershipTests(unittest.TestCase):
    def test_every_doco_and_application_service_has_explicit_restart_policy_no(self):
        compose_files = []
        for host in (REPO_ROOT / "docker/c0", REPO_ROOT / "docker/c1"):
            for path in host.rglob("*.yml"):
                if path.name in {"compose.yml", "docker-compose.yml"} or "docker-compose.app" in path.name:
                    compose_files.append(path)
            for path in host.rglob("*.yaml"):
                if path.name in {"compose.yaml", "docker-compose.yaml"} or "docker-compose.app" in path.name:
                    compose_files.append(path)
        self.assertTrue(compose_files)
        for path in sorted(set(compose_files)):
            blocks = compose_service_blocks(path.read_text(encoding="utf-8"))
            self.assertTrue(blocks, path)
            for service, block in blocks.items():
                with self.subTest(compose=path.relative_to(REPO_ROOT), service=service):
                    restart = re.findall(r"(?m)^    restart:\s*['\"]?([^'\"#\s]+)", block)
                    self.assertEqual(restart, ["no"])


class SystemdOwnershipTests(unittest.TestCase):
    REQUIRED_UNITS = {
        "c1-forgejo-egress.service",
        "c1-applications-storage.service",
        "c1-librefs-storage.service",
        "c1-forgejo-quotas.service",
        "c1-edge-state.service",
        "c0-wildcard-certificate.service",
        "c0-wildcard-certificate.timer",
        "c1-wildcard-certificate.service",
        "c1-wildcard-certificate.timer",
        "doco-c1-openbao-token.service",
        "doco-c1-openbao-renew.service",
        "doco-c1-openbao-renew.timer",
        "forgejo-backup.service",
        "forgejo-backup.timer",
    }

    @classmethod
    def unit_assets(cls):
        units = {}
        for path in (ROOT / "roles").rglob("*"):
            if not path.is_file():
                continue
            name = path.name.removesuffix(".j2")
            if pathlib.Path(name).suffix in {".service", ".timer"}:
                units[name] = path
        return units

    def test_all_resident_unit_families_moved_under_ansible_roles(self):
        units = self.unit_assets()
        self.assertEqual(self.REQUIRED_UNITS - units.keys(), set())

    def test_generated_network_unit_families_are_exact_and_ordered(self):
        expected = {
            "c0-services-prerequisite.service",
            "c0-omada-network.service",
            "c1-services-shim.service",
            "c1-services-network.service",
            "c1-edge-networks.service",
        }
        variables = (ROOT / "roles/network/vars/main.yml").read_text(encoding="utf-8")
        tasks = (ROOT / "roles/network/tasks/main.yml").read_text(encoding="utf-8")
        template = (ROOT / "roles/network/templates/network-prerequisite.service.j2").read_text(encoding="utf-8")
        self.assertEqual(set(re.findall(r"(?m)^    - name: ([a-z0-9-]+\.service)$", variables)), expected)
        self.assertIn('dest: "/etc/systemd/system/{{ item.name }}"', tasks)
        self.assertIn("container_node_network_units[inventory_hostname]", tasks)
        self.assertIn("Before={{ item.before | join(' ') }}", template)
        self.assertIn("After={{ item.after | join(' ') }}", template)
        self.assertIn("Requires={{ item.requires | join(' ') }}", template)
        self.assertRegex(variables, r"doco-cd-c[01]\.service")

    def test_services_declare_ordering_and_timers_target_explicit_services(self):
        units = self.unit_assets()
        for name, path in units.items():
            text = path.read_text(encoding="utf-8")
            with self.subTest(unit=name):
                self.assertIn("[Unit]", text)
                if name.endswith(".service"):
                    self.assertRegex(text, r"(?m)^(?:After|Before|Requires|Wants)=")
                else:
                    self.assertIn("[Timer]", text)
                    target = re.search(r"(?m)^Unit=(\S+)$", text)
                    self.assertIsNotNone(target)
                    self.assertIn(target.group(1), units)

    def test_doco_project_units_fail_closed_behind_prerequisites(self):
        template = (ROOT / "roles/doco_controller/templates/doco-project.service.j2").read_text(encoding="utf-8")
        tasks = (ROOT / "roles/doco_controller/tasks/main.yml").read_text(encoding="utf-8")
        self.assertRegex(template, r"(?m)^Requires=.+$")
        self.assertRegex(template, r"(?m)^After=.+$")
        self.assertRegex(template, r"(?m)^ExecStart=.+doco-project-lifecycle start")
        self.assertRegex(template, r"(?m)^ExecStop=.+doco-project-lifecycle stop")
        self.assertIn("Restart=no", template)
        self.assertNotRegex(template, r"(?i)(compose|reconcile)")
        self.assertIn("doco-project-{{ item.name }}.service", tasks)
        for host, projects in {
            "c0": ("powerdns-c0", "blocky-c0", "openbao-c0", "monitoring-c0", "omada-controller-c0"),
            "c1": ("librefs-c1", "edge-c1", "forgejo-c1"),
        }.items():
            host_vars = (ROOT / f"inventory/host_vars/{host}/main.yml").read_text(encoding="utf-8")
            for project in projects:
                with self.subTest(host=host, project=project):
                    self.assertRegex(host_vars, rf"(?m)^  - name: {re.escape(project)}$")
        self.assertFalse((ROOT / "roles/runtime_assets/templates/librefs-c1.service.j2").exists())
        self.assertFalse((ROOT / "roles/runtime_assets/files/manage-c1-librefs").exists())
        backup = (ROOT / "roles/runtime_assets/templates/forgejo-backup.service.j2").read_text(encoding="utf-8")
        self.assertIn("doco-project-forgejo-c1.service", backup)
        self.assertIn("doco-project-librefs-c1.service", backup)
        self.assertNotIn("doco-project-forgejo.service", backup)
        backup_script = (ROOT / "roles/runtime_assets/files/backup-c1-forgejo").read_text(encoding="utf-8")
        self.assertIn('docker exec --env KOPIA_LOG_DIR=/logs "$KOPIA"', backup_script)
        self.assertIn("repository connect s3", backup_script)
        self.assertIn("repository create s3", backup_script)


class ProtectedRuntimeAssetTests(unittest.TestCase):
    def test_secret_helpers_are_noninteractive_redacted_transactions(self):
        runtime_files = [
            path
            for subtree in ("files", "tasks", "templates", "library")
            for path in (ROOT / "roles/runtime_assets" / subtree).rglob("*")
            if path.is_file() and any(word in path.name for word in ("token", "secret", "certificate", "materialize"))
        ]
        self.assertTrue(runtime_files)
        for path in runtime_files:
            text = path.read_text(encoding="utf-8")
            with self.subTest(asset=path.name):
                self.assertNotRegex(text, r"(?m)^\s*set\s+-[^\n]*x")
                self.assertNotRegex(text, r"(?i)(echo|printf)[^\n]*\$\{?(?:token|password|private_key|secret)\}?")

    def test_verification_openbao_results_are_never_logged(self):
        text = (ROOT / "roles/verification/tasks/openbao.yml").read_text(encoding="utf-8")
        sensitive_tasks = re.findall(r"(?ms)^- name: (?:Read exact OpenBao KV v2 records|Verify exact OpenBao record schemas and versions)\n(?P<body>.*?)(?=^- name:|\Z)", text)
        self.assertEqual(len(sensitive_tasks), 2)
        for body in sensitive_tasks:
            self.assertIn("no_log: true", body)

    def test_c0_doco_api_secret_is_normalized_only_during_secret_provisioning(self):
        materialize = (
            ROOT / "roles/runtime_assets/tasks/materialize-c0.yml"
        ).read_text(encoding="utf-8")
        controller = (
            ROOT / "roles/doco_controller/tasks/main.yml"
        ).read_text(encoding="utf-8")
        self.assertIn("^[A-Za-z0-9_-]{64}\\n?$", materialize)
        self.assertIn("Normalize c0 Doco API secret without trailing whitespace", materialize)
        self.assertIn("content: \"{{ runtime_c0_doco_api_secret.content | b64decode | trim }}\"", materialize)
        self.assertNotIn("atomic_secret:", controller)

    def test_vector_ingest_token_is_materialized(self):
        materialize = (
            ROOT / "roles/runtime_assets/tasks/materialize-c0.yml"
        ).read_text(encoding="utf-8")
        self.assertIn(
            "| replace('@@vector_ingest_token@@', runtime_monitoring.vector_ingest_token)",
            materialize,
        )

    def test_c0_wildcard_certificate_precedes_and_safely_restarts_monitoring(self):
        updater = (
            ROOT / "roles/runtime_assets/files/update-c0-wildcard-certificate"
        ).read_text(encoding="utf-8")
        inventory = (ROOT / "inventory/host_vars/c0/main.yml").read_text(encoding="utf-8")
        self.assertIn("c0-wildcard-certificate.service", inventory)
        self.assertIn(
            '"$SYSTEMCTL_BIN" is-active --quiet doco-project-monitoring-c0.service',
            updater,
        )
        self.assertIn('"$LIFECYCLE" stop monitoring-c0', updater)
        self.assertIn('"$LIFECYCLE" start monitoring-c0', updater)
        self.assertNotIn('"$LIFECYCLE" monitoring-c0 stop', updater)


if __name__ == "__main__":
    unittest.main()
