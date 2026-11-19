"""Exercise the installed systemd service on a disposable Ubuntu runner."""
import subprocess
import unittest
import uuid

from http_lab import CoordinatorLab


class SystemdCheck(CoordinatorLab):
    def test_workspace_survives_service_restart(self):
        unit = "tachi-coordinator.service"
        self.port = 8743

        def ready():
            subprocess.run(["curl", "--fail", "--silent", "--show-error",
                            "--retry", "10", "--retry-delay", "1", "--retry-connrefused",
                            "--max-time", "2", "--output", "/dev/null",
                            "http://127.0.0.1:8743/v1/status"], check=True, timeout=30)
            subprocess.run(["systemctl", "is-active", "--quiet", unit], check=True)

        ready()
        subprocess.run(["systemctl", "is-enabled", "--quiet", unit], check=True)
        operator = ["sudo", "-n", "-u", "tachi"]
        ticket = "/var/lib/tachi/" + str(uuid.uuid4()) + ".invitation"
        subprocess.run([*operator, "/usr/local/bin/tachi-accounts", "invite-client",
                        "--db", "/var/lib/tachi/coordinator.sqlite", "--human-id", "systemd-test",
                        "--scope", "teams:manage", "--scope", "sessions:read", "--out", ticket],
                       check=True)
        try:
            invitation = subprocess.check_output([*operator, "cat", ticket], text=True).strip()
            token = self.request("POST", "/v1/client/pair", 201, payload={"invitation": invitation})["token"]
        finally:
            subprocess.run([*operator, "rm", ticket], check=True)

        workspace_id = str(uuid.uuid4())
        workspace = {"workspace_id": workspace_id, "role": "owner"}
        self.assertEqual(self.request("POST", "/v1/workspaces", 201, token=token,
                                      payload={"workspace_id": workspace_id}), workspace)
        subprocess.run(["sudo", "-n", "systemctl", "restart", unit], check=True, timeout=30)
        ready()
        self.assertEqual(self.request("GET", "/v1/workspaces", 200, token=token),
                         {"workspaces": [workspace]})


if __name__ == "__main__":
    unittest.main()
