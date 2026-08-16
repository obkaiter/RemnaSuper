import importlib.util
import json
import struct
import tempfile
import unittest
from pathlib import Path


MODULE_PATH = Path(__file__).parents[1] / "lib" / "shaping" / "controller.py"
SPEC = importlib.util.spec_from_file_location("shaper_controller", MODULE_PATH)
controller = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(controller)


class ControllerTests(unittest.TestCase):
    def test_ports_are_unique_and_validated(self):
        self.assertEqual(controller.parse_ports("443, 8443,443"), [443, 8443])
        for value in ("", "443,0", "65536", "abc"):
            with self.subTest(value=value), self.assertRaises(controller.ShaperError):
                controller.parse_ports(value)

    def test_rule_layout_matches_bpf_structure(self):
        rule = {
            "id": 7,
            "mode": 2,
            "ports": [443, 8443],
            "download_mbps": 80,
            "upload_mbps": 40,
            "penalty_mbps": 8,
            "burst_mib": 100,
            "window_seconds": 10,
            "penalty_seconds": 60,
        }
        payload = controller.pack_rule(rule)
        self.assertEqual(len(payload), 184)
        fields = struct.unpack(controller.RULE_FORMAT, payload)
        self.assertEqual(fields[0:4], (2, 2, 443, 8443))
        self.assertEqual(fields[34], 10_000_000)
        self.assertEqual(fields[35], 5_000_000)
        self.assertEqual(fields[36], 1_000_000)

    def test_btf_pretty_printed_keys_are_serialized(self):
        key = {
            "address": [0x04030201, 0, 0, 0],
            "rule_id": 3,
            "padding": 0,
        }
        raw = controller.map_key_bytes("download_states", key)
        self.assertEqual(raw[:4], b"\x01\x02\x03\x04")
        self.assertEqual(struct.unpack_from("<I", raw, 16)[0], 3)
        self.assertEqual(controller.state_key(key), ("1.2.3.4", 3))
        self.assertEqual(controller.byte_list(["01", "0a", "ff"]), b"\x01\x0a\xff")

    def test_state_values_support_btf_and_raw_output(self):
        pretty = {
            "total_bytes": 1234,
            "total_packets": 12,
            "dropped_packets": 2,
            "penalized": 1,
        }
        self.assertEqual(
            controller.state_value(pretty),
            {"bytes": 1234, "packets": 12, "drops": 2, "penalized": 1},
        )
        raw = bytearray(controller.STATE_SIZE)
        struct.pack_into("<QQQI", raw, 40, 1234, 12, 2, 1)
        self.assertEqual(controller.state_value(list(raw)), controller.state_value(pretty))

    def test_config_is_saved_atomically(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "rules.json"
            expected = {"version": 1, "rules": {}}
            controller.save_config(path, expected)
            self.assertEqual(json.loads(path.read_text(encoding="utf-8")), expected)

    def test_explicit_port_conflicts_but_wildcard_can_coexist(self):
        rules = {
            "0": {"id": 0, "ports": [0]},
            "1": {"id": 1, "ports": [443]},
        }
        candidate = {"id": 2, "ports": [443]}
        self.assertEqual(controller.find_conflicts(rules, candidate), [(443, 1)])
        self.assertEqual(controller.find_conflicts(rules, {"id": 2, "ports": [8443]}), [])


if __name__ == "__main__":
    unittest.main()
