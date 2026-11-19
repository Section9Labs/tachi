import sqlite3
import subprocess
import sys
import textwrap
import tempfile
import threading
import unittest
from dataclasses import replace
from pathlib import Path

from tachi.hosts import AccountStore, HostStore
from tachi.runtime import AdapterEvent, AdapterIdentity, AdapterRegistry, Capability, EventKind
from tachi.runtime.queue import HostScope, TeamQueue
from tachi.runtime.reference import ReferenceAdapter


class QueueTests(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.path = Path(temp.name) / "queue.sqlite"
        self.accounts = AccountStore(self.path)
        self.owner, self.reader, self.outsider = [self.client(name) for name in ("owner", "reader", "outsider")]
        self.accounts.create_team(self.owner.human_id, self.owner.client_id, "team")
        self.invite_reader()
        self.q = self.open_queue()
        self.registry = AdapterRegistry()
        self.adapters = {}
        for name in ("lead", "peer"):
            identity = AdapterIdentity("fixture", name, "assistant")
            self.q.add_assistant("team", self.owner, name, identity, "session")
            self.adapters[name] = ReferenceAdapter(identity)
            self.registry.register(self.adapters[name])
        self.q.create_run("team", self.owner, "brief", "assistant:lead", turn_limit=5)

    def client(self, name):
        inv = self.accounts.issue_client_invitation(name, {"sessions:read", "messages:send", "teams:manage"})
        return self.accounts.authenticate(self.accounts.redeem_client(inv).token)

    def invite_reader(self):
        invitation = self.accounts.invite_member("owner", self.owner.client_id, "team", "reader")
        self.accounts.accept_invitation("reader", self.reader.client_id, invitation)

    def open_queue(self):
        queue = TeamQueue(self.path, self.accounts)
        self.addCleanup(queue.close)
        return queue

    def post(self, message, **kwargs):
        self.q.post("team", self.owner, "brief", message, {"text": message}, **kwargs)

    def history(self, actor=None):
        return self.q.history("team", actor or self.owner, "brief")

    def status(self, index=0):
        return self.history()[index]["deliveries"][0]["state"]

    def test_room_direct_mentions_replies_and_audience(self):
        self.post("brief")
        self.post("check", mentions=("assistant:peer",), reply_to="brief", capability=Capability.TASK)
        request = self.q.dispatch_one(self.registry)
        event = AdapterEvent(self.adapters["peer"].identity, "session", request, "result",
                             EventKind.COMPLETED, {"operation": "task"})
        self.q.post_reply(event, "source", {"text": "synthetic finding"}, direct_to="assistant:lead")
        with self.assertRaises(PermissionError):
            self.q.post_reply(replace(event, event_id="invented"), "fake", {}, direct_to="assistant:lead")
        result = self.q.dispatch_one(self.registry)
        back = AdapterEvent(self.adapters["lead"].identity, "session", result, "result",
                            EventKind.COMPLETED, {"operation": "message"})
        self.q.post_reply(back, "thanks", {}, direct_to="assistant:peer")
        with self.assertRaises(PermissionError):
            self.q.post_reply(back, "leak", {})
        with self.assertRaises(PermissionError):
            self.q.post("team", self.reader, "brief", "guess", {}, direct_to="assistant:peer", reply_to="source")
        self.q.dispatch_one(self.registry)
        self.assertIsNone(self.q.dispatch_one(self.registry))
        self.assertEqual([row["message"] for row in self.history(self.reader)], ["brief", "check"])
        self.assertEqual(self.adapters["lead"].calls[0].payload, {"text": "synthetic finding"})
        self.assertEqual(self.history()[1]["deliveries"][0]["events"][0]["kind"], "completed")

    def test_duplicate_envelope_atomic_across_reopen(self):
        self.post("once", mentions=("assistant:peer", "assistant:lead"))
        self.q = self.open_queue()
        self.post("once", mentions=("assistant:lead", "assistant:peer"))
        with self.assertRaises(ValueError):
            self.post("once", mentions=("assistant:peer",))
        with self.assertRaises(PermissionError):
            self.post("partial", mentions=("assistant:lead", "assistant:unknown"))
        self.assertEqual(len(self.history()), 1)
        self.assertEqual(len(self.history()[0]["deliveries"]), 2)

    def test_restart_during_native_effect_then_late_reconciliation(self):
        def crash(request):
            self.adapters["lead"].calls.append(request)
            raise SystemExit("simulate coordinator exit before response")

        self.adapters["lead"].dispatch = crash
        for name, target in [("first", "lead"), ("next", "lead"), ("unrelated", "peer")]:
            self.post(name, direct_to=f"assistant:{target}")
        with self.assertRaises(SystemExit):
            self.q.dispatch_one(self.registry)
        self.q.close()
        self.q = self.open_queue()
        self.assertEqual(self.status(), "uncertain")
        self.q.dispatch_one(self.registry)
        self.assertEqual(self.status(2), "completed")
        self.assertIsNone(self.q.dispatch_one(self.registry))
        request, = self.adapters["lead"].calls
        with self.assertRaises(ValueError):
            self.q.retry_blocked("team", self.owner, request.request_id)
        event = AdapterEvent(request.identity, request.session_id, request.request_id,
                             "native-receipt", EventKind.COMPLETED, {"result": "verified"})
        for bad in [replace(event, session_id="wrong"), replace(event, identity=self.adapters["peer"].identity)]:
            with self.assertRaises(ValueError):
                self.q.record(bad)
        self.q.record(event)
        self.q.record(event)
        self.q.record(replace(event, event_id="late-ack", kind=EventKind.ACCEPTED))
        with self.assertRaises(ValueError):
            self.q.record(replace(event, payload={"result": "different"}))
        self.assertEqual(self.status(), "completed")
        self.assertEqual(len(self.history()[0]["deliveries"][0]["events"]), 2)
        self.adapters["lead"].dispatch = ReferenceAdapter.dispatch.__get__(self.adapters["lead"])
        self.q.dispatch_one(self.registry)
        self.assertEqual([r.payload["text"] for r in self.adapters["lead"].calls], ["first", "next"])

    def test_worker_process_exit_after_effect_does_not_repeat_submission(self):
        self.post("interrupted", direct_to="assistant:lead")
        marker = self.path.with_suffix(".receipt")
        child = textwrap.dedent("""
            import os
            import sys
            from pathlib import Path
            from tachi.hosts import AccountStore
            from tachi.runtime import AdapterIdentity, AdapterRegistry
            from tachi.runtime.queue import TeamQueue
            from tachi.runtime.reference import ReferenceAdapter

            class Interrupted(ReferenceAdapter):
                def dispatch(self, request):
                    Path(sys.argv[2]).write_text(request.request_id)
                    os._exit(73)

            registry = AdapterRegistry()
            registry.register(Interrupted(AdapterIdentity("fixture", "lead", "assistant")))
            TeamQueue(sys.argv[1], AccountStore(sys.argv[1])).dispatch_one(registry)
        """)
        process = subprocess.run([sys.executable, "-c", child, self.path, marker], timeout=10)
        self.assertEqual(process.returncode, 73)
        self.q.close()
        self.q = self.open_queue()
        delivery, = self.history()[0]["deliveries"]
        self.assertEqual((delivery["request"], delivery["state"]), (marker.read_text(), "uncertain"))
        self.assertIsNone(self.q.dispatch_one(self.registry))
        self.assertFalse(self.adapters["lead"].calls)

    def test_ambiguous_return_and_acknowledgment_keep_lane_occupied(self):
        self.post("first", direct_to="assistant:peer")
        self.post("second", direct_to="assistant:peer")
        self.adapters["peer"].lose_reply = True
        rid = self.q.dispatch_one(self.registry)
        self.assertEqual(self.status(), "uncertain")
        event = AdapterEvent(self.adapters["peer"].identity, "session", rid, "ack", EventKind.ACCEPTED, {})
        self.q.record(event)
        self.assertEqual(self.status(), "active")
        self.assertIsNone(self.q.dispatch_one(self.registry))
        self.q.intervene("team", self.owner, "brief", "cancelled")
        self.assertEqual((self.status(), self.status(1)), ("active", "cancelled"))
        self.q.record(replace(event, event_id="native-end", kind=EventKind.CANCELLED))
        self.assertEqual(self.status(), "cancelled")
        with self.assertRaises(ValueError):
            self.q.record(replace(event, event_id="bad", kind=EventKind.COMPLETED))

    def test_shared_budget_pause_resume_and_cancellation(self):
        self.q.intervene("team", self.owner, "brief", "paused", turn_limit=1)
        self.post("one", mentions=("assistant:lead", "assistant:peer"))
        with self.assertRaises(PermissionError):
            self.q.intervene("team", self.reader, "brief", "running")
        self.assertIsNone(self.q.dispatch_one(self.registry))
        self.q.intervene("team", self.owner, "brief", "running")
        self.q.dispatch_one(self.registry)
        self.assertIsNone(self.q.dispatch_one(self.registry))
        self.assertEqual(self.q.run_status("team", self.reader, "brief")["turns"], 1)
        self.q.intervene("team", self.owner, "brief", "running", turn_limit=2)
        self.q.dispatch_one(self.registry)
        self.post("later", direct_to="assistant:lead")
        self.q.intervene("team", self.owner, "brief", "cancelled")
        self.assertEqual(self.status(1), "cancelled")
        with self.assertRaises(ValueError):
            self.post("new")
        self.post("later", direct_to="assistant:lead")  # lost client response, exact idempotent replay

    def test_session_and_role_boundaries(self):
        self.accounts.create_team("outsider", self.outsider.client_id, "second")
        with self.assertRaises(sqlite3.IntegrityError):
            self.q.add_assistant("second", self.outsider, "borrowed", identity=self.adapters["lead"].identity,
                              session_id="session")
        with self.assertRaises(PermissionError):
            self.q.history("team", self.outsider, "brief")
        with self.assertRaises(PermissionError):
            self.q.create_run("team", self.reader, "unowned", "assistant:lead", turn_limit=1)
        with self.assertRaises(ValueError):
            self.post("bad", direct_to="")
        with self.assertRaises(ValueError):
            self.q.post("team", self.owner, "brief", "reserved", {"_tachi_host_scope": {}})

    def test_reinvitation_does_not_restore_old_work_direct_history_or_delegation(self):
        self.q.post("team", self.reader, "brief", "task", {}, mentions=("assistant:lead",))
        rid = self.q.dispatch_one(self.registry)
        event = AdapterEvent(self.adapters["lead"].identity, "session", rid, "result",
                             EventKind.COMPLETED, {"operation": "message"})
        self.q.post_reply(event, "delegated", {}, direct_to="assistant:peer")
        self.post("private", direct_to="human:reader")
        self.accounts.revoke_member("owner", self.owner.client_id, "team", "reader")
        with self.assertRaises(PermissionError):
            self.history(self.reader)
        self.invite_reader()
        self.assertEqual([msg["message"] for msg in self.history(self.reader)], ["task"])
        with self.assertRaises(PermissionError):
            self.q.post_reply(event, "revived", {}, direct_to="assistant:peer")
        with self.assertRaises(PermissionError):
            self.q.post("team", self.reader, "brief", "old-private", {},
                        direct_to="human:owner", reply_to="private")
        blocked = self.q.dispatch_one(self.registry)
        self.assertIsNotNone(blocked)
        self.assertFalse(self.adapters["peer"].calls)
        with self.assertRaises(ValueError):
            self.q.retry_blocked("team", self.owner, blocked)
        self.assertIsNone(self.q.dispatch_one(self.registry))
        self.assertFalse(self.adapters["peer"].calls)

    def test_revoked_origin_client_cannot_submit_pending_work(self):
        self.q.post("team", self.reader, "brief", "pending", {}, mentions=("assistant:peer",))
        self.accounts.revoke_client("reader", self.reader.client_id)
        self.q.dispatch_one(self.registry)
        self.assertEqual(self.status(), "denied")
        self.assertFalse(self.adapters["peer"].calls)
        self.post("permitted", direct_to="assistant:peer")
        self.q.dispatch_one(self.registry)
        self.assertEqual(self.status(1), "completed")

    def test_host_rechecked_at_dispatch_and_after_retry(self):
        hosts = HostStore(self.path)
        first, second = [hosts.connect(hosts.pair(hosts.issue_pairing("owner"))) for _ in range(2)]
        grant = hosts.grant("owner", first.host_id, "folder", "read")
        scope = HostScope("owner", first.host_id, grant, "folder", "read", "brief.md")
        self.post("on-host", direct_to="assistant:lead", scope=scope)
        self.post("cloud", direct_to="assistant:peer")
        self.assertIsNone(self.q.dispatch_one(self.registry, host_store=hosts, host_session=second))
        self.q.dispatch_one(self.registry)
        self.assertEqual(self.status(1), "completed")
        hosts.revoke_grant("owner", first.host_id, grant)
        rid = self.q.dispatch_one(self.registry, host_store=hosts, host_session=first)
        self.assertEqual(self.status(), "blocked")
        self.q.retry_blocked("team", self.owner, rid)
        self.q.dispatch_one(self.registry, host_store=hosts, host_session=first)
        self.assertEqual(self.status(), "blocked")
        self.assertFalse(self.adapters["lead"].calls)

    def test_valid_host_scope_reaches_adapter_without_session_secret(self):
        hosts = HostStore(self.path)
        session = hosts.connect(hosts.pair(hosts.issue_pairing("owner")))
        grant = hosts.grant("owner", session.host_id, "folder", "read")
        scope = HostScope("owner", session.host_id, grant, "folder", "read", "brief.md")
        self.post("on-host", direct_to="assistant:lead", scope=scope)
        self.q.dispatch_one(self.registry, host_store=hosts, host_session=session)
        request, = self.adapters["lead"].calls
        self.assertEqual(request.payload["_tachi_host_scope"]["relative_path"], "brief.md")
        self.assertNotIn(session.secret, repr(request))
        self.assertNotIn(session.secret.encode(), self.path.read_bytes())

    def test_two_workers_serialize_one_session_without_locking_another(self):
        entered, finish = threading.Event(), threading.Event()
        self.post("busy", direct_to="assistant:lead")
        self.post("waiting", direct_to="assistant:lead")
        self.post("independent", direct_to="assistant:peer")
        adapter = self.adapters["lead"]
        def slow(request):
            entered.set()
            if not finish.wait(5):
                raise AssertionError("unrelated worker blocked")
            return ReferenceAdapter.dispatch(adapter, request)
        adapter.dispatch = slow
        worker_errors = []
        def run():
            worker = TeamQueue(self.path, self.accounts)
            try:
                worker.dispatch_one(self.registry)
            except BaseException as error:
                worker_errors.append(error)
            finally:
                worker.close()
        thread = threading.Thread(target=run)
        thread.start()
        try:
            self.assertTrue(entered.wait(5))
            self.q.dispatch_one(self.registry)
            self.assertEqual((self.status(1), self.status(2)), ("queued", "completed"))
            self.assertIsNone(self.q.dispatch_one(self.registry))
        finally:
            finish.set()
            thread.join(5)
        self.assertFalse(thread.is_alive())
        self.assertFalse(worker_errors)
        self.assertEqual(self.status(), "completed")
        self.assertEqual(len(adapter.calls), 1)


if __name__ == "__main__":
    unittest.main()
