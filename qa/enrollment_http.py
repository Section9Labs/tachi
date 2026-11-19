"""Qualify an enrolled grant and the original JSON input against one compiled coordinator."""

import argparse
import hashlib
import json
from pathlib import Path
import shutil
import stat
import subprocess
import sys
import tempfile
import unittest

from solo_http import SoloHTTPCheck, routine_listener


class EnrollmentHTTPCheck(SoloHTTPCheck):
    def service_options(self, human, routine, url, secret):
        directory = self.directory / "grant"
        provision = {"human": human, "url": url, "secret": secret, "directory": directory.as_uri()}
        subprocess.run([self.provisioner], input=json.dumps(provision).encode(), check=True, timeout=10)
        binding = directory / "enrollment.json"
        credential = directory / "secret"
        self.assertEqual(stat.S_IMODE(directory.stat().st_mode), 0o700)
        self.assertTrue(all(stat.S_IMODE(path.stat().st_mode) == 0o600 for path in (binding, credential)))
        self.assertTrue(json.loads(binding.read_bytes()) == {"version": 1, "human_id": human,
                            "provider": "grok-bot", "destination": url}, "Unexpected enrollment metadata")
        self.assertTrue(credential.read_bytes() == (url + "\n" + secret).encode(), "Unexpected grant encoding")
        before = {path: hashlib.sha256(path.read_bytes()).digest() for path in (binding, credential)}

        def verify_grant_files():
            self.assertTrue(all(hashlib.sha256(path.read_bytes()).digest() == digest for path, digest in before.items()),
                            "Serving a task modified the provisioned grant")
            self.assertFalse((self.directory / "routines.json").exists())

        self.addCleanup(verify_grant_files)
        return ("--db", self.database, "--solo-enrollment-directory", directory,
                "--solo-enrollment-human", human, "--solo-enrollment-routine", routine, "--solo-loopback-fixture")

    def test_grant_requires_its_enrolled_human(self):
        with routine_listener("/fixture/owner", 200) as (url, secret, observed, _):
            options = list(self.service_options("synthetic-editor", "owner", url, secret))
            options[options.index("--solo-enrollment-human") + 1] = "synthetic-neighbor"
            start = subprocess.run([*self.service_command, "--port", "0", *options], timeout=15,
                                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            self.assertNotEqual(start.returncode, 0, "Coordinator started with a mismatched enrollment owner")
            self.assertFalse(observed())


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--service-root", required=True, type=Path, help="source containing the candidate Packages")
    parser.add_argument("--coordinator", required=True, type=Path, help="compiled tachi-coordinator")
    parser.add_argument("--accounts", required=True, type=Path, help="compiled tachi-accounts")
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix="qa-enrollment-") as temporary:
        root = Path(temporary)
        (root / "Packages").symlink_to(args.service_root.resolve() / "Packages", target_is_directory=True)
        fixture = root / "qa" / "EnrollmentFixture"
        shutil.copytree(Path(__file__).with_name("EnrollmentFixture"), fixture,
                        ignore=shutil.ignore_patterns(".build", ".swiftpm"))
        subprocess.run(["swift", "build", "--package-path", fixture, "--product", "Provision"], check=True)
        bin_dir = subprocess.check_output(["swift", "build", "--package-path", fixture, "--show-bin-path"],
                                          text=True).strip()
        suite = unittest.TestSuite()
        for case in (EnrollmentHTTPCheck, SoloHTTPCheck):
            for test in unittest.defaultTestLoader.loadTestsFromTestCase(case):
                test.service_command = (args.coordinator.resolve(),)
                test.operator_command = (args.accounts.resolve(),)
                test.provisioner = Path(bin_dir) / "Provision"
                suite.addTest(test)
        return 0 if unittest.TextTestRunner(verbosity=2).run(suite).wasSuccessful() else 1


if __name__ == "__main__":
    sys.exit(main())
