"""Check whether a synthetic routine receipt can advance a team assignment."""

from contextlib import closing
from pathlib import Path
from tempfile import TemporaryDirectory
import unittest
from unittest.mock import Mock

from tachi.hosts import AccountStore
from tachi.providers.grok.adapter import GrokBotAdapter
from tachi.providers.grok.connector import HttpResult
from tachi.runtime import AdapterEvent, AdapterIdentity, AdapterRegistry, Capability, EventKind
from tachi.runtime.queue import TeamQueue


class GrokReceiptCheck(unittest.TestCase):
    def test_acceptance_holds_next_turn_and_cannot_author_a_reply(self):
        identity = AdapterIdentity("grok-bot", "lab-account", "lab-bot")
        transport = Mock(return_value=HttpResult(200))
        registry = AdapterRegistry()
        registry.register(GrokBotAdapter(identity, webhook_url="https://routine.example.invalid/lab",
                                         webhook_secret="synthetic", transport=transport))
        with TemporaryDirectory() as directory:
            path = Path(directory) / "lab.sqlite"
            accounts = AccountStore(path)
            invitation = accounts.issue_client_invitation("editor", {"teams:manage", "sessions:read", "messages:send"})
            owner = accounts.authenticate(accounts.redeem_client(invitation).token)
            accounts.create_team("editor", owner.client_id, "lab")
            with closing(TeamQueue(path, accounts)) as queue:
                queue.add_assistant("lab", owner, "reviewer", identity, "lab-session")
                queue.create_run("lab", owner, "brief", "assistant:reviewer", turn_limit=3)
                for message in ("first", "second"):
                    queue.post("lab", owner, "brief", message, {"task": message},
                               mentions=("assistant:reviewer",), capability=Capability.TASK)
                request_id = queue.dispatch_one(registry)

            with closing(TeamQueue(path, accounts)) as queue:
                first, second = queue.history("lab", owner, "brief")
                delivery, = first["deliveries"]
                event, = delivery["events"]
                self.assertEqual((delivery["request"], delivery["state"], event["kind"]),
                                 (request_id, "active", "accepted"))
                self.assertIs(event["payload"]["native_reply"], False)
                receipt = AdapterEvent(identity, "lab-session", request_id, event["event"],
                                       EventKind.ACCEPTED, event["payload"])
                with self.assertRaises(PermissionError):
                    queue.post_reply(receipt, "finding", {"text": "Fixture finding"}, direct_to="human:editor")
                self.assertEqual(second["deliveries"][0]["state"], "queued")
                self.assertIsNone(queue.dispatch_one(registry))
                self.assertEqual(len(queue.history("lab", owner, "brief")), 2)
                transport.assert_called_once()


if __name__ == "__main__":
    unittest.main()
