import unittest

from scripts.read_managed import (
    normalize_apply_groups_exceptions,
    normalize_apply_groups_exceptions_xml,
    normalize_direct_reservation_paths,
)


class ApplyGroupsExceptionTests(unittest.TestCase):
    def test_empty_output(self):
        self.assertEqual(normalize_apply_groups_exceptions("\n  \n"), [])

    def test_one_exclusion(self):
        line = "set security policies apply-groups-except ANSIBLE_SRX1500"
        self.assertEqual(normalize_apply_groups_exceptions(line), [line])

    def test_multiple_exclusions_are_sorted(self):
        first = "set interfaces ge-0/0/0 apply-groups-except ANSIBLE_SRX1500"
        second = "set security policies apply-groups-except ANSIBLE_SRX1500"
        self.assertEqual(
            normalize_apply_groups_exceptions(f"{second}\n{first}\n"),
            [first, second],
        )

    def test_duplicate_exclusions_are_removed(self):
        line = "set security policies apply-groups-except ANSIBLE_SRX1500"
        self.assertEqual(normalize_apply_groups_exceptions(f"{line}\n{line}"), [line])

    def test_xpath_xml_exclusion_is_normalized_to_set_path(self):
        output = """\
<data xmlns="urn:ietf:params:xml:ns:netconf:base:1.0">
  <configuration xmlns="http://xml.juniper.net/xnm/1.1/xnm">
    <security>
      <policies>
        <apply-groups-except>ANSIBLE_SRX1500</apply-groups-except>
      </policies>
    </security>
  </configuration>
</data>
"""
        self.assertEqual(
            normalize_apply_groups_exceptions_xml(output),
            ["set security policies apply-groups-except ANSIBLE_SRX1500"],
        )

    def test_empty_xpath_xml_has_no_exclusions(self):
        self.assertEqual(
            normalize_apply_groups_exceptions_xml(
                '<data xmlns=\"urn:ietf:params:xml:ns:netconf:base:1.0\"/>'
            ),
            [],
        )

    def test_unrecognized_text_fails(self):
        with self.assertRaisesRegex(RuntimeError, "unexpected apply-groups-except output"):
            normalize_apply_groups_exceptions("warning: truncated output")


class DirectReservationTests(unittest.TestCase):
    def test_empty_result(self):
        self.assertEqual(normalize_direct_reservation_paths(""), [])

    def test_bare_master_pool_host_is_detected(self):
        line = (
            "set access address-assignment pool PROD family inet host "
            "bsd-k8s-01"
        )
        self.assertEqual(
            normalize_direct_reservation_paths(line),
            [
                "access/address-assignment/pool/PROD/family/inet/host/"
                "bsd-k8s-01"
            ],
        )

    def test_routing_instance_home_host_is_detected(self):
        line = (
            "set routing-instances VR-XLSATU access address-assignment "
            "pool HOME family inet host home-a"
        )
        self.assertEqual(
            normalize_direct_reservation_paths(line),
            [
                "routing-instances/VR-XLSATU/access/address-assignment/"
                "pool/HOME/family/inet/host/home-a"
            ],
        )

    def test_multiple_paths_are_sorted_and_values_are_redacted(self):
        output = "\n".join(
            [
                "set access address-assignment pool PROD family inet host "
                "z-node hardware-address 02:00:00:00:00:ff",
                "set access address-assignment pool PROD family inet host "
                "z-node ip-address 198.51.100.99",
                "set access address-assignment pool MGMT family inet host "
                "a-node",
            ]
        )
        paths = normalize_direct_reservation_paths(output)
        self.assertEqual(
            paths,
            [
                "access/address-assignment/pool/MGMT/family/inet/host/a-node",
                "access/address-assignment/pool/PROD/family/inet/host/z-node",
            ],
        )
        self.assertNotIn("02:00:00:00:00:ff", "\n".join(paths))
        self.assertNotIn("198.51.100.99", "\n".join(paths))

    def test_non_host_pool_lines_are_ignored(self):
        output = "\n".join(
            [
                "set access address-assignment pool PROD family inet network "
                "198.51.100.0/24",
                "set access address-assignment pool PROD family inet range "
                "PROD-IP-POOL low 198.51.100.100",
            ]
        )
        self.assertEqual(normalize_direct_reservation_paths(output), [])

    def test_groups_hierarchy_is_rejected(self):
        line = (
            "set groups ANSIBLE_SRX1500 access address-assignment pool PROD "
            "family inet host bsd-k8s-01"
        )
        with self.assertRaisesRegex(RuntimeError, "unexpected hierarchy"):
            normalize_direct_reservation_paths(line)

    def test_unexpected_pool_is_rejected(self):
        line = (
            "set access address-assignment pool OTHER family inet host node-a"
        )
        with self.assertRaisesRegex(RuntimeError, "unexpected hierarchy"):
            normalize_direct_reservation_paths(line)


if __name__ == "__main__":
    unittest.main()
