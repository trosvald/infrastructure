import unittest

from scripts.read_managed import (
    normalize_apply_groups_exceptions,
    normalize_apply_groups_exceptions_xml,
    normalize_direct_reservation_paths_xml,
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
    @staticmethod
    def xml(body):
        return (
            '<data xmlns="urn:ietf:params:xml:ns:netconf:base:1.0">'
            '<configuration xmlns="http://xml.juniper.net/xnm/1.1/xnm">'
            f"{body}</configuration></data>"
        )

    def test_empty_result(self):
        self.assertEqual(normalize_direct_reservation_paths_xml(self.xml("")), [])

    def test_master_pool_host(self):
        output = self.xml(
            "<access><address-assignment><pool><name>PROD</name><family><inet>"
            "<host><name>node-a</name><hardware-address>02:00:00:00:00:01"
            "</hardware-address><ip-address>198.51.100.11</ip-address></host>"
            "</inet></family></pool></address-assignment></access>"
        )
        self.assertEqual(
            normalize_direct_reservation_paths_xml(output),
            ["access/address-assignment/pool/PROD/family/inet/host/node-a"],
        )

    def test_routing_instance_home_host(self):
        output = self.xml(
            "<routing-instances><instance><name>VR-XLSATU</name><access>"
            "<address-assignment><pool><name>HOME</name><family><inet>"
            "<host><name>home-a</name></host></inet></family></pool>"
            "</address-assignment></access></instance></routing-instances>"
        )
        self.assertEqual(
            normalize_direct_reservation_paths_xml(output),
            [
                "routing-instances/VR-XLSATU/access/address-assignment/"
                "pool/HOME/family/inet/host/home-a"
            ],
        )

    def test_multiple_paths_are_sorted_and_values_are_redacted(self):
        output = self.xml(
            "<access><address-assignment>"
            "<pool><name>PROD</name><family><inet><host><name>z-node</name>"
            "<hardware-address>02:00:00:00:00:ff</hardware-address>"
            "<ip-address>198.51.100.99</ip-address></host></inet></family></pool>"
            "<pool><name>MGMT</name><family><inet><host><name>a-node</name>"
            "</host></inet></family></pool>"
            "</address-assignment></access>"
        )
        paths = normalize_direct_reservation_paths_xml(output)
        self.assertEqual(
            paths,
            [
                "access/address-assignment/pool/MGMT/family/inet/host/a-node",
                "access/address-assignment/pool/PROD/family/inet/host/z-node",
            ],
        )
        self.assertNotIn("02:00:00:00:00:ff", "\n".join(paths))
        self.assertNotIn("198.51.100.99", "\n".join(paths))

    def test_groups_hierarchy_is_rejected(self):
        output = self.xml(
            "<groups><name>ANSIBLE_SRX1500</name><access><address-assignment>"
            "<pool><name>PROD</name><family><inet><host><name>node-a</name>"
            "</host></inet></family></pool></address-assignment></access></groups>"
        )
        with self.assertRaisesRegex(RuntimeError, "contains groups"):
            normalize_direct_reservation_paths_xml(output)

    def test_unexpected_pool_is_rejected(self):
        output = self.xml(
            "<access><address-assignment><pool><name>OTHER</name><family><inet>"
            "<host><name>node-a</name></host></inet></family></pool>"
            "</address-assignment></access>"
        )
        with self.assertRaisesRegex(RuntimeError, "unexpected master pool"):
            normalize_direct_reservation_paths_xml(output)

    def test_missing_or_duplicate_host_name_is_rejected(self):
        for names in ("", "<name>one</name><name>two</name>"):
            with self.subTest(names=names):
                output = self.xml(
                    "<access><address-assignment><pool><name>DEV</name>"
                    f"<family><inet><host>{names}</host></inet></family></pool>"
                    "</address-assignment></access>"
                )
                with self.assertRaisesRegex(RuntimeError, "exactly one nonempty name"):
                    normalize_direct_reservation_paths_xml(output)

    def test_duplicate_normalized_path_is_rejected(self):
        host = "<host><name>node-a</name></host>"
        output = self.xml(
            "<access><address-assignment><pool><name>PROD</name><family><inet>"
            f"{host}{host}</inet></family></pool></address-assignment></access>"
        )
        with self.assertRaisesRegex(RuntimeError, "duplicate direct reservation path"):
            normalize_direct_reservation_paths_xml(output)


if __name__ == "__main__":
    unittest.main()
