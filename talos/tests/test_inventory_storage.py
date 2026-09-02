import importlib.util
import json
import pathlib
import unittest
from unittest import mock

ROOT = pathlib.Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location(
    "inventory_storage", ROOT / "scripts/inventory_storage.py"
)
assert spec is not None and spec.loader is not None
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


def output(*disks):
    return "\n".join(json.dumps({"spec": disk}) for disk in disks)


def nvme(**changes):
    disk = {
        "transport": "nvme",
        "size": 1_000_204_886_016,
        "model": "SYNTHETIC-NVME",
        "serial": "SYNTHETIC-OSD-01",
        "wwid": "eui.0000000000000001",
        "bus_path": "/pci0000:00/synthetic-nvme-01",
    }
    disk.update(changes)
    return disk


class InventoryStorageTests(unittest.TestCase):
    def select(self, *disks):
        with mock.patch.object(module.subprocess, "check_output", return_value=output(*disks)):
            return module.candidate("bsd-k8s-01", "192.0.2.11")

    def test_accepts_one_stably_identified_one_tb_nvme(self):
        self.assertEqual(self.select(nvme())["wwid"], "eui.0000000000000001")

    def test_rejects_size_only_identity(self):
        with self.assertRaisesRegex(SystemExit, "stable wwid"):
            self.select(nvme(wwid=""))

    def test_rejects_multiple_one_tb_candidates(self):
        with self.assertRaisesRegex(SystemExit, "exactly one"):
            self.select(nvme(), nvme(serial="SYNTHETIC-OSD-02", wwid="eui.0000000000000002"))

    def test_ignores_protected_and_usb_media(self):
        selected = self.select(
            nvme(size=500_000_000_000, serial="TALOS"),
            nvme(size=512_000_000_000, serial="LOCALPV"),
            nvme(transport="usb", serial="USB"),
            nvme(),
        )
        self.assertEqual(selected["serial"], "SYNTHETIC-OSD-01")


if __name__ == "__main__":
    unittest.main()
