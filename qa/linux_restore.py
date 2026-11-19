"""Exercise the packaged Swift operator and coordinator across a SQLite online backup."""
from pathlib import Path
import subprocess
import sys
import time
import unittest

from http_lab import CoordinatorLab


class RestoreCheck(CoordinatorLab):
    def test_resume_from_online_backup(self):
        with self.serve(self.service_command, "--db", self.database, "--reference-teams"):
            invitation = self.directory / "invite"
            self.operator("invite-client", "example", "--out", invitation, "--scope", "teams:manage",
                          "--scope", "messages:send", "--scope", "sessions:read")
            credential = self.request("POST", "/v1/client/pair", 201,
                                      payload={"invitation": invitation.read_text().strip()})
            token = credential["token"]
            summary = self.request("POST", "/v1/reference-teams", 200, token=token,
                                   payload={"creationID": "restore", "turnLimit": 1})
            path = "/v1/reference-teams/" + summary["teamID"]
            self.request("POST", path + "/run", 200, token=token, payload={"state": "paused"})
            draft = {"messageID": "first", "audience": "lead", "text": "count words"}
            self.request("POST", path + "/messages", 200, token=token, payload=draft)
            subprocess.run(["sqlite3", "-readonly", self.database, ".backup snapshot.sqlite"],
                           cwd=self.directory, check=True, timeout=10)

        snapshot = self.directory / "snapshot.sqlite"
        integrity = subprocess.check_output(["sqlite3", "-readonly", snapshot, "PRAGMA integrity_check;"],
                                            text=True, timeout=10)
        self.assertEqual(integrity.strip(), "ok")
        restored = self.directory / "restored"
        restored.mkdir(mode=0o700)
        subprocess.run(["sqlite3", "-readonly", snapshot, ".backup coordinator.sqlite"],
                       cwd=restored, check=True, timeout=10)
        with self.serve(self.service_command, "--db", restored / "coordinator.sqlite", "--reference-teams"):
            team = self.request("GET", path, 200, token=token)
            self.assertEqual((team["runState"], team["turnsUsed"]), ("paused", 0))
            self.request("POST", path + "/messages", 200, token=token, payload=draft)
            self.request("POST", path + "/run", 200, token=token, payload={"state": "running"})
            end = time.monotonic() + 10
            while True:
                rows = self.request("GET", path + "/messages", 200, token=token)["messages"]
                self.assertEqual(len(rows), 1)
                self.assertEqual(len(rows[0]["deliveries"]), 1)
                delivery = rows[0]["deliveries"][0]
                if delivery["state"] == "completed":
                    break
                self.assertLess(time.monotonic(), end, "restored reference turn did not complete")
                time.sleep(.05)
            self.assertTrue(delivery["result"])
            self.assertEqual(self.request("GET", path, 200, token=token)["turnsUsed"], 1)


if __name__ == "__main__":
    service, operator = sys.argv[1:]
    RestoreCheck.service_command = (str(Path(service).resolve()),)
    RestoreCheck.operator_command = (str(Path(operator).resolve()),)
    unittest.main(argv=sys.argv[:1])
