"""Black-box checks for paired-client HTTP through a configured solo connector."""

from contextlib import closing, contextmanager
from http.server import BaseHTTPRequestHandler, HTTPServer
import json
import os
import secrets
import sqlite3
import time
import uuid
from threading import Event, Lock, Thread

from http_lab import CoordinatorLab


@contextmanager
def routine_listener(path, reply_status, *, hold_reply=None):
    """Observe each POST before sending headers or dropping the connection."""
    secret = secrets.token_urlsafe(32)
    observations = []
    lock = Lock()
    posted = Event()

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *args):
            pass

        def do_POST(self):
            size = int(self.headers.get("Content-Length", "0"))
            try:
                body = json.loads(self.rfile.read(size))
            except (ValueError, UnicodeDecodeError):
                body = None
            authorized = self.headers.get("Authorization") == f"Bearer {secret}"
            with lock:
                observations.append((self.path, authorized, body))
                posted.set()
            if hold_reply is not None:
                hold_reply.wait(timeout=30)
            if reply_status is None:
                self.close_connection = True
                return
            self.send_response(reply_status if authorized and self.path == path else 403)
            self.send_header("Content-Length", "0")
            self.end_headers()

    def snapshot():
        with lock:
            return list(observations)

    with HTTPServer(("127.0.0.1", 0), Handler) as server:
        worker = Thread(target=server.serve_forever, kwargs={"poll_interval": 0.05})
        worker.start()
        try:
            yield f"http://127.0.0.1:{server.server_port}{path}", secret, snapshot, posted
        finally:
            server.shutdown()
            worker.join()


class RoutineLab(CoordinatorLab):
    def service_options(self, human, routine, url, secret, filename="routines.json"):
        config = self.directory / filename
        entry = {"human_id": human, "routine_id": routine, "webhook_url": url, "webhook_secret": secret}
        with os.fdopen(os.open(config, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600), "w") as file:
            json.dump({"routines": [entry]}, file)
        return ("--db", self.database, "--solo-routines-file", config, "--solo-loopback-fixture")


class SoloHTTPCheck(RoutineLab):
    routines = "/v1/solo/routines"

    def verify_flow(self, routine, reply_status, final_state):
        human = "synthetic-editor"
        both = ("sessions:read", "messages:send")
        task_id = str(uuid.uuid4())
        body = {"task_id": task_id, "payload": {"text": "Count the two sample rows."}}
        submit = f"{self.routines}/{routine}/tasks"
        history = submit + "/" + task_id
        settled = {"routine_id": routine, "task_id": task_id, "state": final_state,
                   "native_result_available": False, "result": None}

        path = f"/fixture/{routine}"
        expected = [(path, True, body["payload"])]
        in_flight = (dict(settled, state="queued"), dict(settled, state="uncertain"))
        with routine_listener(path, reply_status) as (url, secret, observed, posted):
            options = self.service_options(human, routine, url, secret)
            with self.serve(self.service_command, *options, cwd=self.service_root):
                owner = self.pair(human, "origin", *both)
                sibling = self.pair(human, "sibling", *both)
                reader = self.pair(human, "read-only", "sessions:read")
                other = self.pair("synthetic-neighbor", "other", *both)
                self.request("GET", self.routines, 401, token="synthetic-invalid")
                catalogue = self.request("GET", self.routines, 200, token=owner)
                self.assertTrue(catalogue == {"routines": [{"routine_id": routine, "provider": "grok-bot"}]},
                                "unexpected owner routine catalogue")
                self.assertTrue(self.request("GET", self.routines, 200, token=other) == {"routines": []},
                                "foreign client discovered a routine")
                self.request("POST", submit, 403, token=reader, payload=body)
                self.request("POST", submit, 404, token=other, payload=body)
                self.assertFalse(observed(), "an unauthorized request reached the webhook")

                receipt = self.request("POST", submit, 202, token=owner, payload=body)
                self.assertTrue(receipt == settled or receipt in in_flight,
                                "unexpected initial task snapshot")
                self.assertTrue(posted.wait(15), "POST did not reach the webhook before the first status read")
                deadline = time.monotonic() + 15
                while True:
                    snapshot = self.request("GET", history, 200, token=sibling)
                    if snapshot == settled:
                        break
                    self.assertTrue(snapshot in in_flight, "unexpected task snapshot")
                    if time.monotonic() >= deadline:
                        self.fail("task did not settle before the deadline")
                    time.sleep(0.05)
                self.request("GET", history, 404, token=other)
                self.assertTrue(observed() == expected,
                                "expected one authorized POST containing exactly the routine payload")

            with self.serve(self.service_command, *options, cwd=self.service_root):
                self.assertTrue(self.request("GET", history, 200, token=reader) == settled,
                                "task snapshot changed after restart")
                replay = self.request("POST", submit, 202, token=sibling, payload=body)
                self.assertTrue(replay == settled, "identical resend did not return the stored snapshot")
                changed = dict(body, payload={"text": "Different sample."})
                self.request("POST", submit, 409, token=owner, payload=changed)
                self.request("GET", history, 404, token=other)
                self.assertTrue(self.request("GET", history, 200, token=owner) == settled,
                                "task snapshot changed after resend")
            self.assertTrue(observed() == expected,
                            "restart or retry caused an additional webhook submission")

        # The public snapshot does not expose event counts. Audit the stopped disposable DB read-only.
        with closing(sqlite3.connect(self.database.as_uri() + "?mode=ro", uri=True)) as db:
            self.assertEqual(db.execute("SELECT message FROM rt_delivery").fetchall(), [(task_id,)])
            events = db.execute("SELECT kind, payload FROM rt_event ORDER BY seq").fetchall()
        if reply_status is None:
            self.assertFalse(events, "an unobserved response created a durable event")
        elif reply_status == 200:
            self.assertEqual([kind for kind, _ in events], ["accepted"])
            self.assertTrue(json.loads(events[0][1]) == {"routine_accepted": True, "native_reply": False,
                                                         "native_session_observed": False},
                            "unexpected acceptance receipt")
        else:
            self.assertEqual([kind for kind, _ in events], ["failed"])
            self.assertTrue(json.loads(events[0][1]) == {"reason": "rejected", "status": reply_status},
                            "unexpected rejection receipt")

    def test_observed_acceptance_survives_restart(self):
        self.verify_flow("accept", 200, "accepted")

    def test_lost_reply_survives_restart_without_replay(self):
        self.verify_flow("lost", None, "uncertain")

    def test_observed_rejection_survives_restart(self):
        self.verify_flow("reject", 503, "rejected")
