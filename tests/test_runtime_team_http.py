import json
import os
import re
import sqlite3
import subprocess
import sys
import tempfile
import time
import unittest
from concurrent.futures import ThreadPoolExecutor
from contextlib import closing
from http.client import HTTPConnection
from pathlib import Path

from tachi.hosts import AccountStore
from tachi.runtime import AdapterIdentity
from tachi.runtime.queue import TeamQueue


ROOT = "/v1/reference-teams"
ALL = {"sessions:read", "messages:send", "teams:manage"}


class ReferenceTeamHTTPTests(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.path = Path(tmp.name) / "store.sqlite"
        self.accounts = AccountStore(self.path)
        self.proc = None
        self.addCleanup(self.stop)
        self.start()
        self.owner = self.pair("operator-a")
        self.sibling = self.pair("operator-a")
        self.other = self.pair("operator-b")

    def start(self, enabled=True, *, legacy=False):
        binary = None if legacy else os.environ.get("TACHI_TEST_COORDINATOR")
        self.swift_process = bool(binary)
        args = ([binary] if binary else [sys.executable, "-m", "tachi"]) + ["--db", str(self.path), "--port", "0"]
        if enabled:
            args.append("--reference-teams")
        self.proc = subprocess.Popen(args, stdout=subprocess.PIPE, text=True,
                                     env={**os.environ, "PYTHONWARNINGS": "error"})
        line = self.proc.stdout.readline()
        match = re.search(r"127\.0\.0\.1:(\d+)", line)
        self.assertIsNotNone(match, line)
        self.port = int(match[1])

    def stop(self):
        if self.proc:
            self.proc.terminate()
            status = self.proc.wait(timeout=5)
            self.proc.stdout.close()
            if self.swift_process:
                self.assertEqual(status, 0, "Swift service must shut down cleanly on SIGTERM")
            self.proc = None

    def request(self, method, path, token=None, payload=None, status=200):
        headers = {"Content-Type": "application/json"}
        if token:
            headers["Authorization"] = "Bearer " + token
        conn = HTTPConnection("127.0.0.1", self.port, timeout=5)
        try:
            conn.request(method, path, json.dumps(payload) if payload is not None else None, headers)
            response = conn.getresponse()
            data = json.load(response)
            self.assertEqual(response.status, status, data)
            self.assertEqual(response.getheader("Cache-Control"), "no-store")
            return data
        finally:
            conn.close()

    def pair(self, human, scopes=ALL):
        invitation = self.accounts.issue_client_invitation(human, scopes)
        return self.request("POST", "/v1/client/pair", payload={"invitation": invitation}, status=201)

    def create(self, who=None, creation="local", limit=4):
        return self.request("POST", ROOT, (who or self.owner)["token"], {"creationID": creation, "turnLimit": limit})

    def messages(self, path, who):
        return self.request("GET", path + "/messages", who["token"])["messages"]

    def wait_delivery(self, path, message, state):
        end = time.monotonic() + 5
        while time.monotonic() < end:
            rows = self.messages(path, self.sibling)
            for row in rows:
                if row["messageID"] == message and row["deliveries"][0]["state"] == state:
                    return row
            time.sleep(0.02)
        self.fail(f"delivery did not reach {state}")

    def test_sibling_intervention_restart_budget_completion_and_offline_resend(self):
        team = self.create(limit=1)
        self.assertEqual(team, {"teamID": team["teamID"], "mode": "reference", "runState": "running", "turnLimit": 1,
                                "turnsUsed": 0, "assistants": ["lead", "peer"]})
        path = ROOT + "/" + team["teamID"]
        self.assertEqual(self.request("GET", ROOT, self.sibling["token"]), {"teams": [team]})
        self.request("POST", path + "/run", self.sibling["token"], {"state": "paused"})
        room = {"messageID": "draft_1", "text": "check these words", "audience": "room", "mentions": ["lead"]}
        self.request("POST", path + "/messages", self.owner["token"], room)
        self.stop()
        self.start()
        self.request("POST", path + "/messages", self.owner["token"], room)
        self.assertEqual(self.messages(path, self.sibling)[0]["deliveries"][0]["state"], "queued")
        direct = {"messageID": "private", "text": "edit", "audience": "peer", "replyTo": "draft_1"}
        self.request("POST", path + "/messages", self.sibling["token"], direct)
        self.request("POST", path + "/run", self.sibling["token"], {"state": "running"})
        row = self.wait_delivery(path, "draft_1", "completed")
        self.assertEqual(row, {"messageID": "draft_1", "text": "check these words", "author": "you",
                               "audience": "room", "mentions": ["lead"], "replyTo": None,
                               "deliveries": [{"assistant": "lead", "state": "completed",
                                               "result": "Reference lead counted 3 words."}]})
        self.assertEqual(self.messages(path, self.sibling)[1]["deliveries"][0]["state"], "queued")
        self.request("POST", path + "/run", self.sibling["token"], {"state": "running", "turnLimit": 2})
        reply = self.wait_delivery(path, "private", "completed")
        self.assertEqual((reply["replyTo"], reply["audience"]), ("draft_1", "peer"))
        ended = self.request("POST", path + "/run", self.owner["token"], {"state": "completed"})
        self.assertEqual((ended["turnsUsed"], ended["runState"]), (2, "completed"))
        self.request("POST", path + "/messages", self.owner["token"], room)
        self.assertEqual(len(self.messages(path, self.owner)), 2)
        self.request("POST", path + "/messages", self.owner["token"], dict(room, text="changed"), 409)

    def test_revoked_origin_denied_and_sibling_can_send_on_the_same_session(self):
        path = ROOT + "/" + self.create()["teamID"]
        self.request("POST", path + "/run", self.owner["token"], {"state": "paused"})
        for who, message in ((self.owner, "revoked"), (self.sibling, "authorized")):
            self.request("POST", path + "/messages", who["token"],
                         {"messageID": message, "text": "check", "audience": "lead"})
        self.accounts.revoke_client("operator-a", self.owner["clientID"])
        self.request("GET", path, self.owner["token"], status=401)
        self.request("POST", path + "/run", self.sibling["token"], {"state": "running"})
        self.wait_delivery(path, "revoked", "denied")
        self.wait_delivery(path, "authorized", "completed")
        self.assertEqual(self.request("GET", path, self.sibling["token"])["turnsUsed"], 1)

    def test_scopes_cross_human_isolation_and_server_selected_bindings(self):
        team = self.create()
        path = ROOT + "/" + team["teamID"]
        self.assertEqual(self.request("GET", ROOT, self.other["token"]), {"teams": []})
        self.request("GET", path + "/messages", self.other["token"], status=404)
        self.request("POST", path + "/run", self.other["token"], {"state": "paused"}, 404)
        reader = self.pair("operator-a", {"sessions:read"})["token"]
        self.assertEqual(self.request("GET", path, reader), team)
        self.request("POST", path + "/messages", reader, {"messageID": "no", "audience": "room", "text": "no"}, 403)
        self.request("POST", path + "/run", reader, {"state": "paused"}, 403)
        self.request("POST", ROOT, reader, {"creationID": "new", "turnLimit": 1}, 403)
        self.request("GET", ROOT, status=401)
        self.request("POST", ROOT, self.owner["token"],
                     {"creationID": "bad", "turnLimit": 1, "accountID": "external"}, 400)
        for invalid in (True, 1.5, "2", 0, 1001):
            self.request("POST", ROOT, self.owner["token"], {"creationID": "bad", "turnLimit": invalid}, 400)

        self.request("POST", path + "/messages", self.owner["token"],
                     {"messageID": "bad", "text": "check", "audience": "room", "_tachi_host_scope": {}}, 400)
        another = self.create(who=self.other)
        self.assertNotEqual(team["teamID"], another["teamID"])
        with closing(sqlite3.connect(self.path)) as db:
            bindings = list(db.execute("SELECT provider,session FROM rt_assistant"))
        self.assertEqual({r[0] for r in bindings}, {"tachi-reference"})
        self.assertEqual(len({r[1] for r in bindings}), 4)

    def test_reference_worker_leaves_other_queue_work_untouched(self):
        principal = self.accounts.authenticate(self.owner["token"])
        self.accounts.create_team(principal.human_id, principal.client_id, "another-runtime-team")
        with closing(TeamQueue(self.path, self.accounts)) as queue:
            queue.add_assistant("another-runtime-team", principal, "lead",
                                AdapterIdentity("other-fixture", "account", "assistant"), "session")
            queue.create_run("another-runtime-team", principal, "run", "assistant:lead", turn_limit=1)
            queue.post("another-runtime-team", principal, "run", "pending", {}, direct_to="assistant:lead")
            path = ROOT + "/" + self.create()["teamID"]
            self.request("POST", path + "/messages", self.owner["token"],
                         {"messageID": "reference", "text": "example", "audience": "lead"})
            self.wait_delivery(path, "reference", "completed")
            external, = queue.history("another-runtime-team", principal, "run")
            self.assertEqual(external["deliveries"][0]["state"], "queued")
            self.assertEqual(queue.run_status("another-runtime-team", principal, "run")["turns"], 0)

    @unittest.skipUnless(os.environ.get("TACHI_TEST_COORDINATOR"), "requires a Swift coordinator binary")
    def test_legacy_reference_team_http_cutover_and_readback(self):
        self.stop()
        self.path = self.path.with_name("legacy.sqlite")
        self.accounts = AccountStore(self.path)
        self.start(legacy=True)
        origin = self.pair("editor")
        sibling = self.pair("editor")
        token = sibling["token"]
        team = self.create(who=sibling)
        path = ROOT + "/" + team["teamID"]
        self.request("POST", path + "/run", token, {"state": "paused"})
        revoked = {"messageID": "withdrawn", "audience": "lead", "text": "old client"}
        pending = {"messageID": "draft", "audience": "lead", "text": "two words"}
        self.request("POST", path + "/messages", origin["token"], revoked)
        self.request("POST", path + "/messages", token, pending)
        self.stop()
        self.start()
        self.assertEqual(self.create(who=sibling)["teamID"], team["teamID"])
        self.assertEqual(self.request("GET", path, token)["runState"], "paused")
        self.request("POST", path + "/messages", token, pending)
        self.accounts.revoke_client("editor", origin["clientID"])
        self.request("POST", path + "/run", token, {"state": "running"})
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            rows = self.messages(path, sibling)
            if [r["deliveries"][0]["state"] for r in rows] == ["denied", "completed"]:
                break
            time.sleep(0.05)
        else:
            self.fail("queued legacy messages did not reach their expected states")
        self.assertEqual(rows[1]["deliveries"][0]["result"], "Reference lead counted 2 words.")
        self.stop()
        self.start(legacy=True)
        self.assertEqual(self.messages(path, sibling), rows)

    def test_competing_creation_resumes_same_team_and_disabled_mode_hides_routes(self):
        with ThreadPoolExecutor(max_workers=2) as pool:
            results = list(pool.map(self.create, [self.owner, self.sibling]))
        self.assertEqual(results[0], results[1])
        self.request("POST", ROOT, self.owner["token"], {"creationID": "local", "turnLimit": 999}, 409)
        self.stop()
        self.start(enabled=False)
        self.request("GET", ROOT, self.sibling["token"], status=404)
        self.request("GET", "/v1/client/me", self.sibling["token"])


if __name__ == "__main__":
    unittest.main()
