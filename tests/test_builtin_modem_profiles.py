import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

import yaml

from control.app import config


class BuiltinModemProfileTests(unittest.TestCase):
    def test_first_generation_dji_profile_is_a_default(self):
        profiles = config.DEFAULTS["settings"]["hardware"]["modem_profiles"]
        pairs = {(item["vid"], item["pid"]) for item in profiles}
        self.assertIn(("2ca3", "4006"), pairs)

    def test_old_saved_profiles_gain_new_builtins_without_losing_custom_entries(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "config.yaml"
            saved = {
                "settings": {
                    "hardware": {
                        "modem_profiles": [
                            {"name": "Existing EC25 override", "vid": "2C7C", "pid": "0125",
                             "at_interface": 3},
                            {"name": "Custom modem", "vid": "1234", "pid": "5678",
                             "at_interface": 1},
                        ]
                    }
                },
                "instances": {},
            }
            path.write_text(yaml.safe_dump(saved), encoding="utf-8")
            with patch.object(config, "CONFIG_PATH", path):
                loaded = config.load()

        profiles = loaded["settings"]["hardware"]["modem_profiles"]
        pairs = [(item["vid"].lower(), item["pid"].lower()) for item in profiles]
        self.assertEqual(pairs.count(("2c7c", "0125")), 1)
        self.assertEqual(pairs.count(("2ca3", "4006")), 1)
        self.assertIn(("1234", "5678"), pairs)
        self.assertEqual(profiles[0]["at_interface"], 3)


if __name__ == "__main__":
    unittest.main()
