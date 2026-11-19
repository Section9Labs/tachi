"""Upgrade two packaged coordinator revisions with one external POST in flight."""
import signal
import sqlite3
import sys
import time
import unittest
import uuid
from contextlib import closing
from pathlib import Path
from threading import Event

from solo_http import RoutineLab, routine_listener


class UpgradeCheck(RoutineLab):
    def test_upgrade_after_observed_post(self):
        release = Event()
        task_id = str(uuid.uuid4())
        body = {"task_id": task_id, "payload": {"text": "Upgrade fixture"}}
        path = "/v1/solo/routines/upgrade/tasks"
        detail = path + "/" + task_id

        with routine_listener("/upgrade", None, hold_reply=release) as (url, secret, observations, received):
            options = self.service_options("upgrade-owner", "upgrade", url, secret)
            config = Path(options[options.index("--solo-routines-file") + 1])
            config.chmod(0o400)
            try:
                with self.serve(self.previous_service, *options) as previous:
                    token = self.pair("upgrade-owner", "owner.invitation", "messages:send", "sessions:read", "teams:manage")
                    self.request("POST", path, 202, payload=body, token=token)
                    self.assertTrue(received.wait(5), "previous coordinator did not submit")
                    self.assertEqual(observations(), [("/upgrade", True, body["payload"])])
                    previous.kill()
                    self.assertEqual(previous.wait(timeout=5), -signal.SIGKILL)
            finally:
                release.set()

            with self.serve(self.service_command, *options):
                snapshot = {"routine_id": "upgrade", "task_id": task_id, "state": "uncertain",
                            "native_result_available": False, "result": None}
                self.assertEqual(self.request("GET", detail, 200, token=token), snapshot)
                self.assertEqual(self.request("POST", path, 202, payload=body, token=token), snapshot)
                workspace = {"workspace_id": str(uuid.uuid4())}
                self.assertEqual(self.request("POST", "/v1/workspaces", 201, payload=workspace, token=token),
                                 {**workspace, "role": "owner"})
                self.assertEqual(config.stat().st_mode & 0o777, 0o400)
                # Cover multiple dispatcher iterations before the final durable-state audit.
                time.sleep(1)
                self.assertEqual(self.request("GET", detail, 200, token=token), snapshot)
            self.assertEqual(observations(), [("/upgrade", True, body["payload"])])

        with closing(sqlite3.connect(self.database.as_uri() + "?mode=ro", uri=True)) as db:
            self.assertEqual(db.execute("SELECT message,state FROM rt_delivery").fetchall(), [(task_id, "uncertain")])
            self.assertEqual(db.execute("SELECT COUNT(*) FROM rt_event").fetchone(), (0,))


if __name__ == "__main__":
    previous, accounts, candidate = (str(Path(argument).resolve()) for argument in sys.argv[1:])
    UpgradeCheck.previous_service = (previous,)
    UpgradeCheck.operator_command = (accounts,)
    UpgradeCheck.service_command = (candidate,)
    unittest.main(argv=sys.argv[:1])
