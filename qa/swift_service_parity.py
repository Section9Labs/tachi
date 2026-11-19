"""Run the v1 HTTP oracles against Swift or run a Python-to-Python control."""

import argparse
from pathlib import Path
import subprocess
import sys
import unittest

from artifact_http import ArtifactHTTPCheck
from check_client_pairing import ClientPairingCheck
from check_reference_http import ReferenceTeamCheck
from export_http import WorkspaceExportCheck
from http_lab import CoordinatorLab, PYTHON_OPERATOR, PYTHON_SERVICE
from probe_status import check_status
from solo_http import SoloHTTPCheck
from workspace_http import WorkspaceHTTPCheck


class BootstrapParity(CoordinatorLab):
    def test_status_and_unknown_route(self):
        with self.serve(self.service_command, cwd=self.service_root):
            check_status(self.port)
            self.assertEqual(self.request("GET", "/v1/status/unknown", 404), {"error": "not_found"})


class PairingMigration(CoordinatorLab):
    legacy_root = None

    def legacy_invitation(self, human, label, scope):
        path = self.directory / label
        subprocess.run([*PYTHON_OPERATOR, "invite-client", "--db", self.database, "--human-id", human,
                        "--scope", scope, "--out", path], cwd=self.legacy_root, check=True, timeout=10)
        return path.read_text().strip()

    def redeem(self, invitation, status=201):
        return self.request("POST", "/v1/client/pair", status, payload={"invitation": invitation})

    def check_identity(self, credential, human, scope):
        me = self.request("GET", "/v1/client/me", 200, token=credential["token"])
        expected = {"clientID": credential["clientID"], "humanID": human, "scopes": [scope]}
        self.assertTrue(me == expected, "stored client identity or scopes changed")

    def test_previous_pairing_database_survives_cutover_and_restart(self):
        # Only the operator CLI and the old HTTP service create the pre-cutover state.
        db_options = ("--db", self.database)
        with self.serve(PYTHON_SERVICE, *db_options, cwd=self.legacy_root):
            consumed = self.legacy_invitation("editor", "first", "messages:send")
            active = self.redeem(consumed)
            revoked = self.redeem(self.legacy_invitation("editor", "second", "sessions:read"))
            pending = self.legacy_invitation("reader", "third", "sessions:read")
            self.check_identity(active, "editor", "messages:send")
            self.check_identity(revoked, "editor", "sessions:read")
            subprocess.run([*PYTHON_OPERATOR, "revoke-client", *db_options, "--human-id", "editor",
                            "--client-id", revoked["clientID"]], cwd=self.legacy_root, check=True, timeout=10)
            self.request("GET", "/v1/client/me", 401, token=revoked["token"])

        with self.serve(self.service_command, *db_options, cwd=self.service_root):
            self.check_identity(active, "editor", "messages:send")
            self.request("GET", "/v1/client/me", 401, token=revoked["token"])
            self.redeem(consumed, 401)
            new = self.redeem(pending)
            self.check_identity(new, "reader", "sessions:read")
            self.operator("revoke-client", "editor", "--client-id", active["clientID"])

        with self.serve(self.service_command, *db_options, cwd=self.service_root):
            for credential in (active, revoked):
                self.request("GET", "/v1/client/me", 401, token=credential["token"])
            self.redeem(pending, 401)
            self.check_identity(new, "reader", "sessions:read")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("stage", choices=("status", "pairing", "reference-teams", "solo", "workspaces", "artifacts", "export"))
    parser.add_argument("--service-root", type=Path, default=Path.cwd(), help="candidate checkout")
    parser.add_argument("--legacy-root", type=Path, default=Path.cwd(), help="Python fixture producer checkout")
    parser.add_argument("--python-control", action="store_true", help="use Python for the candidate as well")
    args = parser.parse_args()
    if args.stage in ("solo", "workspaces", "artifacts", "export") and args.python_control:
        parser.error(f"The {args.stage} stage requires the Swift coordinator.")
    if args.stage == "artifacts":
        # The trusted task-source fixture uses the existing repository queue writer.
        sys.path.append(str(Path(__file__).resolve().parents[1]))
    root = args.service_root.resolve()
    service, operator = PYTHON_SERVICE, PYTHON_OPERATOR
    if not args.python_control:
        subprocess.run(["swift", "build", "--product", "tachi-coordinator"], cwd=root, check=True)
        service = ("swift", "run", "tachi-coordinator")
        if args.stage != "status":
            package = root / "Packages" / "TachiAccounts"
            subprocess.run(["swift", "build", "--package-path", package, "--product", "tachi-accounts"],
                           cwd=root, check=True)
            operator = ("swift", "run", "--package-path", package, "--skip-build", "tachi-accounts")

        if args.stage in ("solo", "workspaces", "artifacts", "export"):
            bin_dir = subprocess.check_output(["swift", "build", "--show-bin-path"], cwd=root, text=True).strip()
            service = (Path(bin_dir) / "tachi-coordinator",)
    checks = {"status": (BootstrapParity,), "pairing": (ClientPairingCheck, PairingMigration),
              "reference-teams": (ReferenceTeamCheck,), "solo": (SoloHTTPCheck,),
              "workspaces": (WorkspaceHTTPCheck,), "artifacts": (ArtifactHTTPCheck,), "export": (WorkspaceExportCheck,)}
    suite = unittest.TestSuite()
    for case in checks[args.stage]:
        for test in unittest.defaultTestLoader.loadTestsFromTestCase(case):
            test.service_command = service
            test.operator_command = operator
            test.service_root = root
            test.legacy_root = args.legacy_root.resolve()
            suite.addTest(test)
    mode = "Python control" if args.python_control else "Swift candidate"
    print(f"{mode} | {args.stage}", flush=True)
    return 0 if unittest.TextTestRunner(verbosity=2).run(suite).wasSuccessful() else 1


if __name__ == "__main__":
    sys.exit(main())
