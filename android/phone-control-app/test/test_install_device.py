#!/usr/bin/env python3
"""Exercise the real installer with isolated build and ADB boundaries."""

import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


INSTALLER = Path(__file__).resolve().parents[1] / "run/install-device.sh"
DEVICE = "192.0.2.10:5555"
COMPONENT = "com.airsim.phonecontrol.pixel8pro/com.airsim.phonecontrol.MainActivity"


class InstallDeviceTests(unittest.TestCase):
    def setUp(self):
        self.sandbox = tempfile.TemporaryDirectory(prefix="airsim installer ")
        self.addCleanup(self.sandbox.cleanup)
        self.root = Path(self.sandbox.name)
        (self.root / "run").mkdir()
        shutil.copyfile(INSTALLER, self.root / "run/install-device.sh")
        self.apk = self.root / "build/android/AirSIM-Android-Standalone-debug.apk"
        self.legacy_apk = self.apk.with_name("AirSIM-Phone-Bridge-debug.apk")
        self.build_log = self.root / "build.log"
        self.adb_log = self.root / "adb.jsonl"
        self.write_executable("build.sh", """
import os
from pathlib import Path

root = Path(__file__).parent
(root / "build.log").write_text("build invoked\\n")
if os.environ.get("INSTALL_TEST_FAIL_BUILD"):
    raise SystemExit(23)
apk = root / "build/android/AirSIM-Android-Standalone-debug.apk"
apk.parent.mkdir(parents=True, exist_ok=True)
apk.write_text("fresh standalone APK")
""")
        self.write_executable("adb", """
import json
import os
from pathlib import Path
import sys

with (Path(__file__).parent / "adb.jsonl").open("a") as log:
    log.write(json.dumps(sys.argv[1:]) + "\\n")
if "install" in sys.argv[1:]:
    if not Path(sys.argv[-1]).is_file():
        raise SystemExit(22)
    if os.environ.get("INSTALL_TEST_FAIL_INSTALL"):
        raise SystemExit(24)
""")

    def write_executable(self, name, source):
        path = self.root / name
        path.write_text(f"#!{sys.executable}\n{source}")
        path.chmod(0o755)

    def run_installer(self, **environment):
        env = os.environ.copy()
        for key in ("DEVICE", "ADB_SERIAL", "INSTALL_TEST_FAIL_BUILD",
                    "INSTALL_TEST_FAIL_INSTALL"):
            env.pop(key, None)
        env.update(ADB=str(self.root / "adb"), **environment)
        return subprocess.run(
            ["sh", str(self.root / "run/install-device.sh")],
            env=env, capture_output=True, text=True, timeout=10,
        )

    def seed_apk(self, path):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text("existing APK")

    def adb_calls(self):
        if not self.adb_log.exists():
            return []
        return [json.loads(line) for line in self.adb_log.read_text().splitlines()]

    def expected_calls(self, device=DEVICE):
        return [
            ["connect", device],
            ["-s", device, "install", "-r", str(self.apk)],
            ["-s", device, "shell", "am", "start", "-n", COMPONENT],
        ]

    def assert_success(self, result):
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.adb_calls(), self.expected_calls())

    def test_clean_checkout_builds_and_installs_standalone(self):
        result = self.run_installer(DEVICE=DEVICE)
        self.assert_success(result)
        self.assertTrue(self.build_log.exists())
        self.assertEqual(self.apk.read_text(), "fresh standalone APK")

    def test_legacy_artifact_does_not_skip_standalone_build(self):
        self.seed_apk(self.legacy_apk)
        result = self.run_installer(DEVICE=DEVICE)
        self.assert_success(result)
        self.assertTrue(self.build_log.exists())
        self.assertEqual(self.apk.read_text(), "fresh standalone APK")

    def test_existing_standalone_is_reused_and_device_takes_precedence(self):
        self.seed_apk(self.apk)
        self.seed_apk(self.legacy_apk)
        result = self.run_installer(DEVICE=DEVICE, ADB_SERIAL="other-device")
        self.assert_success(result)
        self.assertFalse(self.build_log.exists())
        self.assertEqual(self.apk.read_text(), "existing APK")

    def test_adb_serial_selects_device_when_device_is_empty(self):
        self.seed_apk(self.apk)
        result = self.run_installer(DEVICE="", ADB_SERIAL=DEVICE)
        self.assert_success(result)

    def test_missing_device_rejects_before_build_or_adb(self):
        result = self.run_installer()
        self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
        self.assertFalse(self.build_log.exists())
        self.assertEqual(self.adb_calls(), [])

    def test_build_failure_never_reaches_adb(self):
        result = self.run_installer(DEVICE=DEVICE, INSTALL_TEST_FAIL_BUILD="1")
        self.assertEqual(result.returncode, 23, result.stdout + result.stderr)
        self.assertTrue(self.build_log.exists())
        self.assertEqual(self.adb_calls(), [])

    def test_install_failure_never_launches_app(self):
        self.seed_apk(self.apk)
        result = self.run_installer(DEVICE=DEVICE, INSTALL_TEST_FAIL_INSTALL="1")
        self.assertEqual(result.returncode, 24, result.stdout + result.stderr)
        self.assertEqual(self.adb_calls(), self.expected_calls()[:2])


if __name__ == "__main__":
    unittest.main()
