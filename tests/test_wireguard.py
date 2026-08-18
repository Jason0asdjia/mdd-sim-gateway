import stat
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from control.app import wireguard


CONFIG = """[Interface]
PrivateKey = private
Address = 10.0.0.2/32
Table = auto

[Peer]
PublicKey = public
AllowedIPs = 0.0.0.0/0
Endpoint = vpn.example.test:51820
"""


def completed(returncode=0):
    return subprocess.CompletedProcess([], returncode)


class WireGuardImportTests(unittest.TestCase):
    def test_project_config_forces_table_off(self):
        result = wireguard._project_only_config(CONFIG)
        self.assertIn("Table=off", result)
        self.assertNotIn("Table = auto", result)

    def test_rejects_hooks_and_duplicate_interface_sections(self):
        with self.assertRaisesRegex(wireguard.WireGuardError, "directives are not allowed"):
            wireguard._validate("vpnuk", CONFIG.replace("Address =", "PostUp = touch /tmp/x\nAddress ="))
        with self.assertRaisesRegex(wireguard.WireGuardError, "one \\[Interface\\]"):
            wireguard._validate("vpnuk", CONFIG + "\n[Interface]\nAddress=10.1.0.1/32\n")

    def test_rejects_invalid_name_and_oversized_config(self):
        with self.assertRaisesRegex(wireguard.WireGuardError, "name is invalid"):
            wireguard._validate("bad interface", CONFIG)
        with self.assertRaisesRegex(wireguard.WireGuardError, "too large"):
            wireguard._validate("vpnuk", CONFIG + "#" * 33_000)

    def test_import_writes_private_project_only_config_and_starts_service(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            with patch.object(wireguard, "WIREGUARD_DIR", root), \
                    patch.object(wireguard.os, "geteuid", return_value=0), \
                    patch.object(wireguard.subprocess, "run",
                                 side_effect=[completed(3), completed(), completed()]) as run:
                result = wireguard.import_config("vpnuk", CONFIG)
            target = root / "vpnuk.conf"
            self.assertTrue(result["project_only"])
            self.assertIn("Table=off", target.read_text(encoding="utf-8"))
            self.assertEqual(stat.S_IMODE(target.stat().st_mode), 0o600)
            self.assertEqual(run.call_args_list[-1].args[0][:3],
                             ["systemctl", "enable", "--now"])

    def test_failed_start_restores_previous_active_configuration(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            target = root / "vpnuk.conf"
            target.write_text("previous\n", encoding="utf-8")
            with patch.object(wireguard, "WIREGUARD_DIR", root), \
                    patch.object(wireguard.os, "geteuid", return_value=0), \
                    patch.object(wireguard.subprocess, "run",
                                 side_effect=[completed(), completed(), completed(1),
                                              completed(), completed()]):
                with self.assertRaisesRegex(wireguard.WireGuardError, "did not start"):
                    wireguard.import_config("vpnuk", CONFIG)
            self.assertEqual(target.read_text(encoding="utf-8"), "previous\n")

    def test_service_timeout_does_not_create_configuration(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            with patch.object(wireguard, "WIREGUARD_DIR", root), \
                    patch.object(wireguard.os, "geteuid", return_value=0), \
                    patch.object(wireguard.subprocess, "run",
                                 side_effect=[completed(3), subprocess.TimeoutExpired("systemctl", 20)]):
                with self.assertRaisesRegex(wireguard.WireGuardError, "could not be started"):
                    wireguard.import_config("vpnuk", CONFIG)
            self.assertFalse((root / "vpnuk.conf").exists())


if __name__ == "__main__":
    unittest.main()
