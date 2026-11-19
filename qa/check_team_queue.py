"""Run the brief handoff with two client bindings and deterministic adapters."""

from contextlib import closing
from pathlib import Path
from tempfile import TemporaryDirectory
import unittest

from tachi.hosts import AccountStore
from tachi.runtime import AdapterIdentity, AdapterRegistry, Capability
from tachi.runtime.queue import TeamQueue
from tachi.runtime.reference import ReferenceAdapter


class ObservedReference(ReferenceAdapter):
    def dispatch(self, request):
        events = super().dispatch(request)
        (self.completion,) = events
        return events


class TeamBriefCheck(unittest.TestCase):
    def test_handoff_then_edit_from_second_client(self):
        with TemporaryDirectory() as directory:
            db = Path(directory) / "lab.sqlite"
            accounts = AccountStore(db)

            def pair():
                invitation = accounts.issue_client_invitation(
                    "editor", {"teams:manage", "sessions:read", "messages:send"})
                return accounts.authenticate(accounts.redeem_client(invitation).token)

            first, second = pair(), pair()
            self.assertNotEqual(first.client_id, second.client_id)
            accounts.create_team("editor", first.client_id, "hall")
            registry = AdapterRegistry()
            lead = ObservedReference(AdapterIdentity("reference-a", "lab", "lead"))
            reviewer = ObservedReference(AdapterIdentity("reference-b", "lab", "reviewer"))
            correction = {"text": "Show check-ins by workshop and label registration separately."}
            with closing(TeamQueue(db, accounts)) as queue:
                for adapter in (lead, reviewer):
                    alias = adapter.identity.assistant_id
                    registry.register(adapter)
                    queue.add_assistant("hall", first, alias, adapter.identity, alias + "-session")
                queue.create_run("hall", first, "brief", "assistant:lead", turn_limit=4)
                queue.post("hall", first, "brief", "draft", {"source": "draft.md"}, mentions=("assistant:lead",))
                self.assertIsNotNone(queue.dispatch_one(registry))
                queue.post_reply(lead.completion, "verify", {"source": "attendance.csv"},
                                 mentions=("assistant:reviewer",), capability=Capability.TASK)
                self.assertIsNotNone(queue.dispatch_one(registry))
                self.assertEqual(reviewer.calls[0].session_id, "reviewer-session")
                self.assertEqual(reviewer.calls[0].payload, {"source": "attendance.csv"})
                finding = {"checked_in": 95, "registered": 120}
                queue.post_reply(reviewer.completion, "finding", finding, mentions=("assistant:lead",))
                self.assertIsNotNone(queue.dispatch_one(registry))
                self.assertEqual(lead.calls[-1].payload, finding)
                queue.intervene("hall", second, "brief", "paused")
                queue.post("hall", second, "brief", "edit", correction, reply_to="finding", mentions=("assistant:lead",))

            with closing(TeamQueue(db, accounts)) as reopened:
                self.assertIsNone(reopened.dispatch_one(registry))
                reopened.intervene("hall", second, "brief", "running")
                self.assertIsNotNone(reopened.dispatch_one(registry))
                self.assertIsNone(reopened.dispatch_one(registry))
                history = reopened.history("hall", first, "brief")
                self.assertEqual([row["reply_to"] for row in history], [None, "draft", "verify", "finding"])
                self.assertEqual([row["message"] for row in history], ["draft", "verify", "finding", "edit"])
                requests = [lead.calls[0], reviewer.calls[0], lead.calls[1], lead.calls[2]]
                for row, request in zip(history, requests, strict=True):
                    (delivery,) = row["deliveries"]
                    self.assertEqual((delivery["request"], delivery["session_id"], delivery["state"]),
                                     (request.request_id, request.session_id, "completed"))
                self.assertEqual(history[2]["parent_request"], reviewer.completion.request_id)
                self.assertEqual(len(lead.calls), 3)
                self.assertEqual(len(reviewer.calls), 1)
                self.assertEqual(lead.calls[-1].payload, correction)
                self.assertEqual(lead.calls[-1].session_id, "lead-session")


if __name__ == "__main__":
    unittest.main()
