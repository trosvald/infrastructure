import copy
import importlib.util
import json
import pathlib
import shutil
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
INTENT = ROOT / "intent/srx1500"
TOPOLOGY = ROOT / "tests/topology.yml"
spec = importlib.util.spec_from_file_location("junos_intent", ROOT / "scripts/junos_intent.py")
if spec is None:
    raise RuntimeError("unable to load Junos intent module")
module = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(module)


class IntentTests(unittest.TestCase):
    def build(self, intent_dir=INTENT, topology=TOPOLOGY):
        return module.build(intent_dir, topology)[0]

    def with_topology(self, mutate):
        topology = copy.deepcopy(module.load_yaml(TOPOLOGY))
        mutate(topology)
        temporary = tempfile.NamedTemporaryFile(mode="w", suffix=".json", delete=False)
        temporary.write(json.dumps(topology))
        temporary.close()
        self.addCleanup(pathlib.Path(temporary.name).unlink, missing_ok=True)
        return pathlib.Path(temporary.name)

    def with_intent(self, domain, mutate):
        temporary = pathlib.Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, temporary, ignore_errors=True)
        shutil.copytree(INTENT, temporary / "srx1500")
        path = temporary / "srx1500" / f"{domain}.yml"
        value = module.load_yaml(path)
        mutate(value)
        path.write_text(json.dumps(value), encoding="utf-8")
        return temporary / "srx1500"

    def test_deterministic_and_group_owned(self):
        first, second = self.build(), self.build()
        self.assertEqual(first, second)
        self.assertEqual(first[0], "delete groups ANSIBLE_SRX1500")
        self.assertEqual(first[-1], "set apply-groups ANSIBLE_SRX1500")
        self.assertTrue(
            all(
                command.startswith(("delete groups ", "set groups ", "set apply-groups "))
                for command in first
            )
        )

    def test_reconciled_live_relationships_are_rendered(self):
        commands = self.build()
        text = "\n".join(commands)
        self.assertIn("interfaces ge-0/0/2 native-vlan-id 2510", text)
        self.assertIn("interfaces ge-0/0/2 unit 0 family ethernet-switching vlan members VLAN-DEV", text)
        self.assertNotIn("interfaces ge-0/0/2 unit 0 family ethernet-switching vlan members VLAN-PROD", text)
        for interface, hostname in (
            ("ge-0/0/3", "BSD-K8S-01"),
            ("ge-0/0/4", "BSD-K8S-02"),
            ("ge-0/0/5", "BSD-K8S-03"),
            ("ge-0/0/9", "BSD-K8S-04"),
            ("ge-0/0/10", "BSD-K8S-05"),
        ):
            self.assertIn(f"interfaces {interface} description TO-{hostname}-MGMT", text)
            self.assertIn(
                f"interfaces {interface} unit 0 family ethernet-switching vlan members VLAN-MGMT",
                text,
            )
            self.assertNotIn(
                f"interfaces {interface} unit 0 family ethernet-switching vlan members VLAN-PROD",
                text,
            )
        self.assertIn("routing-instances VR-XLSATU access address-assignment pool HOME", text)
        self.assertIn(
            "routing-instances VR-XLSATU system services dhcp-local-server group HOME interface irb.2512",
            text,
        )
        for group in ("MGMT", "PROD", "DEV"):
            self.assertIn(
                f"system services dhcp-local-server group {group} overrides delete-binding-on-renegotiation",
                text,
            )
        self.assertIn(
            "routing-instances VR-XLSATU system services dhcp-local-server group HOME "
            "overrides delete-binding-on-renegotiation",
            text,
        )
        self.assertIn(
            "routing-instances VR-XLSATU system services dhcp-local-server "
            "route-suppression access-internal",
            text,
        )
        self.assertIn(
            "routing-instances VR-XLSATU system services dhcp-local-server "
            "requested-ip-interface-match",
            text,
        )
        self.assertNotIn("system services dhcp-local-server delete-binding-on-renegotiation", text)
        for ruleset in ("HOME-TO-XLSATU", "MGMT-TO-MYREP", "PROD-TO-MYREP", "DEV-TO-MYREP"):
            self.assertIn(f"security nat source rule-set {ruleset}", text)
        for port, name in ((22, "EDGE-SSH"), (80, "EDGE-HTTP"), (443, "EDGE-HTTPS")):
            self.assertIn(
                f"security nat destination pool {name} address 198.18.1.10/32 port {port}",
                text,
            )
            self.assertIn(
                f"security nat destination rule-set WAN-MYREP-TO-EDGE rule {name} "
                f"match destination-port {port}",
                text,
            )
        self.assertNotIn("proxy-arp", text)

    def test_public_edge_gate_omits_wan_policy_and_destination_nat(self):
        def disable_without_public_address(value):
            value["edge"]["public_enabled"] = False
            del value["wan"]["secondary_public_cidr"]

        candidate_a = self.with_topology(disable_without_public_address)
        text = "\n".join(self.build(topology=candidate_a))
        self.assertNotIn("security nat destination", text)
        self.assertNotIn("policy WAN-EDGE-PUBLIC", text)
        self.assertIn("policy MGMT-EDGE", text)
    def test_cilium_bgp_contract_is_rendered_once_and_in_order(self):
        first, second = self.build(), self.build()
        self.assertEqual(first, second)
        text = "\n".join(first)
        for peer in (
            "198.51.100.11",
            "198.51.100.12",
            "198.51.100.13",
            "198.51.100.14",
            "198.51.100.15",
        ):
            self.assertIn(f"protocols bgp group CILIUM neighbor {peer}", text)
        self.assertEqual(text.count("protocols bgp group CILIUM authentication-key "), 1)
        self.assertIn(
            "IMPORT-CILIUM-LB term CILIUM-LB-HOSTS from route-filter "
            "198.18.0.0/24 prefix-length-range /32-/32",
            text,
        )
        self.assertIn("EXPORT-CILIUM-NONE term REJECT-ALL then reject", text)
        self.assertIn("routing-options static route 198.18.0.0/24 discard", text)
        self.assertIn("prefix-limit maximum 128 teardown 100 idle-timeout 5", text)
        self.assertIn("protocols bgp group CILIUM multipath", text)
        self.assertIn("routing-options autonomous-system 64512", text)
        self.assertIn("routing-options router-id 198.51.100.1", text)
        self.assertIn(
            "security-zone PROD interfaces irb.2511 "
            "host-inbound-traffic protocols bgp",
            text,
        )
        self.assertNotIn("keepalive", text)
        self.assertNotIn("graceful-restart", text)

    def test_cilium_peer_count_and_address_failures_are_independent(self):
        mutations = {
            "four": lambda topology: topology["bgp"].update(
                peers=topology["bgp"]["peers"][:4]
            ),
            "six": lambda topology: topology["bgp"].update(
                peers=[*topology["bgp"]["peers"], "198.51.100.16"]
            ),
            "duplicate": lambda topology: topology["bgp"]["peers"].__setitem__(
                4, topology["bgp"]["peers"][0]
            ),
            "outside": lambda topology: topology["bgp"]["peers"].__setitem__(
                4, "192.0.2.254"
            ),
        }
        for name, mutate in mutations.items():
            with self.subTest(name=name):
                with self.assertRaisesRegex(module.IntentError, "five approved|five unique"):
                    self.build(topology=self.with_topology(mutate))

    def test_cilium_asn_and_authentication_failures_are_independent(self):
        changed_asn = self.with_topology(
            lambda topology: topology["bgp"].update(peer_as=64514)
        )
        with self.assertRaisesRegex(module.IntentError, "64512/64513"):
            self.build(topology=changed_asn)
        raw_auth = self.with_intent(
            "routing",
            lambda value: value["routing"]["bgp"].update(authentication_key="plaintext"),
        )
        with self.assertRaisesRegex(module.IntentError, "device-local"):
            self.build(intent_dir=raw_auth)
        missing_auth = self.with_topology(
            lambda topology: topology["bgp"].pop("authentication_key")
        )
        with self.assertRaisesRegex(module.IntentError, "undefined topology key"):
            self.build(topology=missing_auth)
        malformed_auth = self.with_topology(
            lambda topology: topology["bgp"].update(authentication_key="invalid")
        )
        with self.assertRaisesRegex(module.IntentError, "43-character base64url"):
            self.build(topology=malformed_auth)

    def test_cilium_import_and_export_policy_failures_are_independent(self):
        def import_term(value):
            return value["routing"]["policies"][2]["terms"][0]

        for prefix_range in ("/24-/32", "/33-/33"):
            bad_range = self.with_intent(
                "routing",
                lambda value, prefix_range=prefix_range: import_term(value)[
                    "route_filter"
                ].update(prefix_length_range=prefix_range),
            )
            with self.subTest(prefix_range=prefix_range):
                with self.assertRaisesRegex(module.IntentError, "only LB-pool /32"):
                    self.build(intent_dir=bad_range)
        aggregate = self.with_intent(
            "routing",
            lambda value: value["routing"]["policies"][2]["terms"].insert(
                1,
                {
                    "name": "AGGREGATE",
                    "from_protocol": "bgp",
                    "route_filter": {"topology": "bgp.lb_pool"},
                    "action": "accept",
                },
            ),
        )
        with self.assertRaisesRegex(module.IntentError, "only LB-pool /32"):
            self.build(intent_dir=aggregate)
        export_permit = self.with_intent(
            "routing",
            lambda value: value["routing"]["policies"][3]["terms"][0].update(
                action="accept"
            ),
        )
        with self.assertRaisesRegex(module.IntentError, "export policy"):
            self.build(intent_dir=export_permit)
        missing_reject = self.with_intent(
            "routing",
            lambda value: value["routing"]["policies"][2]["terms"].pop(),
        )
        with self.assertRaisesRegex(module.IntentError, "only LB-pool /32"):
            self.build(intent_dir=missing_reject)

    def test_cilium_fallback_and_group_safety_failures_are_independent(self):
        mutations = {
            "non-discard": lambda value: value["routing"]["static_routes"][0].update(
                action="reject"
            ),
            "multipath": lambda value: value["routing"]["bgp"].update(multipath=False),
            "hold": lambda value: value["routing"]["bgp"].update(hold_time=10),
            "prefix-maximum": lambda value: value["routing"]["bgp"]["unicast"][
                "prefix_limit"
            ].update(maximum=129),
            "prefix-teardown": lambda value: value["routing"]["bgp"]["unicast"][
                "prefix_limit"
            ].pop("teardown"),
            "graceful-restart": lambda value: value["routing"]["bgp"].update(
                graceful_restart=True
            ),
        }
        for name, mutate in mutations.items():
            with self.subTest(name=name):
                with self.assertRaises(module.IntentError):
                    self.build(intent_dir=self.with_intent("routing", mutate))
        mismatched_pool = self.with_topology(
            lambda topology: topology["bgp"].update(lb_pool="198.19.0.0/24")
        )
        with self.assertRaisesRegex(module.IntentError, "static discard"):
            self.build(topology=mismatched_pool)

    def test_bgp_host_inbound_is_rejected_outside_prod(self):
        non_prod = self.with_intent(
            "security",
            lambda value: value["security"]["zones"][0].update(protocols=["bgp"]),
        )
        with self.assertRaisesRegex(module.IntentError, "only on PROD"):
            self.build(intent_dir=non_prod)

    def test_authentication_value_free_path_never_contains_material(self):
        secret = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopq"
        line = (
            "set groups ANSIBLE_SRX1500 protocols bgp group CILIUM "
            f"authentication-key {secret}"
        )
        normalized = module.value_free_path(line)
        self.assertEqual(
            normalized,
            "protocols/bgp/group/CILIUM/authentication-key",
        )
        self.assertNotIn(secret, normalized)

    def test_no_duplicates_and_live_security_controls(self):
        commands = self.build()
        self.assertEqual(len(commands), len(set(commands)))
        text = "\n".join(commands)
        self.assertIn('description "Management VLAN - Untagged on TP-Link trunks"', text)
        self.assertIn("security flow tcp-mss all-tcp mss 1456", text)
        self.assertIn("security screen ids-option WAN-SCREEN tcp syn-flood alarm-threshold 1024", text)
        self.assertIn(
            "security zones security-zone MGMT interfaces irb.2510 "
            "host-inbound-traffic system-services netconf",
            text,
        )
        self.assertIn("protocols l2-learning global-mode switching", text)
        self.assertIn("system services web-management https system-generated-certificate", text)
        self.assertIn("system syslog file security-log any any", text)
        self.assertIn('system syslog file security-log match "RT_FLOW|RT_SCREEN"', text)
        self.assertIn("system syslog file security-log structured-data", text)
        self.assertIn(
            "system syslog host logs-ingest.example.invalid structured-data",
            text,
        )
        self.assertIn("security log mode stream", text)
        self.assertIn("security log format sd-syslog", text)
        self.assertIn("security log source-address 192.0.2.33", text)
        self.assertIn("security log stream VECTOR host 198.18.2.37", text)
        self.assertIn("security log stream VECTOR host port 6514", text)
        self.assertIn("security log stream VECTOR transport protocol tls", text)
        self.assertIn("security log stream VECTOR transport tls-profile VECTOR-SRX-TLS", text)
        self.assertIn(
            "services ssl initiation profile VECTOR-SRX-TLS trusted-ca VECTOR-SRX-ROOT",
            text,
        )
        self.assertIn("security policies pre-id-default-policy then log session-close", text)
        for policy in (
            "PROD-INTERNET",
            "MGMT-ADMIN-PROD",
            "PROD-INFRA-MGMT",
            "PROD-INFRA-DEV",
            "DEV-INFRA-PROD",
        ):
            self.assertIn(f"policy {policy} then log session-init", text)
            self.assertIn(f"policy {policy} then log session-close", text)

    def test_dhcp_option_lease_home_pool_and_ssh_macs(self):
        text = "\n".join(self.build())
        self.assertIn("pool MGMT family inet dhcp-attributes maximum-lease-time 86400", text)
        self.assertIn("pool MGMT family inet dhcp-attributes option 138 ip-address 192.0.2.2", text)
        self.assertIn("pool HOME family inet dhcp-attributes name-server", text)
        self.assertIn("system services ssh macs hmac-sha2-256", text)
        self.assertIn("system services ssh macs hmac-sha2-512", text)
        self.assertNotIn("unit 0 family inet dhcp\n", text)

    def test_prod_reservation_renders_exact_hardware_and_ip_leaves(self):
        commands = self.build()
        prefix = (
            "set groups ANSIBLE_SRX1500 access address-assignment pool PROD "
            "family inet host synthetic-prod-a "
        )
        reservation_lines = [
            command for command in commands if command.startswith(prefix)
        ]
        self.assertEqual(
            reservation_lines,
            [
                prefix + "hardware-address 02:00:00:00:20:01",
                prefix + "ip-address 198.51.100.11",
            ],
        )

    def test_dhcp_router_range_and_reservation_containment(self):
        outside = self.with_topology(lambda topology: topology["networks"]["mgmt"].update(gateway="198.51.100.254"))
        with self.assertRaisesRegex(module.IntentError, "router is outside"):
            self.build(topology=outside)
        outside = self.with_topology(lambda topology: topology["reservations"]["home"].__setitem__(0, {"name": "outside", "mac": "02:00:00:00:30:ff", "ip": "192.0.2.200"}))
        with self.assertRaisesRegex(module.IntentError, "outside"):
            self.build(topology=outside)

    def test_dhcp_router_must_equal_bound_irb(self):
        mismatch = self.with_topology(lambda topology: topology["networks"]["mgmt"].update(gateway="192.0.2.2"))
        with self.assertRaisesRegex(module.IntentError, "router must equal bound interface address"):
            self.build(topology=mismatch)

    def test_every_dhcp_pool_and_address_book_use_internal_dns(self):
        bad_pool = self.with_intent(
            "dhcp",
            lambda value: value["dhcp"]["pools"][1].update(dns=[{"topology": "dns.secondary"}]),
        )
        with self.assertRaisesRegex(module.IntentError, "must use only dns.internal"):
            self.build(intent_dir=bad_pool)
        bad_address = self.with_intent(
            "security",
            lambda value: value["security"]["address_books"][0].update(value={"topology": "dns.secondary"}),
        )
        with self.assertRaisesRegex(module.IntentError, "production DNS"):
            self.build(intent_dir=bad_address)
        bad_policy = self.with_intent(
            "security",
            lambda value: next(
                policy
                for policy in value["security"]["policies"]
                if policy["name"] == "HOME-TO-DNS"
            ).update(to="MGMT"),
        )
        with self.assertRaisesRegex(module.IntentError, "HOME DNS"):
            self.build(intent_dir=bad_policy)

    def test_wan_routing_zone_and_nat_coupling_is_exact(self):
        bad_routing = self.with_intent(
            "routing",
            lambda value: value["routing"]["instances"][0].update(interfaces=["ge-0/0/1.0", "irb.2512"]),
        )
        with self.assertRaisesRegex(module.IntentError, "VR-XLSATU"):
            self.build(intent_dir=bad_routing)
        bad_zone = self.with_intent(
            "security",
            lambda value: value["security"]["zones"][5].update(interfaces=["ge-0/0/1.0"]),
        )
        with self.assertRaisesRegex(module.IntentError, "WAN zones"):
            self.build(intent_dir=bad_zone)
        bad_nat = self.with_intent(
            "nat",
            lambda value: value["nat"]["source_rules"][0].update(to_zone="WAN-MYREP"),
        )
        with self.assertRaisesRegex(module.IntentError, "source NAT"):
            self.build(intent_dir=bad_nat)

    def test_duplicate_reservation_name_mac_and_ip(self):
        for field, expected in (("name", "reservation name"), ("mac", "reservation MAC"), ("ip", "reservation IP")):
            def mutate(topology, field=field):
                first = topology["reservations"]["prod"][0]
                second = topology["reservations"]["prod"][1]
                duplicate = {
                    "name": "synthetic-prod-duplicate",
                    "mac": "02:00:00:00:20:ff",
                    "ip": "198.51.100.13",
                }
                duplicate[field] = first[field]
                if field == "name":
                    duplicate["ip"] = second["ip"]
                elif field == "mac":
                    duplicate["ip"] = second["ip"]
                elif field == "ip":
                    duplicate["ip"] = first["ip"]
                topology["reservations"]["prod"].append(duplicate)
            with self.subTest(field=field):
                with self.assertRaisesRegex(module.IntentError, expected):
                    self.build(topology=self.with_topology(mutate))

    def test_duplicate_ip_assignment_across_irb_and_reservation(self):
        duplicate = self.with_topology(lambda topology: topology["reservations"]["mgmt"].__setitem__(0, {"name": "duplicate-gateway", "mac": "02:00:00:00:10:ff", "ip": "192.0.2.1"}))
        with self.assertRaisesRegex(module.IntentError, "duplicate IP assignment"):
            self.build(topology=duplicate)

    def test_duplicate_vlan_irb_interface_and_unit_rejected(self):
        duplicate_vlan = self.with_intent("vlans", lambda value: value["vlans"].append(dict(value["vlans"][0])))
        with self.assertRaisesRegex(module.IntentError, "duplicate VLAN name"):
            self.build(intent_dir=duplicate_vlan)
        duplicate_interface = self.with_intent("interfaces", lambda value: value["interfaces"].append(dict(value["interfaces"][0])))
        with self.assertRaisesRegex(module.IntentError, "duplicate interface"):
            self.build(intent_dir=duplicate_interface)
        duplicate_unit = self.with_intent("interfaces", lambda value: value["interfaces"][-1]["units"].append(dict(value["interfaces"][-1]["units"][0])))
        with self.assertRaisesRegex(module.IntentError, "duplicate unit"):
            self.build(intent_dir=duplicate_unit)

    def test_cross_domain_references_are_required(self):
        bad_vlan = self.with_intent("interfaces", lambda value: value["interfaces"][2]["units"][0]["vlans"].append("VLAN-MISSING"))
        with self.assertRaisesRegex(module.IntentError, "undefined VLAN"):
            self.build(intent_dir=bad_vlan)
        bad_zone = self.with_intent("security", lambda value: value["security"]["zones"][0]["interfaces"].append("irb.9999"))
        with self.assertRaisesRegex(module.IntentError, "undefined interfaces"):
            self.build(intent_dir=bad_zone)
        bad_nat = self.with_intent("nat", lambda value: value["nat"]["source_rules"][0].update(to_zone="MISSING"))
        with self.assertRaisesRegex(module.IntentError, "undefined zone"):
            self.build(intent_dir=bad_nat)
        bad_dhcp = self.with_intent("dhcp", lambda value: value["dhcp"]["groups"].__setitem__(0, {**value["dhcp"]["groups"][0], "pool": "MISSING"}))
        with self.assertRaisesRegex(module.IntentError, "undefined pool"):
            self.build(intent_dir=bad_dhcp)

    def test_c0_trunk_invariant_is_fail_closed(self):
        for mutate in (
            lambda value: value["interfaces"][2].update(description="WRONG"),
            lambda value: value["interfaces"][2].update(native_vlan=2511),
            lambda value: value["interfaces"][2]["units"][0].update(mode="access"),
            lambda value: value["interfaces"][2]["units"][0].update(vlans=["VLAN-MGMT"]),
        ):
            with self.subTest():
                with self.assertRaisesRegex(module.IntentError, "ge-0/0/2"):
                    self.build(intent_dir=self.with_intent("interfaces", mutate))

    def test_ordered_reject_term_and_undefined_routing_instance(self):
        bad_order = self.with_intent("routing", lambda value: value["routing"]["policies"][0]["terms"].reverse())
        with self.assertRaisesRegex(module.IntentError, "reject term must remain last"):
            self.build(intent_dir=bad_order)
        bad_instance = self.with_intent("routing", lambda value: value["routing"]["instances"][0].update(interfaces=["ge-0/0/99.0"]))
        with self.assertRaisesRegex(module.IntentError, "VR-XLSATU"):
            self.build(intent_dir=bad_instance)

    def test_dns_field_cannot_be_substituted_with_blocky(self):
        bad_dns = self.with_intent("dhcp", lambda value: value["dhcp"]["pools"][0].update(dns=[{"topology": "dns.blocky"}]))
        with self.assertRaisesRegex(module.IntentError, "not Blocky"):
            self.build(intent_dir=bad_dns)

    def test_credential_and_unsupported_nat_ownership_is_rejected(self):
        bad_auth = self.with_intent("system", lambda value: value["system"].update({"root-authentication": "no"}))
        with self.assertRaisesRegex(module.IntentError, "device-local"):
            self.build(intent_dir=bad_auth)
        bad_nat = self.with_intent("nat", lambda value: value["nat"].update(proxy_arp=[]))
        with self.assertRaisesRegex(module.IntentError, "only reviewed"):
            self.build(intent_dir=bad_nat)


if __name__ == "__main__":
    unittest.main()
